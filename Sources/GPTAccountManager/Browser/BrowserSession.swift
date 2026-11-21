import AppKit
import Combine
import Foundation
import WebKit

@MainActor
private final class KeyboardSubmissionGate {
    // Keep native keyboard submission exclusive on the shared responder chain.
    private var occupied = false

    func withPermit(_ operation: () async -> Bool) async -> Bool {
        guard await acquire() else { return false }
        defer { occupied = false }
        return await operation()
    }

    private func acquire() async -> Bool {
        while occupied {
            guard !Task.isCancelled else { return false }
            do {
                try await Task.sleep(for: .milliseconds(20))
            } catch {
                return false
            }
        }
        guard !Task.isCancelled else { return false }
        occupied = true
        return true
    }
}

@MainActor
private final class BrowserFrameMessageRelay: NSObject, WKScriptMessageHandler {
    weak var session: BrowserSession?

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        session?.register(frame: message.frameInfo)
    }
}

enum TrustedChatGPTOrigin {
    static func allowsTopLevelNavigation(_ url: URL?) -> Bool {
        guard let url,
              url.scheme?.lowercased() == "https",
              url.port == nil || url.port == 443,
              url.user == nil, url.password == nil,
              let host = url.host?.lowercased()
        else { return false }
        return host == "chatgpt.com" || host == "auth.openai.com"
    }

    static func allowsMetadata(_ url: URL?) -> Bool {
        guard allowsTopLevelNavigation(url), let host = url?.host?.lowercased() else {
            return false
        }
        return host == "chatgpt.com"
    }

    static func allowsAuthentication(_ url: URL?) -> Bool {
        allowsTopLevelNavigation(url)
    }

    static func allowsSecurityAutomation(_ url: URL?) -> Bool {
        guard allowsMetadata(url) else { return false }
        let location = "\(url?.path ?? "")#\(url?.fragment ?? "")".lowercased()
        return location.contains("settings/security")
    }

}

enum BrowserSessionError: Error, Equatable {
    case untrustedOrigin
    case evaluationTimedOut
}

@MainActor
private struct JavaScriptValue: @unchecked Sendable {
    let rawValue: Any
}

@MainActor
private final class JavaScriptEvaluationGate {
    private var finished = false
    private var continuation: CheckedContinuation<JavaScriptValue, Error>?
    private var timeoutTask: Task<Void, Never>?
    private let onFinish: @MainActor () -> Void

    init(
        continuation: CheckedContinuation<JavaScriptValue, Error>,
        onFinish: @escaping @MainActor () -> Void
    ) {
        self.continuation = continuation
        self.onFinish = onFinish
    }

    func setTimeoutTask(_ task: Task<Void, Never>) {
        if finished {
            task.cancel()
            return
        }
        timeoutTask = task
    }

    func finish(_ result: Result<JavaScriptValue, Error>) {
        guard !finished else { return }
        finished = true
        let continuation = self.continuation
        self.continuation = nil
        let timeoutTask = self.timeoutTask
        self.timeoutTask = nil

        timeoutTask?.cancel()
        onFinish()
        switch result {
        case .success(let value):
            continuation?.resume(returning: value)
        case .failure(let error):
            continuation?.resume(throwing: error)
        }
    }
}

@MainActor
final class BrowserSession: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
    private static let keyboardSubmissionGate = KeyboardSubmissionGate()
    @Published private(set) var webView: WKWebView
    private(set) var configuredProxy: AccountProxy?
    private let webViewFactory: (WKWebViewConfiguration) -> WKWebView
    private var urlObservation: NSKeyValueObservation?
    @Published private(set) var currentURL: URL?
    @Published private(set) var isVisible = false
    @Published private(set) var blockedNavigationURL: URL?
    private var navigationResults: [ObjectIdentifier: Bool] = [:]
    private var navigationCancellationGeneration = 0
    var cancellationGeneration: Int { navigationCancellationGeneration }
    private var latestNavigation: WKNavigation?
    private var committedNavigation: WKNavigation?
    private var latestNavigationError: NSError?
    private var lastRequestedURL: URL?
    private var hasCommittedPage = false
    @Published private(set) var pageLoadMessage: String?
    @Published private(set) var operationMessage: String?
    var hasAttemptedRotationRecoveryOTP = false
    private var oauthPolicy: OAuthNavigationPolicy?
    @Published private(set) var oauthMessage: String?
    @Published private(set) var callbackURL: URL?
    private var callbackMode: OAuthCallbackMode = .automatic
    private var manualBrowsing = false
    var addressText: String { (callbackURL ?? currentURL)?.absoluteString ?? "" }

    func navigateAddress(_ text: String) -> Bool {
        openAddress(text, mode: callbackMode) != nil
    }
    private var javaScriptGates: [UUID: JavaScriptEvaluationGate] = [:]
    private let frameMessageRelay: BrowserFrameMessageRelay
    private var registeredChildFrames: [WKFrameInfo] = []

    init(
        dataStore: WKWebsiteDataStore,
        proxy: AccountProxy? = nil,
        webViewFactory: @escaping (WKWebViewConfiguration) -> WKWebView = {
            WKWebView(frame: .zero, configuration: $0)
        }
    ) {
        configuredProxy = proxy
        dataStore.proxyConfigurations = proxy.map { [$0.nativeConfiguration()] } ?? []
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = dataStore
        let frameMessageRelay = BrowserFrameMessageRelay()
        self.frameMessageRelay = frameMessageRelay
        configuration.userContentController.add(
            frameMessageRelay,
            contentWorld: .page,
            name: Self.frameRegistrationHandlerName)
        configuration.userContentController.addUserScript(WKUserScript(
            source: Self.closedShadowCaptureScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false,
            in: .page))
        self.webViewFactory = webViewFactory
        webView = webViewFactory(configuration)
        super.init()
        frameMessageRelay.session = self
        webView.navigationDelegate = self
        webView.uiDelegate = self
        observeURL()
    }

    private func observeURL() {
        urlObservation = webView.observe(\.url, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                guard let self, self.callbackURL == nil, let url = self.webView.url else { return }
                self.currentURL = url
            }
        }
    }

    convenience init(dataStoreID: UUID, proxy: AccountProxy? = nil) {
        self.init(dataStore: WKWebsiteDataStore(forIdentifier: dataStoreID), proxy: proxy)
    }

    func applyProxy(_ proxy: AccountProxy?) {
        guard configuredProxy != proxy else { return }
        cancelLoading()
        webView.configuration.websiteDataStore.proxyConfigurations = proxy.map { [$0.nativeConfiguration()] } ?? []
        configuredProxy = proxy
    }

    @discardableResult
    func load(_ url: URL) -> WKNavigation? {
        endOAuth()
        guard TrustedChatGPTOrigin.allowsTopLevelNavigation(url) else {
            blockedNavigationURL = url
            return nil
        }
        blockedNavigationURL = nil
        lastRequestedURL = url
        latestNavigationError = nil
        pageLoadMessage = nil
        let navigation = webView.load(URLRequest(url: url))
        latestNavigation = navigation
        return navigation
    }

    @discardableResult
    func loadOAuth(_ url: URL, mode: OAuthCallbackMode = .automatic) -> WKNavigation? {
        guard let policy = OAuthNavigationPolicy(authorizationURL: url) else { return nil }
        cancelLoading()
        endOAuth()
        oauthPolicy = policy
        callbackMode = mode
        oauthMessage = "Подтвердите вход для второго приложения на странице OpenAI."
        blockedNavigationURL = nil
        currentURL = url
        return webView.load(URLRequest(url: url))
    }

    @discardableResult
    func openAddress(_ text: String, mode: OAuthCallbackMode = .automatic) -> WKNavigation? {
        guard let url = BrowserAddress.url(from: text) else { return nil }
        if OAuthNavigationPolicy(authorizationURL: url) != nil {
            return loadOAuth(url, mode: mode)
        }
        // Explicit manual browsing never expands the credential automation origins.
        cancelLoading()
        endOAuth()
        manualBrowsing = true
        callbackMode = mode
        blockedNavigationURL = nil
        pageLoadMessage = nil
        currentURL = url
        return webView.load(URLRequest(url: url))
    }

    func endOAuth() {
        oauthPolicy = nil
        oauthMessage = nil
        callbackURL = nil
        manualBrowsing = false
    }

    func allowsNavigation(_ url: URL?) -> Bool {
        TrustedChatGPTOrigin.allowsTopLevelNavigation(url) ||
            oauthPolicy?.allowsCallback(url) == true ||
            (manualBrowsing && url.flatMap { BrowserAddress.url(from: $0.absoluteString) } != nil)
    }

    @discardableResult
    func reloadTrustedPage() -> WKNavigation? {
        // A provisional load can fail before WebKit has a document to reload.
        // Retry its original GET in the same cookie store instead of resetting login.
        if !hasCommittedPage, let lastRequestedURL,
           TrustedChatGPTOrigin.allowsTopLevelNavigation(lastRequestedURL) {
            cancelLoading()
            return load(lastRequestedURL)
        }
        guard TrustedChatGPTOrigin.allowsTopLevelNavigation(webView.url) else { return nil }
        blockedNavigationURL = nil
        latestNavigationError = nil
        pageLoadMessage = nil
        let navigation = webView.reloadFromOrigin()
        latestNavigation = navigation
        return navigation
    }

    var canReloadTrustedPage: Bool {
        TrustedChatGPTOrigin.allowsTopLevelNavigation(webView.url) ||
            (!hasCommittedPage && TrustedChatGPTOrigin.allowsTopLevelNavigation(lastRequestedURL))
    }

    var needsInitialPageLoad: Bool {
        webView.url == nil || (!hasCommittedPage && lastRequestedURL != nil)
    }

    func waitForNavigation(_ navigation: WKNavigation?, seconds: Int) async -> Bool {
        await waitForNavigation(navigation, seconds: seconds, acceptFirstDocument: false)
    }

    private func waitForNavigation(
        _ navigation: WKNavigation?, seconds: Int, acceptFirstDocument: Bool
    ) async -> Bool {
        guard let navigation else { return false }
        let identifier = ObjectIdentifier(navigation)
        let generation = navigationCancellationGeneration
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(seconds))
        while clock.now < deadline {
            if Task.isCancelled || generation != navigationCancellationGeneration {
                navigationResults.removeValue(forKey: identifier)
                return false
            }
            // Authentication can start once the first document has committed.
            // Analytics, images or another subresource may never finish loading.
            if acceptFirstDocument, committedNavigation === navigation,
               TrustedChatGPTOrigin.allowsTopLevelNavigation(webView.url) {
                navigationResults.removeValue(forKey: identifier)
                return true
            }
            if let succeeded = navigationResults.removeValue(forKey: identifier) {
                return succeeded
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        navigationResults.removeValue(forKey: identifier)
        return false
    }

    func loadInitialPage(_ url: URL, seconds: Int = 30, attempts: Int = 2) async -> Bool {
        guard !Task.isCancelled, TrustedChatGPTOrigin.allowsTopLevelNavigation(url) else { return false }
        let generation = navigationCancellationGeneration
        for attempt in 0..<max(1, attempts) {
            guard !Task.isCancelled, generation == navigationCancellationGeneration else { return false }
            let navigation = load(url)
            pageLoadMessage = attempt == 0
                ? "Открывается страница входа…"
                : "Восстанавливается соединение со страницей входа (попытка \(attempt + 1) из \(attempts))…"
            let finished = await waitForNavigation(navigation, seconds: seconds, acceptFirstDocument: true)
            guard !Task.isCancelled, generation == navigationCancellationGeneration else { return false }
            // Never reload a committed document: it may already contain a login
            // form, CAPTCHA, or an in-flight authentication redirect.
            if (finished || hasCommittedPage),
               TrustedChatGPTOrigin.allowsTopLevelNavigation(webView.url) {
                pageLoadMessage = nil
                return true
            }
            guard !hasCommittedPage, let navigation, latestNavigation === navigation,
                  blockedNavigationURL == nil else { return false }
            let error = latestNavigationError
            let transientCodes = [NSURLErrorTimedOut, NSURLErrorNetworkConnectionLost,
                                  NSURLErrorCannotConnectToHost, NSURLErrorCannotFindHost,
                                  NSURLErrorDNSLookupFailed, NSURLErrorNotConnectedToInternet]
            let canRetry = error.map {
                $0.domain == NSURLErrorDomain && transientCodes.contains($0.code)
            } ?? true
            // stopLoading cancels the request, but WebKit can reuse its stalled
            // HTTP/2 connection. A fresh ephemeral store gets a new connection.
            webView.stopLoading()
            guard canRetry, attempt + 1 < attempts else {
                pageLoadMessage = error.map { "Не удалось загрузить страницу (код \($0.code)). Нажмите «Обновить страницу»." }
                    ?? "Страница не ответила после повторной загрузки. Нажмите «Обновить страницу»."
                return false
            }
            pageLoadMessage = "Страница не ответила. Повторная загрузка…"
            do { try await Task.sleep(for: .milliseconds(300)) } catch { return false }
            guard !hasCommittedPage, latestNavigation === navigation,
                  blockedNavigationURL == nil else { return false }
            guard await recoverInitialConnection(navigation: navigation, generation: generation)
            else { return false }
        }
        return false
    }

    private func recoverInitialConnection(navigation: WKNavigation, generation: Int) async -> Bool {
        let original = webView
        func stillCurrent() -> Bool {
            !Task.isCancelled && generation == navigationCancellationGeneration &&
                webView === original && latestNavigation === navigation &&
                !hasCommittedPage && blockedNavigationURL == nil
        }
        guard stillCurrent() else { return false }
        // Persistent account profiles also contain local storage and other login
        // state. Keep them intact; only rebuild an uncommitted temporary browser.
        guard !original.configuration.websiteDataStore.isPersistent else { return true }
        let cookies = await original.configuration.websiteDataStore.httpCookieStore.allCookies()
        guard stillCurrent() else { return false }
        let store = WKWebsiteDataStore.nonPersistent()
        store.proxyConfigurations = original.configuration.websiteDataStore.proxyConfigurations
        for cookie in cookies {
            await store.httpCookieStore.setCookie(cookie)
            guard stillCurrent() else { return false }
        }
        let configuration = original.configuration.copy() as! WKWebViewConfiguration
        configuration.websiteDataStore = store
        let replacement = webViewFactory(configuration)
        original.navigationDelegate = nil
        original.uiDelegate = nil
        registeredChildFrames.removeAll()
        navigationResults.removeAll()
        latestNavigation = nil
        committedNavigation = nil
        latestNavigationError = nil
        currentURL = nil
        replacement.navigationDelegate = self
        replacement.uiDelegate = self
        webView = replacement
        observeURL()
        return true
    }

    func cancelLoading() {
        navigationCancellationGeneration &+= 1
        webView.stopLoading()
        let gates = Array(javaScriptGates.values)
        for gate in gates {
            gate.finish(.failure(CancellationError()))
        }
    }

    func evaluate(
        _ script: String,
        timeout: Duration = .seconds(8)
    ) async throws -> Any {
        guard TrustedChatGPTOrigin.allowsTopLevelNavigation(webView.url) else {
            throw BrowserSessionError.untrustedOrigin
        }
        return try await callJavaScript(script, in: nil, timeout: timeout)
    }

    func evaluateInTrustedChildFrames(
        _ script: String
    ) async -> [(frame: WKFrameInfo, value: Any)] {
        guard TrustedChatGPTOrigin.allowsTopLevelNavigation(webView.url) else {
            return []
        }
        var results: [(WKFrameInfo, Any)] = []
        for frame in registeredChildFrames where Self.allowsAuthentication(frame: frame) {
            do {
                let value = try await callJavaScript(script, in: frame)
                results.append((frame, value))
            } catch {}
        }
        return results
    }

    func evaluate(_ script: String, in frame: WKFrameInfo) async throws -> Any {
        guard TrustedChatGPTOrigin.allowsTopLevelNavigation(webView.url),
              Self.allowsAuthentication(frame: frame)
        else { throw BrowserSessionError.untrustedOrigin }
        return try await callJavaScript(script, in: frame)
    }

    private func callJavaScript(
        _ script: String,
        in frame: WKFrameInfo?,
        timeout: Duration = .seconds(8)
    ) async throws -> Any {
        let operationID = UUID()
        let value: JavaScriptValue = try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                let gate = JavaScriptEvaluationGate(
                    continuation: continuation,
                    onFinish: { [weak self] in
                        self?.javaScriptGates.removeValue(forKey: operationID)
                    })
                javaScriptGates[operationID] = gate
                guard !Task.isCancelled else {
                    gate.finish(.failure(CancellationError()))
                    return
                }
                let timeoutTask = Task { @MainActor in
                    try? await Task.sleep(for: timeout)
                    gate.finish(.failure(BrowserSessionError.evaluationTimedOut))
                }
                gate.setTimeoutTask(timeoutTask)
                webView.__callAsyncJavaScript(
                    "return await (\(script));",
                    arguments: [:],
                    inFrame: frame,
                    in: .page,
                    completionHandler: { value, error in
                        if let error {
                            gate.finish(.failure(error))
                        } else {
                            gate.finish(.success(JavaScriptValue(rawValue: value ?? NSNull())))
                        }
                    })
            }
        }, onCancel: { [weak self] in
            Task { @MainActor [weak self] in
                self?.javaScriptGates[operationID]?.finish(.failure(CancellationError()))
            }
        })
        return value.rawValue
    }

    func setVisible(_ value: Bool) {
        isVisible = value
    }

    func setOperationMessage(_ message: String?) {
        operationMessage = message
    }

    func waitUntilAttached(seconds: Int) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(seconds))
        while webView.window == nil, clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        return webView.window != nil
    }

    /// Native events are required by the birthday control's trusted key handlers.
    /// This only fills the scoped about-you form; it never presses Continue.
    func fillBirthdayUsingKeyboard(_ birthDate: String, expectedURL: URL, expectedName: String) async -> Bool {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        guard birthDate.range(of: #"^[0-9]{4}-[0-9]{2}-[0-9]{2}$"#, options: .regularExpression) != nil,
              let date = formatter.date(from: birthDate), formatter.string(from: date) == birthDate,
              date <= Date(), !expectedName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              TrustedChatGPTOrigin.allowsAuthentication(expectedURL),
              expectedURL.host?.lowercased() == "auth.openai.com", expectedURL.path == "/about-you"
        else { return false }
        let generation = cancellationGeneration
        let target = webView
        func current() -> Bool {
            !Task.isCancelled && cancellationGeneration == generation && webView === target &&
                isVisible && target.url == expectedURL
        }
        guard current() else { return false }
        for _ in 0..<100 where target.window == nil {
            do { try await Task.sleep(for: .milliseconds(20)) } catch { return false }
            guard current() else { return false }
        }
        guard current(), let window = target.window else { return false }
        let arguments = [expectedURL.absoluteString, expectedName, birthDate, "__birthdayKeyboard_" + UUID().uuidString]
        guard let encoded = try? JSONEncoder().encode(arguments), let json = String(data: encoded, encoding: .utf8) else { return false }
        var identityCaptured = false
        func checked(_ operation: String) async -> Bool {
            guard current(), target.window === window else { return false }
            let captureIdentity = !identityCaptured
            identityCaptured = true
            let identityCheck = """
            const identityElements = [owner, ...selected, hidden];
            if (\(captureIdentity)) Object.defineProperty(document, identityKey, {
              value: identityElements.map(element => new WeakRef(element)), configurable: true
            });
            const identity = document[identityKey];
            if (!Array.isArray(identity) || identity.length !== identityElements.length ||
                identity.some((reference, index) => reference.deref() !== identityElements[index])) return false;
            """
            let script = "(() => { const [expectedURL, expectedName, birthday, identityKey] = \(json);\n" + Self.birthdayKeyboardScope + "\n" + identityCheck + "\n" + operation + "\n})()"
            let result = try? await evaluate(script)
            return current() && target.window === window && result as? Bool == true
        }
        return await Self.keyboardSubmissionGate.withPermit {
            guard current(), target.window === window, await checked("return true;"), current() else { return false }
            let previousResponder = window.firstResponder
            guard window.makeFirstResponder(target) else { return false }
            defer {
                if window.firstResponder === target || (window.firstResponder as? NSView)?.isDescendant(of: target) == true {
                    _ = window.makeFirstResponder(previousResponder)
                }
            }
            let pieces = birthDate.split(separator: "-").map(String.init)
            for (part, value) in zip(["year", "month", "day"], pieces) {
                guard await checked("parts.\(part).focus(); return document.activeElement === parts.\(part);"), current() else { return false }
                try? await Task.sleep(for: .milliseconds(60))
                guard current(), await checked("return document.activeElement === parts.\(part);"), current(),
                      sendKey("\u{7f}", keyCode: 51, to: target, in: window) else { return false }
                // Await each event before checking focus: a segment can advance after its last digit.
                let digits = Array(value)
                for (index, digit) in digits.enumerated() {
                    guard await checked("return document.activeElement === parts.\(part);"), current(),
                          sendDigits(String(digit), to: target, in: window) else { return false }
                    try? await Task.sleep(for: .milliseconds(40))
                    guard current() else { return false }
                    let allowedFocus = index == digits.count - 1
                        ? "document.activeElement === parts.\(part) || document.activeElement === controls[controls.indexOf(parts.\(part)) + 1]"
                        : "document.activeElement === parts.\(part)"
                    guard await checked("return \(allowedFocus);"), current() else { return false }
                }
                guard await checked("return Number(parts.\(part).getAttribute('aria-valuenow')) === \(Int(value)!);"), current() else { return false }
            }
            guard await checked("if (Object.values(parts).includes(document.activeElement)) document.activeElement.blur(); return true;"), current() else { return false }
            try? await Task.sleep(for: .milliseconds(100))
            guard current() else { return false }
            return await checked("return hidden.value === birthday && ['year','month','day'].every((part, index) => Number(parts[part].getAttribute('aria-valuenow')) === Number(birthday.split('-')[index]));")
        }
    }

    private static let birthdayKeyboardScope = #"""
    if (location.href !== expectedURL || location.origin !== 'https://auth.openai.com' || location.pathname !== '/about-you') return false;
    const norm = value => String(value || '').trim().replace(/\s+/g, ' ').toLowerCase();
    const visible = element => {
      if (!element.getClientRects().length) return false;
      for (let node = element; node; node = node.parentElement) {
        const style = getComputedStyle(node);
        if (node.hidden || node.hasAttribute('inert') || node.getAttribute('aria-hidden') === 'true' ||
            style.display === 'none' || ['hidden','collapse'].includes(style.visibility) || style.opacity === '0') return false;
      }
      return true;
    };
    const enabled = element => !element.disabled && !element.readOnly && element.getAttribute('aria-disabled') !== 'true';
    const label = element => norm([element.name, element.id, element.getAttribute('autocomplete'), element.getAttribute('aria-label'),
      ...(element.getAttribute('aria-labelledby') || '').split(/\s+/).map(id => document.getElementById(id)?.textContent),
      ...[...(element.labels || [])].filter(visible).map(item => item.textContent)].join(' '));
    const birthdayLabel = value => /birth.?day|birth.?date|date.?of.?birth|bday|дата рождения|день рождения/.test(value);
    const controls = [...document.querySelectorAll('input,select,textarea,[contenteditable],[role="spinbutton"]')]
      .filter(element => visible(element) && enabled(element) && !['hidden','checkbox','radio','button','submit','reset'].includes(element.type) &&
        (['INPUT','SELECT','TEXTAREA'].includes(element.tagName) || element.isContentEditable || element.getAttribute('role') === 'spinbutton'));
    const names = controls.filter(element => element.tagName === 'INPUT' && /\bname\b|имя|full.?name|фио/.test(label(element)) && !/user.?name/.test(label(element)));
    if (controls.length !== 4 || names.length !== 1 || names[0].value !== expectedName || !names[0].form) return false;
    const owner = names[0].form;
    if (owner.action && new URL(owner.action, location.href).origin !== location.origin) return false;
    const groups = [...owner.querySelectorAll('[role="group"],fieldset')].filter(visible).filter(element =>
      birthdayLabel(label(element) + ' ' + norm(element.tagName === 'FIELDSET' ? element.querySelector('legend')?.textContent : '')));
    if (groups.length !== 1) return false;
    const parts = {};
    for (const part of ['year','month','day']) {
      const localized = {year:'год',month:'месяц',day:'день'}[part];
      const matches = controls.filter(element => groups[0].contains(element) && element.isContentEditable && element.getAttribute('role') === 'spinbutton' &&
        (element.getAttribute('data-type') === part || element.getAttribute('autocomplete') === 'bday-' + part ||
          new RegExp('(?:^|[\\s_-])(?:' + part + '|' + localized + ')(?:$|[\\s_-])').test(label(element))));
      if (matches.length !== 1) return false;
      parts[part] = matches[0];
    }
    const selected = [names[0], ...Object.values(parts)];
    if (new Set(selected).size !== 4 || controls.some(element => !selected.includes(element)) ||
        selected.some(element => element.closest('form') !== owner || (element.form && element.form !== owner))) return false;
    const hiddenDates = [...owner.querySelectorAll('input[type="hidden"]')].filter(element => birthdayLabel(label(element)));
    if (hiddenDates.length !== 1 || hiddenDates[0].form !== owner || !enabled(hiddenDates[0])) return false;
    const hidden = hiddenDates[0];
    """#

    /// Last-resort OTP input for the real MFA page when WebKit accessibility can
    /// focus the field but the page DOM temporarily exposes no input element.
    /// The caller must already have verified the trusted MFA origin.
    @discardableResult
    func submitMFAUsingKeyboard(_ value: String) async -> Bool {
        guard value.count == 6,
              value.allSatisfy(\.isNumber),
              isVisible,
              webView.window != nil,
              TrustedChatGPTOrigin.allowsAuthentication(webView.url),
              webView.url?.host?.lowercased() == "auth.openai.com",
              webView.url?.path.lowercased().hasPrefix("/mfa-challenge/") == true,
              let window = webView.window
        else { return false }

        return await Self.keyboardSubmissionGate.withPermit {
            guard !Task.isCancelled,
                  isVisible,
                  webView.window === window,
                  TrustedChatGPTOrigin.allowsAuthentication(webView.url),
                  webView.url?.host?.lowercased() == "auth.openai.com",
                  webView.url?.path.lowercased().hasPrefix("/mfa-challenge/") == true
            else { return false }
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            window.makeKey()
            guard window.makeFirstResponder(webView) else { return false }
            guard sendKey("\t", keyCode: 48, to: webView, in: window) else { return false }
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return false }
            if !insertText(value, into: webView) {
                guard sendDigits(value, to: webView, in: window) else { return false }
            }
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled, sendKey("\r", keyCode: 36, to: webView, in: window) else { return false }
            // Keep the shared keyboard slot until WebKit has consumed the
            // synthetic submit event; otherwise the next session can steal
            // focus while this form is still dispatching its submit handler.
            try? await Task.sleep(for: .milliseconds(250))
            return !Task.isCancelled
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard webView === self.webView else { return }
        currentURL = webView.url
        pageLoadMessage = nil
        if let url = webView.url, oauthPolicy?.allowsCallback(url) == true {
            callbackURL = url
            let hasError = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.contains { $0.name == "error" } == true
            oauthMessage = hasError
                ? "OpenAI вернул ошибку авторизации. Создайте новую ссылку в CodexAcc."
                : "Страница возврата открыта. Проверьте результат входа в CodexAcc."
        }
        if let navigation {
            navigationResults[ObjectIdentifier(navigation)] = true
        }
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        guard webView === self.webView else { return }
        registeredChildFrames.removeAll()
        latestNavigation = navigation
        latestNavigationError = nil
        if let url = webView.url { currentURL = url }
    }

    func webView(_ webView: WKWebView, didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!) {
        guard webView === self.webView else { return }
        if let url = webView.url { currentURL = url }
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        guard webView === self.webView else { return }
        hasCommittedPage = true
        committedNavigation = navigation
        currentURL = webView.url
        pageLoadMessage = nil
    }

    func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: any Error
    ) {
        guard webView === self.webView else { return }
        recordFailure(navigation, error: error)
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: any Error
    ) {
        guard webView === self.webView else { return }
        recordFailure(navigation, error: error)
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
        guard webView === self.webView else {
            decisionHandler(.cancel)
            return
        }
        let isTopLevel = navigationAction.targetFrame == nil ||
            navigationAction.targetFrame?.isMainFrame == true
        if isTopLevel, manualBrowsing, let url = navigationAction.request.url,
           let policy = OAuthNavigationPolicy(authorizationURL: url) {
            oauthPolicy = policy
            manualBrowsing = false
        }
        guard !isTopLevel || allowsNavigation(navigationAction.request.url)
        else {
            blockedNavigationURL = navigationAction.request.url
            if oauthPolicy != nil {
                oauthMessage = "Переход заблокирован: адрес не совпадает с OAuth-ссылкой. Создайте новую ссылку в CodexAcc."
            }
            decisionHandler(.cancel)
            return
        }
        if isTopLevel, let url = navigationAction.request.url {
            currentURL = url
            if oauthPolicy?.allowsCallback(url) == true {
                callbackURL = url
                if callbackMode == .copyLink {
                    oauthMessage = "Callback получен. Скопируйте адрес и вставьте в приложение, где начали вход."
                    decisionHandler(.cancel)
                    return
                }
            }
        }
        decisionHandler(.allow)
    }

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        guard webView === self.webView else { return nil }
        if navigationAction.targetFrame == nil, let requestURL = navigationAction.request.url {
            if allowsNavigation(requestURL) {
                _ = webView.load(URLRequest(url: requestURL))
            } else {
                blockedNavigationURL = requestURL
            }
        }
        return nil
    }

    private func recordFailure(_ navigation: WKNavigation?, error: Error) {
        let details = error as NSError
        if details.code != NSURLErrorCancelled,
           let failed = (details.userInfo[NSURLErrorFailingURLErrorKey] as? URL) ??
            (details.userInfo[NSURLErrorFailingURLStringErrorKey] as? String).flatMap(URL.init(string:)),
           allowsNavigation(failed) {
            currentURL = failed
            if oauthPolicy?.allowsCallback(failed) == true { callbackURL = failed }
        }
        if let navigation, latestNavigation === navigation {
            latestNavigationError = error as NSError
            if (error as NSError).code != NSURLErrorCancelled {
                pageLoadMessage = "Не удалось загрузить страницу (код \((error as NSError).code)). Нажмите «Обновить страницу»."
            }
        }
        if oauthPolicy != nil, (error as NSError).code != NSURLErrorCancelled {
            oauthMessage = callbackURL != nil
                ? "Callback получен, но страница возврата недоступна. Скопируйте адрес для ручного завершения входа."
                : "Страница не загрузилась. Проверьте адрес или получите новую ссылку входа."
        }
        if let navigation {
            navigationResults[ObjectIdentifier(navigation)] = false
        }
    }

    private func sendKey(
        _ characters: String,
        keyCode: UInt16,
        to responder: NSResponder,
        in window: NSWindow
    ) -> Bool {
        guard let down = keyEvent(
                type: .keyDown,
                characters: characters,
                keyCode: keyCode,
                windowNumber: window.windowNumber),
              let up = keyEvent(
                type: .keyUp,
                characters: characters,
                keyCode: keyCode,
                windowNumber: window.windowNumber)
        else { return false }
        // A background/pool WebView can live in a non-key window. Sending the
        // event through that window then silently drops it on macOS. Dispatch
        // to the responder we explicitly focused instead of consulting the
        // mutable window responder chain for every key.
        responder.keyDown(with: down)
        responder.keyUp(with: up)
        return true
    }

    private func sendDigits(_ value: String, to responder: NSResponder, in window: NSWindow) -> Bool {
        let keyCodes: [Character: UInt16] = [
            "0": 29, "1": 18, "2": 19, "3": 20, "4": 21,
            "5": 23, "6": 22, "7": 26, "8": 28, "9": 25
        ]
        for character in value {
            guard let keyCode = keyCodes[character],
                  sendKey(String(character), keyCode: keyCode, to: responder, in: window)
            else { return false }
        }
        return true
    }

    private func insertText(_ value: String, into responder: NSResponder) -> Bool {
        guard let inputClient = responder as? NSTextInputClient else {
            return false
        }
        inputClient.insertText(
            value,
            replacementRange: NSRange(location: NSNotFound, length: 0))
        return true
    }

    private func keyEvent(
        type: NSEvent.EventType,
        characters: String,
        keyCode: UInt16,
        windowNumber: Int
    ) -> NSEvent? {
        NSEvent.keyEvent(
            with: type,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: windowNumber,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode)
    }

    fileprivate func register(frame: WKFrameInfo) {
        guard !frame.isMainFrame,
              Self.allowsAuthentication(frame: frame),
              !registeredChildFrames.contains(where: { $0 === frame })
        else { return }
        registeredChildFrames.append(frame)
    }

    private static func allowsAuthentication(frame: WKFrameInfo) -> Bool {
        let origin = frame.securityOrigin
        guard origin.protocol.lowercased() == "https" else { return false }
        let host = origin.host.lowercased()
        return host == "auth.openai.com" || host == "chatgpt.com"
    }

    private static let frameRegistrationHandlerName = "gptAccountManagerFrame"

    private static let closedShadowCaptureScript = """
    (() => {
      window.webkit?.messageHandlers?.\(frameRegistrationHandlerName)?.postMessage(null);
      if (window.__gptAccountManagerShadowRoot) return;
      const roots = new WeakMap();
      const original = Element.prototype.attachShadow;
      Object.defineProperty(window, "__gptAccountManagerShadowRoot", {
        value: element => roots.get(element) || element.shadowRoot || null,
        configurable: false,
        enumerable: false,
        writable: false,
      });
      Element.prototype.attachShadow = function(init) {
        const root = original.call(this, init);
        roots.set(this, root);
        return root;
      };
    })();
    """
}

@MainActor
final class WebSessionManager {
    private struct SavedSession {
        let storeID: UUID
        let proxy: AccountProxy?
        let session: BrowserSession
    }
    private var sessions: [UUID: SavedSession] = [:]
    private let verificationSessionFactory: (@MainActor () -> BrowserSession)?
    private let accountSessionFactory: (@MainActor (UUID) -> BrowserSession)?
    private let proxyResolver: @MainActor (AccountRecord) -> AccountProxy?

    init(
        accountSessionFactory: (@MainActor (UUID) -> BrowserSession)? = nil,
        verificationSessionFactory: (@MainActor () -> BrowserSession)? = nil,
        proxyResolver: @escaping @MainActor (AccountRecord) -> AccountProxy? = { $0.proxy }
    ) {
        self.accountSessionFactory = accountSessionFactory
        self.verificationSessionFactory = verificationSessionFactory
        self.proxyResolver = proxyResolver
    }

    func existingSession(for account: AccountRecord) -> BrowserSession? {
        guard let saved = sessions[account.id], saved.storeID == account.browserStoreID,
              saved.proxy == proxyResolver(account) else { return nil }
        return saved.session
    }

    func session(for account: AccountRecord) -> BrowserSession {
        if let session = existingSession(for: account) { return session }
        sessions[account.id]?.session.cancelLoading()
        sessions[account.id]?.session.setVisible(false)
        let proxy = proxyResolver(account)
        let session = makeAccountSession(storeID: account.browserStoreID, proxy: proxy)
        sessions[account.id] = SavedSession(storeID: account.browserStoreID, proxy: proxy, session: session)
        return session
    }

    func resetSession(for account: AccountRecord) async -> BrowserSession {
        let original = session(for: account)
        original.cancelLoading()
        original.endOAuth()
        original.setVisible(false)
        await original.webView.configuration.websiteDataStore.removeData(
            ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
        let proxy = proxyResolver(account)
        let replacement = makeAccountSession(storeID: account.browserStoreID, proxy: proxy)
        sessions[account.id] = SavedSession(storeID: account.browserStoreID, proxy: proxy, session: replacement)
        return replacement
    }

    func verificationSession() -> BrowserSession {
        verificationSessionFactory?() ?? BrowserSession(dataStore: .nonPersistent())
    }

    func verificationSession(for account: AccountRecord) -> BrowserSession {
        let proxy = proxyResolver(account)
        guard let verificationSessionFactory else {
            return BrowserSession(dataStore: .nonPersistent(), proxy: proxy)
        }
        let session = verificationSessionFactory()
        session.applyProxy(proxy)
        return session
    }

    private func makeAccountSession(storeID: UUID, proxy: AccountProxy?) -> BrowserSession {
        guard let accountSessionFactory else {
            return BrowserSession(dataStoreID: storeID, proxy: proxy)
        }
        let session = accountSessionFactory(storeID)
        session.applyProxy(proxy)
        return session
    }
}
