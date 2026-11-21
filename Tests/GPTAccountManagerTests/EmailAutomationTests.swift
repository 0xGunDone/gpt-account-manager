import AppKit
import Foundation
import Testing
import WebKit
@testable import GPTAccountManager

@MainActor
private final class EmailFixtureWebView: WKWebView {
    var fixtureHTML = "<p>Local fixture</p>"
    var loadedURLs: [URL] = []

    override func load(_ request: URLRequest) -> WKNavigation? {
        if let url = request.url { loadedURLs.append(url) }
        return super.loadHTMLString(fixtureHTML, baseURL: request.url)
    }
}

@MainActor
private final class EmailFixtureMailbox: EmailCodeReceiving {
    var baselineCalls = 0
    var codeCalls = 0
    var baselineResult: Set<String>?
    func captureBaseline() async throws -> Set<String> {
        baselineCalls += 1
        if let baselineResult { return baselineResult }
        throw MailVerificationError.baselineRequired
    }
    func waitForCode(alias: String, since: Date, excluding: Set<String>) async throws -> MailVerificationCode {
        codeCalls += 1
        throw MailVerificationError.baselineRequired
    }
    func cancel() {}
}

@MainActor
private final class EmailFixtureChanger: EmailChanging {
    let session: BrowserSession
    init(session: BrowserSession) { self.session = session }
    func prepareSession(for account: AccountRecord) {}
    func browserSession(for account: AccountRecord) -> BrowserSession? { session }
    func cancel() {}
    func changeEmail(account: AccountRecord, onCheckpoint: @escaping @MainActor (PendingEmailChange) throws -> Void) async -> EmailChangeOutcome {
        guard var pending = account.pendingEmailChange else { return .failure("Missing reservation") }
        do {
            pending.originalUserID = "user-fixture"
            pending.requestedAt = Date(timeIntervalSince1970: 1_700_000_000)
            pending.phase = .requested
            try onCheckpoint(pending)
            pending.phase = .confirming
            try onCheckpoint(pending)
            return .success(.init(email: pending.newEmail, userID: "user-fixture"))
        } catch { return .failure("Checkpoint failed") }
    }
}

@MainActor
private final class EmailFixtureChecker: SubscriptionChecking {
    var activeSession: BrowserSession?
    init(session: BrowserSession) { activeSession = session }
    func check(account: AccountRecord) async -> SubscriptionCheckOutcome {
        .success(.init(signedInEmail: account.email, planLabel: "plus", activeUntil: nil, willRenew: nil))
    }
}

@MainActor
private final class EmailFixtureAccountSessions: AccountSessionProviding {
    let session: BrowserSession
    init(session: BrowserSession) { self.session = session }
    func accountSession(for account: AccountRecord) -> BrowserSession { session }
    func existingAccountSession(for account: AccountRecord) -> BrowserSession? { session }
}

@MainActor
private final class EmailFixtureRotator: TwoFARotating {
    let session: BrowserSession
    private var started = false
    init(session: BrowserSession) { self.session = session }
    func browserSession(for account: AccountRecord) -> BrowserSession? { started ? session : nil }
    func rotate2FA(account: AccountRecord, onCheckpoint: @escaping @MainActor (RotationCheckpointEvent) throws -> Void) async -> TwoFARotationOutcome {
        started = true
        return .manualActionRequired(stage: nil, message: "Fixture challenge")
    }
}

@MainActor
@Suite(.serialized)
struct EmailAutomationTests {
    private func session(html: String = "<p>Local fixture</p>") -> BrowserSession {
        _ = NSApplication.shared
        return BrowserSession(dataStore: .nonPersistent()) { configuration in
            let web = EmailFixtureWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
            web.fixtureHTML = html
            return web
        }
    }

    private func identityFixture(_ payload: String, ok: Bool = true) async throws -> BrowserSession {
        let value = session(html: """
        <p>Identity fixture</p><script>
        window.fetch = async () => ({ok: \(ok), json: async () => (\(payload))});
        </script>
        """)
        let navigation = value.load(URL(string: "https://chatgpt.com/")!)
        #expect(await value.waitForNavigation(navigation, seconds: 5))
        return value
    }

    private func store() throws -> AccountStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let value = AccountStore(fileURL: directory.appendingPathComponent("accounts.json"))
        try value.merge([.init(email: "old@example.com", password: "fixture-password", totpSecret: "JBSWY3DPEHPK3PXP")])
        try value.importEmailAliases("new@icloud.com")
        return value
    }

    private func pendingAccount(phase: EmailChangePhase) -> AccountRecord {
        var account = AccountRecord(credential: .init(email: "old@example.com", password: "fixture-password", totpSecret: "JBSWY3DPEHPK3PXP"))
        account.pendingEmailChange = PendingEmailChange(
            aliasID: UUID(), originalEmail: account.email, newEmail: "new@icloud.com", phase: phase,
            baselineMessageIDs: ["existing-message"], requestedAt: Date(timeIntervalSince1970: 1_700_000_000), originalUserID: "user-fixture")
        return account
    }

    @Test func emailVerificationKeepsResolvedAccountProxy() throws {
        let proxy = AccountProxy(scheme: .socks5, host: "127.0.0.1", port: 1080)
        var account = pendingAccount(phase: .confirming)
        account.proxy = proxy
        let browser = ChatGPTAutomation(sessionManager: WebSessionManager())
        let automation = EmailChangeAutomation(browser: browser, mailbox: EmailFixtureMailbox())
        #expect(automation.resetVerificationSession(for: account))
        let verification = try #require(automation.browserSession(for: account))
        #expect(verification.configuredProxy == proxy)
        #expect(!verification.webView.configuration.websiteDataStore.isPersistent)
        #expect(verification.webView.configuration.websiteDataStore.proxyConfigurations.count == 1)
        #expect(browser.accountSession(for: account).configuredProxy == proxy)
    }

    @Test func identityUsesUserIDInsteadOfWorkspaceID() async throws {
        let fixture = try await identityFixture("{user:{email:'new@icloud.com',id:'user-fixture',account_id:'workspace-fixture'},account:{id:'workspace-fixture'}}")
        let proof = try await EmailChangeAutomation.identity(in: fixture)
        #expect(proof == .init(email: "new@icloud.com", userID: "user-fixture"))
    }

    @Test func identityRejectsMissingMalformedAndWorkspaceOnlyUserIDs() async throws {
        let payloads = [
            "{user:{email:'new@icloud.com',account_id:'workspace-fixture'},account:{id:'workspace-fixture'}}",
            "{user:{email:'new@icloud.com',id:''}}",
            "{user:{email:'new@icloud.com',id:42}}",
            "{user:{email:'',id:'user-fixture'}}",
            "{account:{email:'new@icloud.com',id:'workspace-fixture'}}"
        ]
        for payload in payloads {
            let fixture = try await identityFixture(payload)
            await #expect(throws: (any Error).self) { try await EmailChangeAutomation.identity(in: fixture) }
        }
        let rejected = try await identityFixture("{user:{email:'new@icloud.com',id:'user-fixture'}}", ok: false)
        await #expect(throws: (any Error).self) { try await EmailChangeAutomation.identity(in: rejected) }
    }

    @Test func authenticatedDifferentUserCannotCommitEmailChange() async throws {
        let store = try store()
        let id = try #require(store.accounts.first?.id)
        var pending = try store.reserveEmailChange(id: id)
        pending.originalUserID = "user-fixture"
        pending.requestedAt = Date(timeIntervalSince1970: 1_700_000_000)
        pending.phase = .requested
        try store.checkpointEmailChange(id: id, change: pending)
        pending.phase = .confirming
        try store.checkpointEmailChange(id: id, change: pending)
        let fixture = try await identityFixture("{user:{email:'new@icloud.com',id:'different-user'},account:{id:'user-fixture'}}")
        let proof = try await EmailChangeAutomation.identity(in: fixture)
        #expect(throws: AccountStoreError.emailChangeVerificationFailed) {
            try store.completeEmailChange(id: id, proof: proof)
        }
        #expect(store.accounts.first?.email == "old@example.com")
        #expect(store.accounts.first?.pendingEmailChange == pending)
        #expect(store.emailAliases.first?.status == .reserved)
    }

    @Test(arguments: ["check", "oauth", "rotation"])
    func nextOperationOwnsDisplayedSessionAfterEmailSuccess(operation: String) async throws {
        let store = try store()
        let id = try #require(store.accounts.first?.id)
        let emailSession = session()
        let checkSession = session()
        let accountSession = session()
        let rotationSession = session()
        let checker = EmailFixtureChecker(session: checkSession)
        let changer = EmailFixtureChanger(session: emailSession)
        let coordinator = OperationCoordinator(store: store, checker: checker,
                                              rotator: EmailFixtureRotator(session: rotationSession),
                                              accountSessions: EmailFixtureAccountSessions(session: accountSession),
                                              emailChanger: changer)
        await coordinator.changeEmail(id: id)
        #expect(store.accounts.first?.email == "new@icloud.com")
        #expect(store.accounts.first?.pendingEmailChange == nil)
        #expect(coordinator.browserSession(for: id) === emailSession)

        switch operation {
        case "check":
            await coordinator.check(id: id)
            #expect(coordinator.browserSession(for: id) === checkSession)
        case "oauth":
            #expect(await coordinator.openOAuthURL(for: id, text: "https://auth.openai.com/oauth/authorize?client_id=fixture&redirect_uri=http%3A%2F%2Flocalhost%3A1%2Fcallback&state=fixture", mode: .copyLink) == nil)
            #expect(coordinator.browserSession(for: id) === accountSession)
            accountSession.cancelLoading()
        default:
            await coordinator.rotate2FA(id: id)
            #expect(coordinator.browserSession(for: id) === rotationSession)
        }
    }

    @Test func requestedRestartDoesNotResendUntilMailboxIsReady() async throws {
        let original = session(html: """
        <p>Account settings fixture</p><script>
        window.fetch = async () => ({ok:true,json:async()=>({user:{email:'old@example.com',id:'user-fixture'}})});
        </script>
        """)
        let browser = ChatGPTAutomation(sessionManager: WebSessionManager(accountSessionFactory: { _ in original }))
        let mailbox = EmailFixtureMailbox()
        let automation = EmailChangeAutomation(browser: browser, mailbox: mailbox)
        let account = pendingAccount(phase: .requested)
        var checkpoints = 0
        let outcome = await automation.changeEmail(account: account) { _ in checkpoints += 1 }
        guard case .manual = outcome else { Issue.record("Restart must return original session for manual recovery"); return }
        #expect(automation.browserSession(for: account) === original)
        #expect(original.webView.url?.path == "/settings/account")
        #expect(mailbox.baselineCalls == 1)
        #expect(mailbox.codeCalls == 0)
        #expect(checkpoints == 0)
    }

    @Test func requestedRestartPersistsFreshAttemptBeforeSendingNewCodeRequest() async throws {
        let original = session(html: """
        <div role="dialog"><h2>Edit email address</h2>
        <form onsubmit="event.preventDefault();document.body.dataset.submitted='yes';">
          <label>Email<input type="email"></label><button>Send verification email</button>
        </form></div><script>
        window.fetch = async () => ({ok:true,json:async()=>({user:{email:'old@example.com',id:'user-fixture'}})});
        </script>
        """)
        let browser = ChatGPTAutomation(sessionManager: WebSessionManager(accountSessionFactory: { _ in original }))
        let mailbox = EmailFixtureMailbox()
        mailbox.baselineResult = ["old-mail", "previous-attempt-mail"]
        let automation = EmailChangeAutomation(browser: browser, mailbox: mailbox)
        let account = pendingAccount(phase: .requested)
        var refreshed: PendingEmailChange?
        let result = await automation.changeEmail(account: account) { change in
            if change.requestAttemptID != nil {
                refreshed = change
                throw CancellationError() // Stop at the durable boundary, before any new email is submitted.
            }
        }
        guard case .manual = result else { Issue.record("Expected checkpoint stop"); return }
        let next = try #require(refreshed)
        #expect(next.newEmail == "new@icloud.com")
        #expect(next.originalUserID == "user-fixture")
        #expect(next.operationID == account.pendingEmailChange?.operationID)
        #expect(next.phase == .requested && next.requestAttemptID != nil)
        #expect(next.baselineMessageIDs == ["old-mail", "previous-attempt-mail"])
        #expect(next.requestedAt! > account.pendingEmailChange!.requestedAt!)
        #expect(try await original.evaluate("document.body.dataset.submitted === undefined") as? Bool == true)
        #expect(mailbox.codeCalls == 0)
    }

    @Test func requestedRestartNeverResendsForAnotherRemoteIdentity() async throws {
        let original = session(html: """
        <p>Account settings</p><script>
        window.fetch = async () => ({ok:true,json:async()=>({user:{email:'old@example.com',id:'different-user'}})});
        </script>
        """)
        let mailbox = EmailFixtureMailbox()
        mailbox.baselineResult = []
        let automation = EmailChangeAutomation(browser: ChatGPTAutomation(sessionManager: WebSessionManager(accountSessionFactory: { _ in original })), mailbox: mailbox)
        let result = await automation.changeEmail(account: pendingAccount(phase: .requested)) { _ in
            Issue.record("Different identity changed checkpoint")
        }
        guard case .failure = result else { Issue.record("Different identity was not rejected"); return }
        #expect(mailbox.baselineCalls == 0)
        #expect(mailbox.codeCalls == 0)
    }

    @Test(arguments: [false, true])
    func passwordReauthenticationReturningHomeReopensSettingsOnlyForOriginalIdentity(wrongIdentity: Bool) async throws {
        let original = session(html: """
        <form onsubmit="event.preventDefault();document.body.dataset.authenticated='yes'">
          <input type="password"><button>Continue</button>
        </form>
        """)
        let navigation = original.load(URL(string: "https://auth.openai.com/log-in/password")!)
        #expect(await original.waitForNavigation(navigation, seconds: 5))
        let mailbox = EmailFixtureMailbox()
        mailbox.baselineResult = []
        let automation = EmailChangeAutomation(browser: ChatGPTAutomation(
            sessionManager: WebSessionManager(accountSessionFactory: { _ in original })), mailbox: mailbox)
        let account = pendingAccount(phase: .reserved)
        var requested = false
        var result: EmailChangeOutcome?
        let task = Task {
            result = await automation.changeEmail(account: account) { change in
                if change.phase == .requested {
                    requested = true
                    throw CancellationError() // Verify recovery without submitting a new address.
                }
            }
        }
        var submittedPassword = false
        for _ in 0..<100 {
            if try await original.evaluate("document.body.dataset.authenticated === 'yes'") as? Bool == true {
                submittedPassword = true
                break
            }
            try await Task.sleep(for: .milliseconds(30))
        }
        #expect(submittedPassword)
        let web = try #require(original.webView as? EmailFixtureWebView)
        let identity = """
        <script>window.fetch=async()=>({ok:true,json:async()=>({user:{email:'old@example.com',id:'\(wrongIdentity ? "other-user" : "user-fixture")'}})});</script>
        """
        web.fixtureHTML = """
        <div role="dialog"><h2>Edit email address</h2><form>
          <input type="email"><button>Send verification email</button>
        </form></div>\(identity)
        """
        web.loadHTMLString("<h1>ChatGPT home</h1>\(identity)", baseURL: URL(string:
            "https://chatgpt.com/?callbackUrl=https%3A%2F%2Fchatgpt.com%2F%23settings%2FAccount"))
        for _ in 0..<150 {
            if result != nil { break }
            try await Task.sleep(for: .milliseconds(30))
        }
        task.cancel()
        await task.value
        let reopened = web.loadedURLs.filter { $0.host == "chatgpt.com" }
        if wrongIdentity {
            #expect(reopened.isEmpty)
            #expect(!requested)
            guard case .failure = result else { Issue.record("Wrong identity must stop recovery"); return }
        } else {
            #expect(reopened == [URL(string: "https://chatgpt.com/#settings/Account")!])
            #expect(requested)
        }
        #expect(mailbox.codeCalls == 0)
        #expect(automation.browserSession(for: account) === original)
    }

    @Test(arguments: [false, true])
    func slowEmailEditorOpeningIsClickedOnceWhileWaitingForReauthentication(clearsHash: Bool) async throws {
        let original = session(html: """
        <button aria-label="Change email address: old@example.com"
          onclick="document.body.dataset.opens=String(Number(document.body.dataset.opens||0)+1);\(clearsHash ? "history.replaceState({},'', '/?callbackUrl=fixture');" : "")">Edit</button>
        <script>window.fetch=async()=>({ok:true,json:async()=>({user:{email:'old@example.com',id:'user-fixture'}})});</script>
        """)
        let navigation = original.load(URL(string: "https://chatgpt.com/#settings/Account")!)
        #expect(await original.waitForNavigation(navigation, seconds: 5))
        let mailbox = EmailFixtureMailbox()
        mailbox.baselineResult = []
        let automation = EmailChangeAutomation(browser: ChatGPTAutomation(
            sessionManager: WebSessionManager(accountSessionFactory: { _ in original })), mailbox: mailbox)
        let task = Task {
            await automation.changeEmail(account: pendingAccount(phase: .reserved)) { change in
                #expect(change.phase == .reserved)
            }
        }
        for _ in 0..<100 {
            if try await original.evaluate("document.body.dataset.opens !== undefined") as? Bool == true { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        try await Task.sleep(for: .milliseconds(1250))
        task.cancel()
        _ = await task.value
        #expect(try await original.evaluate("document.body.dataset.opens") as? String == "1")
        #expect((original.webView as? EmailFixtureWebView)?.loadedURLs.count == 1)
        #expect(mailbox.codeCalls == 0)
    }

    @Test func confirmingRestartCanReopenOriginalConfirmationPage() async throws {
        let original = session()
        let browser = ChatGPTAutomation(sessionManager: WebSessionManager(accountSessionFactory: { _ in original }))
        let mailbox = EmailFixtureMailbox()
        let automation = EmailChangeAutomation(browser: browser, mailbox: mailbox)
        let account = pendingAccount(phase: .confirming)
        automation.prepareSession(for: account)
        #expect(original.webView.url == nil)
        automation.returnToConfirmation(for: account)
        let web = try #require(original.webView as? EmailFixtureWebView)
        #expect(web.loadedURLs.last?.path == "/settings/account")
        #expect(automation.browserSession(for: account) === original)
        #expect(account.pendingEmailChange?.phase == .confirming)
        #expect(mailbox.baselineCalls == 0)
        #expect(mailbox.codeCalls == 0)
        original.cancelLoading()
    }

    @Test func freshEmailLoginReplacesOnlyVerificationBrowserAndRetainsOriginalSession() async throws {
        let original = try await identityFixture("{user:{email:'old@example.com',id:'user-fixture'}}")
        let browser = ChatGPTAutomation(sessionManager: WebSessionManager(accountSessionFactory: { _ in original }))
        let mailbox = EmailFixtureMailbox()
        let automation = EmailChangeAutomation(browser: browser, mailbox: mailbox)
        let account = pendingAccount(phase: .confirming)
        automation.prepareSession(for: account)
        let cookie = try #require(HTTPCookie(properties: [
            .domain: "chatgpt.com", .path: "/", .name: "original", .value: "retained",
        ]))
        await original.webView.configuration.websiteDataStore.httpCookieStore.setCookie(cookie)
        let originalGeneration = original.cancellationGeneration

        #expect(automation.resetVerificationSession(for: account))
        let first = try #require(automation.browserSession(for: account))
        #expect(first !== original)
        #expect(first.webView.configuration.websiteDataStore.isPersistent == false)
        #expect(first.isVisible)
        automation.returnToConfirmation(for: account)
        #expect(automation.browserSession(for: account) === original)

        #expect(automation.resetVerificationSession(for: account))
        let second = try #require(automation.browserSession(for: account))
        #expect(second !== first && second !== original)
        #expect(second.webView.configuration.websiteDataStore !== first.webView.configuration.websiteDataStore)
        #expect(!first.isVisible)
        #expect(second.webView.url == nil)
        #expect(await second.webView.configuration.websiteDataStore.httpCookieStore.allCookies().isEmpty)
        automation.returnToConfirmation(for: account)
        #expect(automation.browserSession(for: account) === original)
        #expect(await original.webView.configuration.websiteDataStore.httpCookieStore.allCookies().contains { $0.name == "original" })
        #expect(mailbox.baselineCalls == 0 && mailbox.codeCalls == 0)
        #expect(original.cancellationGeneration == originalGeneration)
    }

    @Test func freshEmailLoginIsUnavailableBeforeConfirmation() {
        let original = session()
        let browser = ChatGPTAutomation(sessionManager: WebSessionManager(accountSessionFactory: { _ in original }))
        let automation = EmailChangeAutomation(browser: browser, mailbox: EmailFixtureMailbox())
        for phase in [EmailChangePhase.reserved, .requested] {
            let account = pendingAccount(phase: phase)
            automation.prepareSession(for: account)
            #expect(!automation.resetVerificationSession(for: account))
            #expect(automation.browserSession(for: account) === original)
        }
    }

    @Test func aliasReplacementProvesOriginalSessionAndRetainsItsCookies() async throws {
        let original = try await identityFixture("{user:{email:'old@example.com',id:'user-fixture'}}")
        let browser = ChatGPTAutomation(sessionManager: WebSessionManager(accountSessionFactory: { _ in original }))
        let mailbox = EmailFixtureMailbox()
        let automation = EmailChangeAutomation(browser: browser, mailbox: mailbox)
        let account = pendingAccount(phase: .confirming)
        #expect(automation.resetVerificationSession(for: account))
        let verification = try #require(automation.browserSession(for: account))
        let cookie = try #require(HTTPCookie(properties: [
            .domain: "chatgpt.com", .path: "/", .name: "original", .value: "retained",
        ]))
        await original.webView.configuration.websiteDataStore.httpCookieStore.setCookie(cookie)
        let originalGeneration = original.cancellationGeneration
        let proof = try await automation.originalIdentityForAliasReplacement(account: account)
        #expect(proof == .init(email: "old@example.com", userID: "user-fixture"))
        #expect(automation.browserSession(for: account) === original)
        #expect(!verification.isVisible && original.isVisible)
        #expect(original.cancellationGeneration == originalGeneration)
        #expect(await original.webView.configuration.websiteDataStore.httpCookieStore.allCookies().contains { $0.name == "original" })
        #expect(mailbox.baselineCalls == 0 && mailbox.codeCalls == 0)

        var replaced = account
        replaced.pendingEmailChange = PendingEmailChange(aliasID: UUID(), originalEmail: account.email, newEmail: "other@icloud.com")
        automation.prepareSession(for: replaced)
        #expect(automation.browserSession(for: replaced) === original)
        #expect(verification.cancellationGeneration > 0)
        #expect(original.cancellationGeneration == originalGeneration)
    }

    @Test func aliasReplacementRestoresOriginalPageWithoutSubmittingNewAddress() async throws {
        let original = session(html: """
        <div role="dialog"><h2>Edit email address</h2>
        <form onsubmit="event.preventDefault();document.body.dataset.submitted='yes';">
          <input type="email"><button>Send verification email</button>
        </form></div><script>
        window.fetch=async()=>({ok:true,json:async()=>({user:{email:'old@example.com',id:'user-fixture'}})});
        </script>
        """)
        let mailbox = EmailFixtureMailbox()
        let automation = EmailChangeAutomation(browser: ChatGPTAutomation(
            sessionManager: WebSessionManager(accountSessionFactory: { _ in original })), mailbox: mailbox)
        let proof = try await automation.originalIdentityForAliasReplacement(account: pendingAccount(phase: .requested))
        #expect(proof.email == "old@example.com")
        #expect((original.webView as? EmailFixtureWebView)?.loadedURLs == [URL(string: "https://chatgpt.com/")!])
        #expect(try await original.evaluate("document.querySelector('input').value === '' && document.body.dataset.submitted === undefined") as? Bool == true)
        #expect(mailbox.baselineCalls == 0 && mailbox.codeCalls == 0)
    }

    @Test func successfulAliasReplacementClosesOldCodeDialogInPreservedOriginalSession() async throws {
        let original = session(html: """
        <div role="dialog"><h2>Verify your email</h2><p>Code sent to new@icloud.com</p>
          <input autocomplete="one-time-code"><button>Continue</button>
        </div><script>
        window.fetch=async()=>({ok:true,json:async()=>({user:{email:'old@example.com',id:'user-fixture'}})});
        </script>
        """)
        let navigation = original.load(URL(string: "https://chatgpt.com/#settings/Account")!)
        #expect(await original.waitForNavigation(navigation, seconds: 5))
        let browser = ChatGPTAutomation(sessionManager: WebSessionManager(accountSessionFactory: { _ in original }))
        let mailbox = EmailFixtureMailbox()
        let automation = EmailChangeAutomation(browser: browser, mailbox: mailbox)
        let account = pendingAccount(phase: .confirming)
        #expect(automation.resetVerificationSession(for: account))
        let verification = try #require(automation.browserSession(for: account))
        let cookie = try #require(HTTPCookie(properties: [
            .domain: "chatgpt.com", .path: "/", .name: "original", .value: "retained",
        ]))
        await original.webView.configuration.websiteDataStore.httpCookieStore.setCookie(cookie)
        _ = try await automation.originalIdentityForAliasReplacement(account: account)
        let web = try #require(original.webView as? EmailFixtureWebView)
        web.loadedURLs.removeAll()
        web.fixtureHTML = "<h1>Account settings</h1>"
        var replaced = account
        replaced.pendingEmailChange = PendingEmailChange(aliasID: UUID(), originalEmail: account.email, newEmail: "other@icloud.com")
        automation.resetAfterAliasReplacement(for: replaced)
        #expect(web.loadedURLs == [URL(string: "https://chatgpt.com/#settings/Account")!])
        for _ in 0..<100 {
            if !web.isLoading { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(try await original.evaluate("document.querySelector('[autocomplete=one-time-code]') === null") as? Bool == true)
        #expect(automation.browserSession(for: replaced) === original)
        #expect(!verification.isVisible)
        #expect(await original.webView.configuration.websiteDataStore.httpCookieStore.allCookies().contains { $0.name == "original" })
        #expect(mailbox.baselineCalls == 0 && mailbox.codeCalls == 0)
    }

    @Test(arguments: [false, true])
    func aliasReplacementRejectsAlreadyChangedEmailOrDifferentUser(wrongUser: Bool) async throws {
        let original = try await identityFixture("{user:{email:'\(wrongUser ? "old@example.com" : "new@icloud.com")',id:'\(wrongUser ? "different-user" : "user-fixture")'}}")
        let mailbox = EmailFixtureMailbox()
        let automation = EmailChangeAutomation(browser: ChatGPTAutomation(
            sessionManager: WebSessionManager(accountSessionFactory: { _ in original })), mailbox: mailbox)
        await #expect(throws: (any Error).self) {
            try await automation.originalIdentityForAliasReplacement(account: pendingAccount(phase: .confirming))
        }
        #expect(mailbox.baselineCalls == 0 && mailbox.codeCalls == 0)
    }

    @Test func cancelledOriginalIdentityProofCannotReplaceAlias() async throws {
        let original = session(html: """
        <script>window.fetch=async()=>{
          document.body.dataset.requested='yes';
          await new Promise(resolve=>setTimeout(resolve,500));
          return {ok:true,json:async()=>({user:{email:'old@example.com',id:'user-fixture'}})};
        };</script>
        """)
        let navigation = original.load(URL(string: "https://chatgpt.com/")!)
        #expect(await original.waitForNavigation(navigation, seconds: 5))
        let automation = EmailChangeAutomation(browser: ChatGPTAutomation(
            sessionManager: WebSessionManager(accountSessionFactory: { _ in original })), mailbox: EmailFixtureMailbox())
        let task = Task {
            try await automation.originalIdentityForAliasReplacement(account: pendingAccount(phase: .confirming))
        }
        var requested = false
        for _ in 0..<100 {
            if try await original.evaluate("document.body.dataset.requested === 'yes'") as? Bool == true {
                requested = true
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(requested)
        automation.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}
