import AppKit
import Foundation
import Testing
import WebKit
@testable import GPTAccountManager

@MainActor
private final class LocalEmailFlowWebView: WKWebView {
    var fixtureHTML = ""
    var requestedURLs: [URL] = []

    override func load(_ request: URLRequest) -> WKNavigation? {
        if let url = request.url { requestedURLs.append(url) }
        return super.loadHTMLString(fixtureHTML, baseURL: request.url)
    }
}

@MainActor
private final class LocalEmailMailbox: EmailCodeReceiving {
    var baselineCalls = 0
    var codeCalls = 0
    var beforeReturningCode: ((String, Date, Set<String>) throws -> Void)?

    func captureBaseline() async throws -> Set<String> {
        baselineCalls += 1
        return ["old-message"]
    }

    func waitForCode(alias: String, since: Date, excluding: Set<String>) async throws -> MailVerificationCode {
        codeCalls += 1
        try beforeReturningCode?(alias, since, excluding)
        return MailVerificationCode(messageID: "fresh-message", code: "123456")
    }

    func cancel() {}
}

@MainActor
private final class LocalEmailUnusedChecker: SubscriptionChecking {
    var activeSession: BrowserSession?
    var calls = 0

    func check(account: AccountRecord) async -> SubscriptionCheckOutcome {
        calls += 1
        return .failure("Subscription check is outside this local email fixture")
    }
}

@MainActor
private final class LocalEmailNavigationBlocker: NSObject, WKNavigationDelegate {
    var blockedURLs: [URL] = []

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
        if let url = navigationAction.request.url { blockedURLs.append(url) }
        decisionHandler(.cancel)
    }
}

@MainActor
@Suite(.serialized)
struct EmailEndToEndTests {
    // Local DOM + mocked mailbox/identity integration. This does not exercise
    // OpenAI OAuth, credential login, Mail.ru, or any external network service.
    @Test(arguments: [false, true])
    func localEmailWorkflowCommitsOnlyMatchingVerificationIdentity(wrongVerificationUser: Bool) async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AccountStore(fileURL: directory.appendingPathComponent("accounts.json"))
        try store.merge([.init(email: "old@example.com", password: "fixture-password", totpSecret: "JBSWY3DPEHPK3PXP")])
        let group = try store.createGroup(name: "Local email fixture", tag: "preserved")
        let id = try #require(store.accounts.first?.id)
        try store.moveAccounts(ids: [id], to: group.id, protectedIDs: [])
        try store.importEmailAliases("new-fixture@icloud.com\nunused-fixture@icloud.com")
        let before = try #require(store.accounts.first)
        let reservation = try store.reserveEmailChange(id: id, alias: "new-fixture@icloud.com")

        let original = BrowserSession(dataStore: .nonPersistent()) { configuration in
            let web = LocalEmailFlowWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
            web.fixtureHTML = Self.settingsHTML
            return web
        }
        let initialURL = URL(string: "https://chatgpt.com/#settings/Account")!
        let navigation = original.load(initialURL)
        #expect(await original.waitForNavigation(navigation, seconds: 5))
        let browser = ChatGPTAutomation(sessionManager: WebSessionManager(accountSessionFactory: { _ in original }))
        let mailbox = LocalEmailMailbox()
        let automation = EmailChangeAutomation(browser: browser, mailbox: mailbox)
        defer { automation.cancel() }

        // Prepare a local verification page through the existing recovery API;
        // the persisted operation stays reserved until the real automation runs.
        var verificationAccount = try #require(store.accounts.first)
        verificationAccount.pendingEmailChange?.phase = .confirming
        #expect(automation.resetVerificationSession(for: verificationAccount))
        let verification = try #require(automation.browserSession(for: verificationAccount))
        #expect(verification !== original)
        #expect(!verification.webView.configuration.websiteDataStore.isPersistent)
        verification.webView.navigationDelegate = nil
        verification.webView.loadHTMLString("""
        \(Self.networkIsolation)
        <p>Local verification identity</p>
        <script>
          window.fetch = async url => {
            if (url !== '/api/auth/session') throw new Error('Unexpected fixture request');
            return {ok:true,json:async()=>({user:{email:'new-fixture@icloud.com',id:'\(wrongVerificationUser ? "different-user" : "stable-user")'}})};
          };
          window.localFixtureReady = true;
        </script>
        """, baseURL: URL(string: "https://chatgpt.com/")!)
        var verificationReady = false
        for _ in 0..<100 {
            if (try? await verification.evaluate("window.localFixtureReady === true")) as? Bool == true {
                verificationReady = true
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(verificationReady)
        let blocker = LocalEmailNavigationBlocker()
        verification.webView.navigationDelegate = blocker
        defer { verification.webView.navigationDelegate = nil }
        #expect(store.accounts.first?.pendingEmailChange?.phase == .reserved)

        mailbox.beforeReturningCode = { alias, since, excluding in
            #expect(alias == reservation.newEmail)
            #expect(excluding == ["old-message"])
            let disk = AccountStore(fileURL: store.fileURL)
            try disk.load()
            let checkpoint = try #require(disk.accounts.first?.pendingEmailChange)
            #expect(checkpoint.phase == .requested)
            #expect(checkpoint.operationID == reservation.operationID)
            #expect(checkpoint.originalUserID == "stable-user")
            #expect(checkpoint.requestedAt == since)
            #expect(checkpoint.requestAttemptID != nil)
            #expect(checkpoint.baselineMessageIDs == excluding)
            #expect(disk.accounts.first?.email == before.email)
            #expect(disk.emailAliases.first?.status == .reserved)
        }
        let checker = LocalEmailUnusedChecker()
        let coordinator = OperationCoordinator(store: store, checker: checker, emailChanger: automation)
        let timeout = Task {
            do { try await Task.sleep(for: .seconds(15)) } catch { return }
            Issue.record("Local email workflow did not finish within 15 seconds")
            coordinator.stop()
        }
        defer { timeout.cancel() }
        await coordinator.continueEmailChange(id: id)

        let submitted = try #require(try await original.evaluate("({opens:window.opens,email:window.submittedEmail,emailSubmissions:window.emailSubmissions,code:window.submittedCode,codeSubmissions:window.codeSubmissions})") as? [String: Any])
        #expect(submitted["opens"] as? Int == 1)
        #expect(submitted["email"] as? String == reservation.newEmail)
        #expect(submitted["emailSubmissions"] as? Int == 1)
        #expect(submitted["code"] as? String == "123456")
        #expect(submitted["codeSubmissions"] as? Int == 1)
        #expect(mailbox.baselineCalls == 2 && mailbox.codeCalls == 1)
        #expect(checker.calls == 0)
        #expect(blocker.blockedURLs.isEmpty)
        let originalWeb = try #require(original.webView as? LocalEmailFlowWebView)
        #expect(originalWeb.requestedURLs == [initialURL])
        #expect(!coordinator.isRunning)

        let reloaded = AccountStore(fileURL: store.fileURL)
        try reloaded.load()
        #expect(reloaded.accounts == store.accounts)
        #expect(reloaded.emailAliases == store.emailAliases)
        let after = try #require(reloaded.accounts.first)
        #expect(after.id == before.id && after.browserStoreID == before.browserStoreID)
        #expect(after.password == before.password && after.totpSecret == before.totpSecret)
        #expect(after.groupID == before.groupID && after.tag == before.tag)
        #expect(after.pendingPassword == nil && after.pendingTOTPSecret == nil && after.rotationStage == nil)
        #expect(reloaded.groups == [group])
        #expect(reloaded.emailAliases[0].accountID == id)
        #expect(reloaded.emailAliases[1].status == .available)
        if wrongVerificationUser {
            #expect(after.email == before.email)
            #expect(after.pendingEmailChange?.phase == .confirming)
            #expect(after.pendingEmailChange?.operationID == reservation.operationID)
            #expect(after.pendingEmailChange?.originalUserID == "stable-user")
            #expect(reloaded.emailAliases[0].status == .reserved)
            #expect(coordinator.completedCount == 0)
        } else {
            #expect(after.email == reservation.newEmail)
            #expect(after.pendingEmailChange == nil)
            #expect(reloaded.emailAliases[0].status == .used)
            #expect(coordinator.completedCount == 1)
        }
    }

    private static let networkIsolation = """
    <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; form-action 'none'">
    """

    private static let settingsHTML = """
    \(networkIsolation)
    <main id="flow"><button aria-label="Change email address: old@example.com" onclick="openEmail()">Edit</button></main>
    <script>
      window.opens = 0;
      window.emailSubmissions = 0;
      window.codeSubmissions = 0;
      window.fetch = async url => {
        if (url !== '/api/auth/session') throw new Error('Unexpected fixture request');
        return {ok:true,json:async()=>({user:{email:window.codeSubmissions ? 'new-fixture@icloud.com' : 'old@example.com',id:'stable-user'}})};
      };
      function openEmail() {
        window.opens++;
        document.getElementById('flow').innerHTML = `<section>
          <div><span>Изменить адрес электронной почты</span>
            <button aria-label="Закрыть модальное окно редактирования электронной почты">×</button></div>
          <p>Введите свой новый адрес электронной почты. Мы отправим код подтверждения, чтобы подтвердить изменение.</p>
          <label>Адрес электронной почты<input type="email" required
            oninput="setTimeout(()=>document.getElementById('send-email').disabled=false,50)"></label>
          <button>Отменить</button>
          <button id="send-email" disabled onclick="sendEmail(document.getElementById('flow'))">Отправить письмо с подтверждением</button>
        </section>`;
      }
      function sendEmail(form) {
        window.submittedEmail = form.querySelector('input').value;
        window.emailSubmissions++;
        document.getElementById('flow').innerHTML = `<section><div><span>Добавить адрес электронной почты</span>
          <button aria-label="Закрыть модальное окно добавления адреса электронной почты">×</button></div>
          <p>Введите 6-значный код, который мы только что отправили на new-fixture@icloud.com, чтобы подтвердить вашу почту.</p>
          <p>Подтвердив этот адрес электронной почты, вы выйдете из системы на всех устройствах, чтобы мы могли завершить обновление вашей учетной записи. После этого вам нужно будет снова войти в систему.</p>
          <input aria-label="Код подтверждения" placeholder="Введите код" required
            oninput="setTimeout(()=>document.getElementById('verify-email').disabled=false,50)">
          <button>Отправить еще раз</button><button>Назад</button>
          <button id="verify-email" disabled onclick="confirmEmail(document.getElementById('flow'))">Проверить</button>
        </section>`;
      }
      function confirmEmail(form) {
        window.submittedCode = form.querySelector('input').value;
        window.codeSubmissions++;
      }
    </script>
    """
}
