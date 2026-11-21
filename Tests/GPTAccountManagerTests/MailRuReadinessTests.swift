import AppKit
import Foundation
import Testing
import WebKit
@testable import GPTAccountManager

@MainActor
private final class ReadinessWebView: WKWebView {
    var requests: [URLRequest] = []
    var inboxDelay = 0
    var messageDelay = 0
    var emailChangeMessage = false
    var forcedURL: URL?
    var keepLoading = false
    var stoppedLoads = 0
    var mailboxAddress = "owner@mail.ru"
    var deferFirstLoad = false
    var deferMessageLoads = false
    private var deferredNavigation: WKNavigation?
    private lazy var navigationSource = WKWebView()
    let receivedAt = Date().addingTimeInterval(-5)

    override var url: URL? { forcedURL ?? super.url }
    override var isLoading: Bool { keepLoading || super.isLoading }

    override func load(_ request: URLRequest) -> WKNavigation? {
        requests.append(request)
        if (deferFirstLoad && requests.count == 1) || (deferMessageLoads && MailRuOrigin.messageID(request.url) != nil) {
            deferredNavigation = navigationSource.loadHTMLString("<p>Pending navigation</p>", baseURL: nil)
            return deferredNavigation
        }
        forcedURL = request.url
        let html = MailRuOrigin.isInbox(request.url) ? inboxHTML : messageHTML
        return super.loadHTMLString(html, baseURL: request.url)
    }

    func commitDeferredInbox() {
        forcedURL = requests.first?.url
        super.loadHTMLString(inboxHTML, baseURL: forcedURL)
        navigationDelegate?.webView?(self, didCommit: deferredNavigation)
    }

    func show(_ html: String, at url: String) {
        forcedURL = URL(string: url)
        super.loadHTMLString(html, baseURL: forcedURL)
    }

    override func stopLoading() {
        stoppedLoads += 1
        super.stopLoading()
    }

    private var inboxHTML: String {
        let rows = ["1000", "1001"].map { id in
            """
            <tr class="messageline" id="msglist-\(id)">
              <td class="messageline__subject"><a class="messageline__link" href="/message/\(id)/?folder=0">Ваш код ChatGPT</a></td>
              <td class="messageline__date" title="Среда, 7 октября 2026, 01:20 +03:00">1:20</td>
            </tr>
            """
        }.joined()
        return """
        <html><head><title>Входящие - \(mailboxAddress) - Почта Mail.ru</title></head><body>
        <div id="mail" hidden><span>\(mailboxAddress)</span><a href="https://auth.mail.ru/cgi-bin/logout">Выйти</a>
        <table><tbody>\(rows)</tbody></table></div>
        <script>setTimeout(() => document.getElementById('mail').hidden = false, \(inboxDelay));</script>
        </body></html>
        """
    }

    private var messageHTML: String {
        let id = MailRuOrigin.messageID(forcedURL) ?? "1001"
        return """
        <html><body><table><tbody>
        <tr id="msgFieldFrom"><td><span class="val">ChatGPT &lt;noreply_at_tm_openai_com_fixture_123abc@icloud.com&gt;</span></td></tr>
        <tr id="msgFieldTo"><td><span class="val">Hide My Email &lt;alias@icloud.com&gt;</span></td></tr>
        </tbody></table><a href="/cgi-bin/getmsg?id=\(id)">Скачать</a>
        <div id="ReadMsgBody"><div id="MSG\(id)"><div id="viewmessagebody_BODY" class="mr_read__body__content" \(messageDelay > 0 ? "hidden" : "")>
        Введите код подтверждения, чтобы \(emailChangeMessage ? "изменить адрес электронной почты" : "завершить регистрацию"): \(id == "1000" ? "654321" : "123456").
        </div></div></div><script>setTimeout(()=>document.querySelector('#viewmessagebody_BODY').hidden=false,\(messageDelay));</script></body></html>
        """
    }

    var sourceScript: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        let headers = """
        Authentication-Results: mxs.mail.ru; dkim=pass header.d=icloud.com
        DKIM-Signature: v=1; d=icloud.com; h=From:To:Date:X-ICLOUD-HME; b=fixture
        From: ChatGPT <noreply_at_tm_openai_com_fixture_123abc@icloud.com>
        To: Hide My Email <alias@icloud.com>
        Date: \(formatter.string(from: receivedAt))
        X-ICLOUD-HME: p=alias@icloud.com; f=owner@mail.ru; r=to; s=noreply@tm.openai.com

        fixture body
        """
        let payload = String(data: try! JSONEncoder().encode(headers), encoding: .utf8)!
        return """
        window.fetch = async (url, options) => ({ok:true, url, body:new ReadableStream({start(controller) {
            controller.enqueue(new TextEncoder().encode(\(payload))); controller.close();
        }})});
        """
    }
}

@MainActor
@Suite(.serialized)
struct MailRuReadinessTests {
    private func fixture(timeouts: MailRuMailbox.Timeouts = .init()) -> (MailRuMailbox, ReadinessWebView) {
        _ = NSApplication.shared
        var view: ReadinessWebView!
        let mailbox = MailRuMailbox(expectedMailbox: "owner@mail.ru", timeouts: timeouts) { configuration in
            configuration.websiteDataStore = .nonPersistent()
            view = ReadinessWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 700), configuration: configuration)
            configuration.userContentController.addUserScript(WKUserScript(
                source: view.sourceScript, injectionTime: .atDocumentStart,
                forMainFrameOnly: true, in: .defaultClient))
            return view
        }
        return (mailbox, view)
    }

    @Test(arguments: [false, true])
    func awaitingCodeOpensInboxWithoutReplacingSavedBaseline(fromMessage: Bool) async throws {
        let (mailbox, view) = fixture()
        if fromMessage {
            _ = view.load(URLRequest(url: URL(string: "https://e.mail.ru/message/999/?folder=0")!))
            try await waitForDocument(view)
            view.requests.removeAll()
        }
        let code = try await mailbox.waitForCode(alias: "alias@icloud.com",
            since: view.receivedAt.addingTimeInterval(-5), excluding: ["1000"], purpose: .registration)
        #expect(code == MailVerificationCode(messageID: "1001", code: "123456"))
        #expect(MailRuOrigin.isInbox(view.requests.first?.url))
        #expect(!view.requests.contains { MailRuOrigin.messageID($0.url) == "1000" })
        #expect(view.requests.contains { MailRuOrigin.messageID($0.url) == "1001" })
    }

    @Test func captureBaselineOpensInboxAndWaitsForRenderedMailbox() async throws {
        let (mailbox, view) = fixture()
        view.inboxDelay = 250
        #expect(try await mailbox.captureBaseline() == ["1000", "1001"])
        #expect(view.requests.count == 1)
    }

    @Test func pendingInboxReadinessExpiresAsTimeoutWithoutReloading() async {
        let (mailbox, view) = fixture(timeouts: .init(readiness: .milliseconds(150)))
        view.deferFirstLoad = true
        await #expect(throws: MailVerificationError.timedOut) { try await mailbox.captureBaseline() }
        #expect(view.requests.count == 1)
    }

    @Test func pendingMessageNavigationExpiresAsTimeout() async throws {
        let (mailbox, view) = fixture(timeouts: .init(navigation: .milliseconds(150)))
        #expect(try await mailbox.captureBaseline() == ["1000", "1001"])
        view.deferMessageLoads = true
        await #expect(throws: MailVerificationError.timedOut) {
            try await mailbox.waitForCode(alias: "alias@icloud.com",
                since: view.receivedAt.addingTimeInterval(-5), excluding: ["1000"])
        }
        #expect(view.requests.filter { MailRuOrigin.messageID($0.url) == "1001" }.count == 1)
    }

    @Test func stalledMessageReadExpiresAsTimeout() async throws {
        let (mailbox, view) = fixture(timeouts: .init(evaluation: .milliseconds(300)))
        #expect(try await mailbox.captureBaseline() == ["1000", "1001"])
        view.configuration.userContentController.addUserScript(WKUserScript(
            source: "window.fetch = () => new Promise(() => {});", injectionTime: .atDocumentStart,
            forMainFrameOnly: true, in: .defaultClient))
        await #expect(throws: MailVerificationError.timedOut) {
            try await mailbox.waitForCode(alias: "alias@icloud.com",
                since: view.receivedAt.addingTimeInterval(-5), excluding: ["1000"])
        }
        #expect(view.requests.filter { MailRuOrigin.messageID($0.url) == "1001" }.count == 1)
    }

    @Test(arguments: [
        "<header><button>owner@mail.ru</button><button>other@mail.ru</button></header><main>No messages</main>",
        """
        <title>Входящие - owner@mail.ru - Почта Mail.ru</title>
        <span>owner@mail.ru</span><a href="https://auth.mail.ru/cgi-bin/logout">Выйти</a>
        <table><tr class="messageline" id="msglist-1001"><td>
          <a class="messageline__link" href="/message/9999/?folder=0">Invalid row</a>
        </td></tr></table>
        """
    ])
    func malformedRenderedInboxDoesNotBecomeRetryableTimeout(content: String) async throws {
        let (mailbox, view) = fixture(timeouts: .init(readiness: .milliseconds(300)))
        view.show("<html><body>\(content)</body></html>", at: "https://e.mail.ru/inbox/")
        try await waitForDocument(view)
        await #expect(throws: MailVerificationError.unsupportedLayout) { try await mailbox.captureBaseline() }
        #expect(view.requests.isEmpty)
    }

    @Test func emailChangePollingWaitsForMessageBodyAfterNavigationFinishes() async throws {
        let (mailbox, view) = fixture()
        view.messageDelay = 600
        view.emailChangeMessage = true
        let task = Task {
            try await mailbox.waitForCode(alias: "alias@icloud.com",
                since: view.receivedAt.addingTimeInterval(-5), excluding: ["1000"])
        }
        let timeout = Task {
            try? await Task.sleep(for: .seconds(5))
            if !Task.isCancelled { mailbox.cancel() }
        }
        defer { timeout.cancel(); task.cancel() }
        let code = try await task.value
        #expect(code == MailVerificationCode(messageID: "1001", code: "123456"))
        #expect(view.requests.filter { MailRuOrigin.messageID($0.url) == "1001" }.count == 1)
    }

    @Test func readingCheckExercisesInboxSearchWithoutExposingCode() async throws {
        let (mailbox, view) = fixture()
        view.messageDelay = 400
        view.emailChangeMessage = true
        _ = view.load(URLRequest(url: URL(string: "https://e.mail.ru/message/1001/?folder=0")!))
        try await waitForDocument(view)
        await mailbox.checkReading()
        #expect(mailbox.lastReadingCheck?.contains("Проверка пройдена") == true)
        #expect(mailbox.lastReadingCheck?.contains("123456") == false)
        #expect(!view.requests.contains { MailRuOrigin.messageID($0.url) == "1000" })
        #expect(view.requests.filter { MailRuOrigin.messageID($0.url) == "1001" }.count == 2)
        mailbox.openInbox()
        #expect(mailbox.lastReadingCheck == nil)
    }

    @Test func pendingStartupNavigationWithNoURLDoesNotLoadTwice() async throws {
        let (mailbox, view) = fixture()
        view.deferFirstLoad = true
        mailbox.ensureLoaded()
        #expect(view.url == nil)
        #expect(!view.isLoading)
        let baseline = Task { try await mailbox.captureBaseline() }
        try await Task.sleep(for: .milliseconds(150))
        #expect(view.requests.count == 1)
        view.commitDeferredInbox()
        #expect(try await baseline.value == ["1000", "1001"])
        #expect(view.requests.count == 1)
    }

    @Test func verifiedInboxDoesNotWaitForSlowSubresources() async throws {
        let (mailbox, view) = fixture()
        mailbox.ensureLoaded()
        view.keepLoading = true
        #expect(try await mailbox.captureBaseline() == ["1000", "1001"])
        #expect(view.requests.count == 1)
    }

    @Test(arguments: [false, true])
    func cancellingPendingReadinessStopsWithoutReloading(cancelTask: Bool) async throws {
        let (mailbox, view) = fixture()
        view.deferFirstLoad = true
        let baseline = Task { try await mailbox.captureBaseline() }
        try await Task.sleep(for: .milliseconds(150))
        if cancelTask { baseline.cancel() } else { mailbox.cancel() }
        await #expect(throws: MailVerificationError.cancelled) { try await baseline.value }
        #expect(view.requests.count == 1)
        #expect(view.stoppedLoads == 1)
    }

    @Test(arguments: ["https://e.mail.ru/login", "https://e.mail.ru/inbox/", "https://id.vk.ru/auth"])
    func visibleSignInIsNeverReloaded(url: String) async throws {
        let (mailbox, view) = fixture()
        view.show("<html><body><input type='password' value='fixture'><input name='login'></body></html>", at: url)
        try await waitForDocument(view)
        await #expect(throws: MailVerificationError.signInRequired) { try await mailbox.captureBaseline() }
        #expect(view.requests.isEmpty)
    }

    @Test func wrongMailboxAndUntrustedOriginStayBlocked() async throws {
        let (mailbox, view) = fixture()
        view.mailboxAddress = "other@mail.ru"
        await #expect(throws: MailVerificationError.unsupportedLayout) { try await mailbox.captureBaseline() }
        #expect(view.requests.count == 1)
        view.forcedURL = URL(string: "https://attacker.example/inbox/")
        await #expect(throws: MailVerificationError.untrustedOrigin) { try await mailbox.captureBaseline() }
        #expect(view.requests.count == 1)
    }

    @Test(arguments: ["<input autofocus><script>document.querySelector('input').focus()</script>", "<div id='captcha'>Проверка</div>"])
    func editingAndCaptchaAreNeverReloaded(content: String) async throws {
        let (mailbox, view) = fixture()
        view.show("<html><body>\(content)</body></html>", at: "https://e.mail.ru/settings")
        try await waitForDocument(view)
        await #expect(throws: MailVerificationError.unsupportedLayout) { try await mailbox.captureBaseline() }
        #expect(view.requests.isEmpty)
    }

    @Test func firstInboxPageWithObservedSortIsReadyWithoutReloading() async throws {
        let (mailbox, view) = fixture()
        let url = URL(string: "https://e.mail.ru/messages/inbox?page=1&sortby=A")!
        _ = view.load(URLRequest(url: url))
        try await waitForDocument(view)
        let code = try await mailbox.waitForCode(alias: "alias@icloud.com",
            since: view.receivedAt.addingTimeInterval(-5), excluding: ["1000"], purpose: .registration)
        #expect(code.code == "123456")
        #expect(view.requests[1].url?.path == "/message/1001")
        #expect(view.requests.last?.url == url)
        for query in ["page=2&sortby=A", "page=1&sortby=B", "page=1&page=1&sortby=A", "page=1&sortby=A&next=evil"] {
            #expect(!MailRuOrigin.isInbox(URL(string: "https://e.mail.ru/messages/inbox?\(query)")))
        }
    }

    private func waitForDocument(_ view: WKWebView) async throws {
        for _ in 0..<60 {
            if !view.isLoading, (try? await view.evaluateJavaScript("document.readyState")) as? String == "complete" { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw MailVerificationError.unsupportedLayout
    }
}
