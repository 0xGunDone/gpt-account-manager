import Foundation
import Observation
import WebKit

enum MailRuOrigin {
    static func allowsNavigation(_ url: URL?) -> Bool {
        guard let url, url.scheme?.lowercased() == "https",
              url.port == nil || url.port == 443, url.user == nil, url.password == nil,
              let host = url.host?.lowercased() else { return false }
        return host == "mail.ru" || host.hasSuffix(".mail.ru") || host == "id.vk.ru"
    }

    static func allowsReading(_ url: URL?) -> Bool {
        allowsNavigation(url) && url?.host?.lowercased() == "e.mail.ru"
    }

    static func isInbox(_ url: URL?) -> Bool {
        guard allowsReading(url), let url, url.fragment == nil else { return false }
        if ["/inbox", "/inbox/"].contains(url.path) { return url.query == nil }
        guard ["/messages/inbox", "/messages/inbox/"].contains(url.path) else { return false }
        if url.query == nil || url.query?.range(of: #"^[0-9]+$"#, options: .regularExpression) != nil { return true }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return items.count == 2 && items.contains(URLQueryItem(name: "page", value: "1")) &&
            items.contains(URLQueryItem(name: "sortby", value: "A"))
    }

    static func messageID(_ url: URL?) -> String? {
        guard allowsReading(url), let url, url.fragment == nil else { return nil }
        let components = url.path.split(separator: "/")
        guard components.count == 2 else { return nil }
        if components[0] == "inbox", url.query == nil { return String(components[1]) }
        guard components[0] == "message", url.query == "folder=0",
              components[1].allSatisfy(\.isNumber) else { return nil }
        return String(components[1])
    }
}

@MainActor
@Observable
final class MailRuMailbox: NSObject, WKNavigationDelegate, WKUIDelegate {
    struct Timeouts {
        var readiness: Duration = .seconds(20)
        var navigation: Duration = .seconds(15)
        var evaluation: Duration = .seconds(8)
    }

    // This store is intentionally separate from every ChatGPT account store.
    static let dataStoreID = UUID(uuidString: "8BDE779C-66E8-4735-8977-0491F9A3E519")!
    static let expectedMailboxKey = "mailRuExpectedMailbox"
    let webView: WKWebView
    private(set) var expectedMailbox: String
    private(set) var status = "Войдите в Mail.ru один раз. Сеанс почты сохранится в приложении."
    private(set) var lastReadingCheck: String?
    @ObservationIgnored private let defaults: UserDefaults?
    @ObservationIgnored private let timeouts: Timeouts
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var polling = false
    @ObservationIgnored private var hasLoaded = false
    @ObservationIgnored private var evaluations: [UUID: MailboxEvaluation] = [:]
    @ObservationIgnored private var finishedNavigation: ObjectIdentifier?
    @ObservationIgnored private var pendingNavigation: ObjectIdentifier?
    private static let inboxURL = URL(string: "https://e.mail.ru/inbox/")!
    @ObservationIgnored private var currentInboxURL = inboxURL

    init(expectedMailbox: String? = nil, defaults: UserDefaults = .standard, timeouts: Timeouts = .init(),
         webViewFactory: ((WKWebViewConfiguration) -> WKWebView)? = nil) {
        self.defaults = expectedMailbox == nil ? defaults : nil
        self.timeouts = timeouts
        self.expectedMailbox = MailVerificationMatcher.normalizedAddress(
            expectedMailbox ?? defaults.string(forKey: Self.expectedMailboxKey) ?? "") ?? ""
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = WKWebsiteDataStore(forIdentifier: Self.dataStoreID)
        webView = webViewFactory?(configuration) ?? WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        status = signInStatus
    }

    func setExpectedMailbox(_ value: String) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty || MailVerificationMatcher.normalizedAddress(trimmed) != nil else {
            throw MailVerificationError.invalidAlias
        }
        let address = MailVerificationMatcher.normalizedAddress(trimmed) ?? ""
        guard address != expectedMailbox else { return }
        cancel()
        expectedMailbox = address
        defaults?.set(address, forKey: Self.expectedMailboxKey)
        lastReadingCheck = nil
        status = signInStatus
    }

    private var signInStatus: String {
        expectedMailbox.isEmpty
            ? "Укажите свой ящик Mail.ru для получения пересланных писем и войдите в него."
            : "Войдите в \(expectedMailbox). Сеанс сохранится в приложении."
    }

    func ensureLoaded() {
        guard !hasLoaded else { return }
        hasLoaded = true
        pendingNavigation = webView.load(URLRequest(url: currentInboxURL)).map(ObjectIdentifier.init)
    }

    func openInbox() {
        lastReadingCheck = nil
        cancel()
        hasLoaded = true
        pendingNavigation = webView.load(URLRequest(url: currentInboxURL)).map(ObjectIdentifier.init)
    }

    func refresh() {
        lastReadingCheck = nil
        cancel()
        guard MailRuOrigin.allowsNavigation(webView.url) else { openInbox(); return }
        pendingNavigation = webView.reload().map(ObjectIdentifier.init)
    }

    func cancel() {
        generation += 1
        if polling {
            status = MailVerificationError.cancelled.localizedDescription
            webView.stopLoading()
            pendingNavigation = nil
        }
        polling = false
        for evaluation in Array(evaluations.values) {
            evaluation.finish(.failure(MailVerificationError.cancelled))
        }
    }

    func captureBaseline() async throws -> Set<String> {
        lastReadingCheck = nil
        cancel()
        return try await captureBaseline(token: generation)
    }

    private func captureBaseline(token: Int) async throws -> Set<String> {
        polling = true
        defer { if token == generation { polling = false } }
        do {
            status = "Обновляется список писем перед запросом кода…"
            let snapshot = try await ensureInboxReady(token: token, deadline: .now.advanced(by: timeouts.readiness), refresh: true)
            let ids = Set(snapshot.entries.map(\.id))
            status = "Почта готова. Будут проверяться только новые письма для выбранного адреса."
            return ids
        } catch {
            if token == generation { status = error.localizedDescription }
            throw error
        }
    }

    func checkReading() async {
        lastReadingCheck = nil
        cancel()
        let token = generation
        defer { if token == generation { lastReadingCheck = status } }
        guard !expectedMailbox.isEmpty else { status = signInStatus; return }
        if MailRuOrigin.isInbox(webView.url) {
            do {
                _ = try await captureBaseline(token: token)
                let snapshot = try await inboxSnapshot(token: token)
                let candidates = snapshot.entries.filter {
                    $0.subject.range(of: #"\b(?:ChatGPT|OpenAI)\b"#, options: [.regularExpression, .caseInsensitive]) != nil
                }.count
                status = "Чтение списка проверено: писем \(snapshot.entries.count), с темой OpenAI/ChatGPT — \(candidates)."
            } catch { if token == generation { status = error.localizedDescription } }
            return
        }
        do {
            guard let id = MailRuOrigin.messageID(webView.url), let url = webView.url else {
                throw MailVerificationError.baselineRequired
            }
            let now = Date()
            let entry = MailboxInboxSnapshot.Entry(id: id, url: url, subject: "", receivedAt: ISO8601DateFormatter().string(from: now))
            let message = try await readMessage(entry: entry, token: token, deadline: .now.advanced(by: .seconds(10)))
            guard let alias = MailVerificationMatcher.addressInHeader(message.recipient) else {
                throw MailVerificationError.unsupportedLayout
            }
            let result = try MailVerificationMatcher.match(messages: [message], alias: alias,
                                                           since: message.receivedAt, excluding: [], now: Date())
            status = result == nil
                ? "Заголовки прочитаны и отправитель подтверждён. Единственный код смены email не найден."
                : "Чтение проверено: отправитель, адресат и код смены email распознаны. Дата отправки: \(ISO8601DateFormatter().string(from: message.receivedAt)). Код не отправлялся."
            if result != nil {
                let inbox = try await ensureInboxReady(token: token, deadline: .now.advanced(by: .seconds(20)))
                let otherIDs = Set(inbox.entries.map(\.id)).subtracting([id])
                let found = try await waitForCode(alias: alias, since: message.receivedAt, excluding: otherIDs, purpose: .emailChange)
                status = found.messageID == id
                    ? "Проверка пройдена: письмо найдено автоматически во входящих, адресат и код подтверждены. Код не отправлялся."
                    : "Найдено другое подходящее письмо. Запросите свежий код перед продолжением смены email."
            }
        } catch {
            if token == generation { status = error.localizedDescription }
        }
    }

    func waitForCode(alias: String, since: Date, excluding: Set<String>) async throws -> MailVerificationCode {
        try await waitForCode(alias: alias, since: since, excluding: excluding, purpose: .emailChange)
    }

    func waitForCode(
        alias: String, since: Date, excluding: Set<String>, purpose: MailVerificationPurpose
    ) async throws -> MailVerificationCode {
        lastReadingCheck = nil
        guard MailVerificationMatcher.normalizedAddress(alias) != nil else {
            throw MailVerificationError.invalidAlias
        }
        // The coordinator persists these two values before requesting a code so
        // a restart can resume without requesting another email or losing IDs.
        guard since <= Date(), since.timeIntervalSince1970 > 0 else {
            throw MailVerificationError.baselineRequired
        }
        guard !polling else { throw MailVerificationError.baselineRequired }
        let token = generation
        let deadline = ContinuousClock.now.advanced(by: .seconds(120))
        polling = true
        status = "Ожидается новое письмо с кодом для \(alias)…"
        defer { if token == generation { polling = false } }
        do {
            var snapshot = try await ensureInboxReady(token: token, deadline: deadline)
            while ContinuousClock.now < deadline {
                try checkCancellation(token)
                let newEntries = snapshot.entries.filter {
                    !excluding.contains($0.id) && (purpose != .emailChange ||
                        $0.subject.range(of: #"\b(?:ChatGPT|OpenAI)\b"#, options: [.regularExpression, .caseInsensitive]) != nil)
                }
                // Inspect every fresh message before deciding: choosing the first
                // matching code would silently accept two concurrent requests.
                var messages: [MailVerificationMessage] = []
                var unreadableCount = 0
                var unverifiedCount = 0
                for entry in newEntries {
                    guard ContinuousClock.now < deadline else { throw MailVerificationError.timedOut }
                    try await loadMailboxURL(entry.url, token: token, deadline: deadline)
                    do {
                        messages.append(try await readMessage(entry: entry, token: token, deadline: deadline))
                    } catch MailVerificationError.unverifiedSender {
                        // A newsletter or unrelated forwarded message cannot stop the code search.
                        unverifiedCount += 1
                    } catch MailVerificationError.unsupportedLayout {
                        // Ignore an unrecognized message; require full proof for any accepted code.
                        unreadableCount += 1
                    }
                    _ = try await ensureInboxReady(token: token, deadline: deadline)
                }
                if let code = try MailVerificationMatcher.match(
                    messages: messages, alias: alias, since: since, excluding: excluding, purpose: purpose
                ) {
                    status = "Найдено новое письмо OpenAI для \(alias)."
                    return code
                }
                status = "Ожидается код: новых писем — \(newEntries.count), проверено — \(messages.count), не прочитано — \(unreadableCount), отправитель не подтверждён — \(unverifiedCount)."
                guard ContinuousClock.now < deadline else { throw MailVerificationError.timedOut }
                try await Task.sleep(for: min(.seconds(3), ContinuousClock.now.duration(to: deadline)))
                try checkCancellation(token)
                guard ContinuousClock.now < deadline else { throw MailVerificationError.timedOut }
                // Never reload a login form or a page the user opened while waiting.
                snapshot = try await ensureInboxReady(token: token, deadline: deadline, refresh: true)
            }
            throw MailVerificationError.timedOut
        } catch {
            if token == generation { status = error.localizedDescription }
            throw error
        }
    }

    private func checkCancellation(_ token: Int) throws {
        if Task.isCancelled, token == generation {
            webView.stopLoading()
            pendingNavigation = nil
        }
        guard !Task.isCancelled, token == generation else { throw MailVerificationError.cancelled }
    }

    private func ensureInboxReady(
        token: Int, deadline: ContinuousClock.Instant, refresh: Bool = false
    ) async throws -> MailboxInboxSnapshot {
        guard !expectedMailbox.isEmpty else { throw MailboxReadinessError.mailboxRequired }
        let readyDeadline = min(deadline, ContinuousClock.now.advanced(by: timeouts.readiness))
        var needsRefresh = refresh
        while ContinuousClock.now < readyDeadline {
            try checkCancellation(token)
            if let url = webView.url {
                guard MailRuOrigin.allowsNavigation(url) else { throw MailVerificationError.untrustedOrigin }
                guard MailRuOrigin.allowsReading(url) else { throw MailVerificationError.signInRequired }
            }
            if pendingNavigation != nil || (webView.url == nil && webView.isLoading) {
                needsRefresh = false
            } else if webView.url == nil {
                try startInboxNavigation()
                needsRefresh = false
            } else {
                do {
                    let page: MailboxPageState = try await read(Self.readinessScript, token: token, deadline: readyDeadline)
                    guard !page.signIn else { throw MailVerificationError.signInRequired }
                    guard !page.editing, !page.challenge else { throw MailVerificationError.unsupportedLayout }
                    if page.ready {
                        if MailRuOrigin.isInbox(webView.url) {
                            let snapshot = try await inboxSnapshot(token: token, deadline: readyDeadline, waitingForDOM: true)
                            if !needsRefresh { return snapshot }
                        }
                        try startInboxNavigation()
                        needsRefresh = false
                    }
                } catch MailboxReadinessError.notReady {
                    // The route can commit before Mail.ru renders its mailbox identity and rows.
                } catch MailVerificationError.cancelled {
                    // A redirect invalidates a DOM read; user cancellation still ends this operation.
                    try checkCancellation(token)
                }
            }
            guard ContinuousClock.now < readyDeadline else { break }
            do {
                try await Task.sleep(for: min(.milliseconds(100), ContinuousClock.now.duration(to: readyDeadline)))
            } catch {
                try checkCancellation(token)
                throw error
            }
        }
        try checkCancellation(token)
        throw MailVerificationError.timedOut
    }

    private func startInboxNavigation() throws {
        hasLoaded = true
        guard let navigation = webView.load(URLRequest(url: currentInboxURL, cachePolicy: .reloadIgnoringLocalCacheData)) else {
            throw MailVerificationError.unsupportedLayout
        }
        pendingNavigation = ObjectIdentifier(navigation)
    }

    private func inboxSnapshot(
        token: Int, deadline: ContinuousClock.Instant? = nil, waitingForDOM: Bool = false
    ) async throws -> MailboxInboxSnapshot {
        guard MailRuOrigin.allowsReading(webView.url) else { throw MailVerificationError.signInRequired }
        guard MailRuOrigin.isInbox(webView.url) else { throw MailVerificationError.baselineRequired }
        let snapshot: MailboxInboxSnapshot = try await read(Self.inboxScript, token: token, deadline: deadline)
        guard snapshot.invalid != true else { throw MailVerificationError.unsupportedLayout }
        if waitingForDOM, !snapshot.supported,
           snapshot.mailbox.isEmpty || MailVerificationMatcher.normalizedAddress(snapshot.mailbox) ==
            MailVerificationMatcher.normalizedAddress(expectedMailbox) {
            throw MailboxReadinessError.notReady
        }
        guard snapshot.supported,
              MailVerificationMatcher.normalizedAddress(snapshot.mailbox) ==
                MailVerificationMatcher.normalizedAddress(expectedMailbox),
              MailVerificationMatcher.normalizedAddress(expectedMailbox) != nil,
              snapshot.entries.allSatisfy({ MailRuOrigin.messageID($0.url) == $0.id }) else {
            throw MailVerificationError.unsupportedLayout
        }
        if let url = webView.url { currentInboxURL = url }
        return snapshot
    }

    private func readMessage(
        entry: MailboxInboxSnapshot.Entry, token: Int, deadline: ContinuousClock.Instant
    ) async throws -> MailVerificationMessage {
        let readyDeadline = min(deadline, ContinuousClock.now.advanced(by: .seconds(8)))
        while true {
            try checkCancellation(token)
            do {
                return try await readLoadedMessage(entry: entry, token: token, deadline: readyDeadline)
            } catch MailVerificationError.unsupportedLayout {
                guard ContinuousClock.now < readyDeadline else { throw MailVerificationError.unsupportedLayout }
                // Mail.ru can finish navigation before rendering the message body/headers.
                // Stay on this message until it is readable instead of reopening it each poll.
                try await Task.sleep(for: min(.milliseconds(200), ContinuousClock.now.duration(to: readyDeadline)))
            }
        }
    }

    private func readLoadedMessage(
        entry: MailboxInboxSnapshot.Entry, token: Int, deadline: ContinuousClock.Instant
    ) async throws -> MailVerificationMessage {
        guard MailRuOrigin.messageID(webView.url) == entry.id else {
            throw MailVerificationError.untrustedOrigin
        }
        let value: MailboxMessageSnapshot = try await read(Self.messageScript, token: token, deadline: deadline)
        guard MailRuOrigin.messageID(webView.url) == entry.id else { throw MailVerificationError.cancelled }
        let light = webView.url?.path.hasPrefix("/message/") == true
        guard value.supported,
              let received = light ? MailVerificationMatcher.sourceDate(rawHeaders: value.rawHeaders ?? "") :
                MailVerificationMatcher.receivedDate(from: value.receivedAt) else {
            throw MailVerificationError.unsupportedLayout
        }
        let originalSender: String?
        if light {
            guard let verified = MailVerificationMatcher.verifiedOriginalSender(
                rawHeaders: value.rawHeaders ?? "", visibleSender: value.sender,
                visibleRecipient: value.recipient, expectedMailbox: expectedMailbox
            ) else { throw MailVerificationError.unverifiedSender }
            originalSender = verified
        } else { originalSender = value.originalSender }
        return .init(messageID: entry.id, sender: value.sender, recipient: value.recipient,
                     originalSender: originalSender, receivedAt: received,
                     subject: value.subject.isEmpty ? entry.subject : value.subject, body: value.body)
    }

    private func loadMailboxURL(_ url: URL, token: Int, deadline: ContinuousClock.Instant) async throws {
        try checkCancellation(token)
        guard ContinuousClock.now < deadline else { throw MailVerificationError.timedOut }
        guard MailRuOrigin.allowsReading(webView.url), MailRuOrigin.allowsReading(url) else {
            throw MailVerificationError.signInRequired
        }
        guard let navigation = webView.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)) else {
            throw MailVerificationError.unsupportedLayout
        }
        pendingNavigation = ObjectIdentifier(navigation)
        let loadDeadline = min(deadline, ContinuousClock.now.advanced(by: timeouts.navigation))
        repeat {
            try await Task.sleep(for: min(.milliseconds(100), ContinuousClock.now.duration(to: loadDeadline)))
            try checkCancellation(token)
            if finishedNavigation == ObjectIdentifier(navigation),
               webView.url == url || (MailRuOrigin.isInbox(url) && MailRuOrigin.isInbox(webView.url)) { return }
        } while ContinuousClock.now < loadDeadline
        throw MailVerificationError.timedOut
    }

    private func read<Value: Decodable>(
        _ script: String, token: Int, deadline: ContinuousClock.Instant? = nil
    ) async throws -> Value {
        try checkCancellation(token)
        let budget = deadline.map { min(timeouts.evaluation, ContinuousClock.now.duration(to: $0)) } ?? timeouts.evaluation
        guard budget > .zero else { throw MailVerificationError.timedOut }
        guard let capturedURL = webView.url, MailRuOrigin.allowsReading(capturedURL) else { throw MailVerificationError.untrustedOrigin }
        let json: String = try await withCheckedThrowingContinuation { continuation in
            let id = UUID()
            let gate = MailboxEvaluation(continuation: continuation) { [weak self] in
                self?.evaluations.removeValue(forKey: id)
            }
            evaluations[id] = gate
            gate.timeout = Task { @MainActor in
                do { try await Task.sleep(for: budget) }
                catch { return }
                gate.finish(.failure(MailVerificationError.timedOut))
            }
            // A private content world avoids page monkey patches. No script
            // message handler exposes native actions to emails or mailbox scripts.
            webView.__callAsyncJavaScript("return await (" + script + ");", arguments: [:], inFrame: nil, in: .defaultClient) { value, error in
                if error == nil {
                    guard let json = value as? String else {
                        gate.finish(.failure(MailVerificationError.unsupportedLayout)); return
                    }
                    gate.finish(.success(json))
                } else { gate.finish(.failure(MailVerificationError.unsupportedLayout)) }
            }
        }
        try checkCancellation(token)
        guard webView.url == capturedURL else { throw MailVerificationError.cancelled }
        guard MailRuOrigin.allowsReading(webView.url), let data = json.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(Value.self, from: data) else {
            throw MailVerificationError.unsupportedLayout
        }
        return decoded
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        let topLevel = action.targetFrame?.isMainFrame != false
        if topLevel, polling, [.linkActivated, .formSubmitted, .backForward, .reload].contains(action.navigationType) {
            cancel()
        }
        guard !topLevel || MailRuOrigin.allowsNavigation(action.request.url) else {
            status = MailVerificationError.untrustedOrigin.localizedDescription
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if polling { cancel() }
        guard MailRuOrigin.allowsNavigation(action.request.url) else {
            status = MailVerificationError.untrustedOrigin.localizedDescription
            return nil
        }
        if action.targetFrame == nil { webView.load(action.request) }
        return nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if let navigation {
            finishedNavigation = ObjectIdentifier(navigation)
            if pendingNavigation == ObjectIdentifier(navigation) { pendingNavigation = nil }
        }
        guard !polling else { return }
        status = MailRuOrigin.allowsReading(webView.url)
            ? "Почта открыта. Для автоматической проверки нужны видимые заголовки письма и адрес ящика."
            : signInStatus
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        if let navigation, pendingNavigation == ObjectIdentifier(navigation) { pendingNavigation = nil }
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        if let navigation { pendingNavigation = ObjectIdentifier(navigation) }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if let navigation, pendingNavigation == ObjectIdentifier(navigation) { pendingNavigation = nil }
        if (error as NSError).code != NSURLErrorCancelled {
            status = "Не удалось открыть почту (код \((error as NSError).code)). Нажмите «Обновить»."
        }
    }

    // Read standard rendered semantics only. No provider-internal state, API
    // calls, guessed CSS classes, or fallback to the entire document's text.
    // Unsupported Mail.ru layouts require adapting this reader after inspection.
    private static let visibleScript = #"""
    const visible = e => {
      if (!e || !e.getClientRects().length || e.closest('[hidden], [aria-hidden="true"]')) return false;
      for (let parent = e; parent; parent = parent.parentElement) {
        const style = getComputedStyle(parent);
        if (style.visibility === 'hidden' || style.display === 'none' || style.opacity === '0') return false;
      }
      return true;
    };
    const text = e => visible(e) ? e.innerText.trim() : '';
    """#

    private static let readinessScript = "(() => {" + visibleScript + #"""
      const active = document.activeElement;
      const editing = visible(active) && (active.matches('input, textarea') || active.isContentEditable);
      const signIn = [...document.querySelectorAll('input[type="password"], input[type="email"], input[autocomplete="username"], input[autocomplete="current-password"], input[name="login"], input[name="username"]')].some(visible);
      const challenge = [...document.querySelectorAll('iframe[src*="captcha"], [id*="captcha"], [class*="captcha"]')].some(visible);
      return JSON.stringify({ready: document.readyState !== 'loading', signIn, editing, challenge});
    })()
    """#

    static let inboxScript = "(() => {" + visibleScript + #"""
      const active = document.activeElement;
      const editing = visible(active) && (active.matches('input, textarea') || active.isContentEditable);
      const login = [...document.querySelectorAll('input[type="password"]')].some(visible);
      if (document.querySelector('tr.messageline[id^="msglist-"]')) {
        const identity = document.title.match(/^\s*(?:\(\d+\)\s*)?Входящие\s*-\s*([^\s]+@[^\s]+)\s*-\s*Почта Mail\.ru\s*$/i)?.[1]?.toLowerCase() || '';
        const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
        let identityVisible = false;
        for (let node = walker.nextNode(); node; node = walker.nextNode()) {
          if (visible(node.parentElement) && node.textContent.trim().toLowerCase() === identity) identityVisible = true;
        }
        const logout = [...document.querySelectorAll('a[href]')].some(el => {
          if (!visible(el)) return false;
          const url = new URL(el.href, location.href);
          return url.origin === 'https://auth.mail.ru' && url.pathname === '/cgi-bin/logout';
        });
        const entries = new Map();
        for (const row of document.querySelectorAll('tr.messageline[id^="msglist-"]')) {
          if (!visible(row)) continue;
          const links = [...row.querySelectorAll('a.messageline__link[href]')].filter(visible).filter(el => {
            const url = new URL(el.href, location.href);
            return url.origin === 'https://e.mail.ru' && /^\/message\/\d+\/?$/.test(url.pathname) && url.search === '?folder=0' && !url.hash;
          });
          if (!links.length) continue;
          const urls = new Set(links.map(el => el.href));
          if (urls.size !== 1) continue;
          const url = new URL(links[0].href);
          const id = url.pathname.split('/')[2];
          if (row.id !== 'msglist-' + id) continue;
          const subjects = [...row.querySelectorAll('td.messageline__subject a.messageline__link')].filter(visible).map(text).filter(Boolean);
          const dates = new Set([...row.querySelectorAll('td.messageline__date[title]')].filter(visible).map(el => el.getAttribute('title'))
            .filter(value => /\d{4},?\s+\d{1,2}:\d{2}\s+[+-]\d{2}:\d{2}$/.test(value || '')));
          entries.set(id, { id, url: url.href, subject: subjects.length === 1 ? subjects[0] : '', receivedAt: dates.size === 1 ? [...dates][0] : '' });
        }
        return JSON.stringify({ supported: !editing && !login && !!identity && identityVisible && logout && entries.size > 0,
          invalid: identityVisible && logout && [...document.querySelectorAll('tr.messageline[id^="msglist-"]')].some(visible) && entries.size === 0,
          mailbox: identity, entries: [...entries.values()] });
      }
      const emails = new Set();
      for (const el of document.querySelectorAll('header button, header [role="button"], [role="banner"] button, [role="banner"] [role="button"]')) {
        if (!visible(el)) continue;
        for (const part of [text(el), el.getAttribute('aria-label') || '', el.getAttribute('title') || '']) {
          for (const email of part.match(/[A-Za-z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+/g) || []) emails.add(email.toLowerCase());
        }
      }
      const entries = new Map();
      for (const el of document.querySelectorAll('main a[href], [role="main"] a[href]')) {
        if (!visible(el) || el.closest('article, [role="article"]')) continue;
        const u = new URL(el.href, location.href);
        const match = u.pathname.match(/^\/inbox\/([^/]+)\/?$/);
        if (u.origin === 'https://e.mail.ru' && match && !u.search && !u.hash)
          entries.set(match[1], { id: match[1], url: u.href, subject: text(el), receivedAt: '' });
      }
      const empty = [...document.querySelectorAll('main, [role="main"]')].some(el =>
        visible(el) && /^(писем нет|нет писем|папка пуста|no messages|no mail)$/i.test(text(el)));
      return JSON.stringify({ supported: !editing && !login && emails.size === 1 && (entries.size > 0 || empty),
        invalid: emails.size > 1,
        mailbox: [...emails][0] || '', entries: [...entries.values()] });
    })()
    """#

    static let messageScript = "(async () => {" + visibleScript + #"""
      const id = location.pathname.match(/^\/message\/(\d+)\/?$/)?.[1];
      if (id) {
        const unique = selector => {
          const values = [...document.querySelectorAll(selector)].filter(visible);
          return values.length === 1 ? values[0] : null;
        };
        const body = unique('#viewmessagebody_BODY.mr_read__body__content');
        const senderNode = unique('#msgFieldFrom .val');
        const recipientNode = unique('#msgFieldTo .val');
        const sender = senderNode && !senderNode.closest('#ReadMsgBody') ? text(senderNode) : '';
        const recipient = recipientNode && !recipientNode.closest('#ReadMsgBody') ? text(recipientNode) : '';
        const bodyValid = body?.closest('#ReadMsgBody') && body.closest('[id="MSG' + id + '"]');
        const links = [...document.querySelectorAll('a[href]')].filter(el => {
          if (!visible(el) || el.closest('#ReadMsgBody') || text(el) !== 'Скачать') return false;
          const url = new URL(el.href, location.href);
          return url.origin === 'https://e.mail.ru' && url.pathname === '/cgi-bin/getmsg' && url.search === '?id=' + id && !url.hash;
        });
        let rawHeaders = '';
        if (bodyValid && sender && recipient && links.length === 1) {
          const abort = new AbortController();
          const timer = setTimeout(() => abort.abort(), 6000);
          try {
            const response = await fetch(links[0].href, { credentials: 'include', redirect: 'error', signal: abort.signal });
            if (response.ok && response.url === links[0].href && response.body) {
              const reader = response.body.getReader();
              const decoder = new TextDecoder();
              let buffer = '';
              while (buffer.length <= 131072) {
                const chunk = await reader.read();
                buffer += decoder.decode(chunk.value || new Uint8Array(), {stream: !chunk.done});
                const end = buffer.search(/\r?\n\r?\n/);
                if (end >= 0) { rawHeaders = buffer.slice(0, end); break; }
                if (chunk.done) break;
              }
              await reader.cancel();
            }
          } catch (_) {} finally { clearTimeout(timer); }
        }
        return JSON.stringify({ supported: !!(bodyValid && sender && recipient && rawHeaders),
          sender, recipient, originalSender: null, receivedAt: '', subject: '', body: text(body), rawHeaders });
      }
      const bodies = [...document.querySelectorAll('main article, [role="main"] article, main [role="article"], [role="main"] [role="article"]')].filter(visible);
      const body = bodies.length === 1 ? bodies[0] : null;
      const outsideBody = e => visible(e) && !e.closest('article, [role="article"]');
      const fields = new Map();
      const add = (label, value) => {
        label = label.trim().replace(/:$/, '').toLowerCase();
        if (!label || !value) return;
        const values = fields.get(label) || new Set(); values.add(value); fields.set(label, values);
      };
      for (const dt of document.querySelectorAll('main dt, [role="main"] dt')) {
        if (outsideBody(dt) && dt.nextElementSibling?.tagName === 'DD' && outsideBody(dt.nextElementSibling))
          add(text(dt), text(dt.nextElementSibling));
      }
      for (const row of document.querySelectorAll('main tr, [role="main"] tr, main [role="row"], [role="main"] [role="row"]')) {
        if (!outsideBody(row)) continue;
        const label = row.querySelector('th, [role="rowheader"]');
        const cells = [...row.querySelectorAll('td, [role="cell"]')].filter(outsideBody);
        if (label && cells.length === 1) add(text(label), text(cells[0]));
      }
      const get = labels => {
        const values = new Set(labels.flatMap(label => [...(fields.get(label) || [])]));
        return values.size === 1 ? [...values][0] : '';
      };
      const sender = get(['от', 'от кого', 'from']);
      const recipient = get(['кому', 'to']);
      const originalSender = get(['исходный отправитель', 'original sender']);
      const headings = [...document.querySelectorAll('main h1, [role="main"] h1')].filter(outsideBody);
      const dates = [...document.querySelectorAll('main time[datetime], [role="main"] time[datetime]')].filter(outsideBody);
      const receivedAt = dates.length === 1 ? dates[0].getAttribute('datetime') : '';
      const subject = headings.length === 1 ? text(headings[0]) : '';
      return JSON.stringify({ supported: !!(body && sender && recipient && subject && receivedAt && text(dates[0])),
        sender, recipient, originalSender: originalSender || null, receivedAt, subject, body: text(body) });
    })()
    """#
}

private enum MailboxReadinessError: Error, LocalizedError {
    case notReady
    case mailboxRequired

    var errorDescription: String? {
        switch self {
        case .notReady: nil
        case .mailboxRequired: "Укажите и сохраните свой ящик Mail.ru во вкладке «Почта»."
        }
    }
}

private struct MailboxPageState: Decodable {
    let ready: Bool
    let signIn: Bool
    let editing: Bool
    let challenge: Bool
}

struct MailboxInboxSnapshot: Decodable {
    struct Entry: Decodable {
        let id: String
        let url: URL
        let subject: String
        let receivedAt: String
    }
    let supported: Bool
    let invalid: Bool?
    let mailbox: String
    let entries: [Entry]
}

struct MailboxMessageSnapshot: Decodable {
    let supported: Bool
    let sender: String
    let recipient: String
    let originalSender: String?
    let receivedAt: String
    let subject: String
    let body: String
    let rawHeaders: String?
}

@MainActor
private final class MailboxEvaluation {
    var timeout: Task<Void, Never>?
    private var continuation: CheckedContinuation<String, Error>?
    private let onFinish: @MainActor () -> Void

    init(continuation: CheckedContinuation<String, Error>, onFinish: @escaping @MainActor () -> Void) {
        self.continuation = continuation
        self.onFinish = onFinish
    }

    func finish(_ result: Result<String, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        timeout?.cancel()
        timeout = nil
        onFinish()
        continuation.resume(with: result)
    }
}
