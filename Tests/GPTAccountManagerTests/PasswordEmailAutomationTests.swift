import AppKit
import Foundation
import Testing
import WebKit
@testable import GPTAccountManager

@MainActor
private final class PasswordMailboxFixture: EmailCodeReceiving {
    var baselineCalls = 0
    var purposes: [MailVerificationPurpose] = []
    var sinceDates: [Date] = []
    var exclusions: [Set<String>] = []
    var aliases: [String] = []
    var cancelled = false
    var onCode: (@MainActor () async throws -> Void)?
    var onBaseline: (@MainActor () async throws -> Void)?

    func captureBaseline() async throws -> Set<String> {
        baselineCalls += 1
        try await onBaseline?()
        return ["existing-mail"]
    }

    func waitForCode(alias: String, since: Date, excluding: Set<String>) async throws -> MailVerificationCode {
        Issue.record("Password automation used the email-change-only mailbox API")
        throw MailVerificationError.baselineRequired
    }

    func waitForCode(alias: String, since: Date, excluding: Set<String>, purpose: MailVerificationPurpose) async throws -> MailVerificationCode {
        aliases.append(alias)
        sinceDates.append(since)
        exclusions.append(excluding)
        purposes.append(purpose)
        try await onCode?()
        return .init(messageID: "new-mail", code: "123456")
    }

    func cancel() { cancelled = true }
}

@MainActor
private final class PasswordMailWebView: WKWebView {
    var initialHTML: String?
    var initialURL: URL?
    var settingsHTML: String?
    var onLoad: (@MainActor () -> Void)?
    var loadedURLs: [URL] = []
    override func load(_ request: URLRequest) -> WKNavigation? {
        if let url = request.url { loadedURLs.append(url) }
        onLoad?()
        if request.url?.fragment?.lowercased().hasPrefix("settings") == true, let settingsHTML {
            return super.loadHTMLString(settingsHTML, baseURL: request.url)
        }
        if let initialHTML { return super.loadHTMLString(initialHTML, baseURL: initialURL) }
        return super.load(request)
    }
}

@MainActor
private final class PasswordMutationTransition: NSObject, WKScriptMessageHandler {
    var stages: [String] = []
    var checkpointSaved = false

    static let authenticatedHTML = """
    <main>ChatGPT</main><script>
    window.fetch=async()=>({ok:true,json:async()=>({user:{email:'owner@example.com'}})});
    </script>
    """

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let stage = message.body as? String else { return }
        stages.append(stage)
        switch stage {
        case "reauthenticate":
            message.webView?.loadHTMLString("""
            <form onsubmit="event.preventDefault();if(document.querySelector('input').value==='123456')window.webkit.messageHandlers.mutation.postMessage('change-mail')">
              <p>Code sent to owner@example.com</p><input name="code" autocomplete="one-time-code"><button>Continue</button>
            </form>
            """, baseURL: URL(string: "https://auth.openai.com/email-verification"))
        case "change-mail":
            message.webView?.loadHTMLString("""
            <h1>Set new password</h1>
            <form onsubmit="event.preventDefault();if(document.querySelector('input').value==='candidate-fixture')window.webkit.messageHandlers.mutation.postMessage('changed')">
              <input type="password" autocomplete="new-password"><button>Save</button>
            </form>
            """, baseURL: URL(string: "https://auth.openai.com/reset-password"))
        case "changed":
            #expect(checkpointSaved)
            message.webView?.loadHTMLString(Self.authenticatedHTML, baseURL: URL(string: "https://chatgpt.com/"))
        default: Issue.record("Unknown mutation fixture stage")
        }
    }
}

@MainActor
private final class PasswordReauthenticationTransition: NSObject, WKScriptMessageHandler {
    let behavior: String
    var stages: [String] = []

    init(behavior: String) { self.behavior = behavior }

    static func authenticatedHTML(email: String = "owner@example.com", userID: String = "owner-fixture") -> String {
        """
        <h1>ChatGPT</h1><script>
        window.fetch=async()=>({ok:true,json:async()=>({user:{email:'\(email)',id:'\(userID)'}})});
        </script>
        """
    }

    static let passwordControl = """
    <button onclick="window.webkit.messageHandlers.reauthentication.postMessage('open')">Password Change</button>
    """

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let stage = message.body as? String else { return }
        stages.append(stage)
        switch stage {
        case "open":
            if stages.filter({ $0 == "open" }).count == 1 || behavior == "repeated-home" {
                message.webView?.loadHTMLString("""
                <p>Sign in to owner@example.com</p>
                <form onsubmit="event.preventDefault();if(document.querySelector('input').value==='old-fixture')window.webkit.messageHandlers.reauthentication.postMessage('authenticated')">
                  <input type="password" autocomplete="current-password"><button>Continue</button>
                </form>
                """, baseURL: URL(string: "https://auth.openai.com/log-in/password"))
            } else {
                message.webView?.loadHTMLString("""
                <form onsubmit="event.preventDefault();if(document.querySelector('input').value==='123456')window.webkit.messageHandlers.reauthentication.postMessage('new-password')">
                  <p>Code sent to owner@example.com</p>
                  <input name="code" autocomplete="one-time-code"><button>Continue</button>
                </form>
                """, baseURL: URL(string: "https://auth.openai.com/email-verification"))
            }
        case "authenticated":
            let identity = Self.authenticatedHTML(
                email: behavior == "wrong-email" ? "other@example.com" : "owner@example.com",
                userID: behavior == "wrong-user" ? "other-fixture" : "owner-fixture")
            message.webView?.loadHTMLString(identity + (behavior == "security" ? Self.passwordControl : ""),
                baseURL: URL(string: behavior == "security" ? "https://chatgpt.com/#settings/Security" :
                    "https://chatgpt.com/?callbackUrl=https%3A%2F%2Fchatgpt.com%2F%23settings%2FSecurity"))
        case "new-password":
            message.webView?.loadHTMLString("""
            <h1>Set new password</h1><form>
              <input type="password" autocomplete="new-password"><button>Save</button>
            </form>
            """, baseURL: URL(string: "https://auth.openai.com/reset-password"))
        default: Issue.record("Unknown password reauthentication fixture stage")
        }
    }
}

@MainActor
private final class PasswordMailTransition: NSObject, WKScriptMessageHandler {
    let codeHTML: String
    let signedInEmail: String
    var stages: [String] = []

    init(codeHTML: String, signedInEmail: String) {
        self.codeHTML = codeHTML
        self.signedInEmail = signedInEmail
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let stage = message.body as? String else { return }
        stages.append(stage)
        if stage == "password" {
            message.webView?.loadHTMLString(codeHTML, baseURL: URL(string: "https://auth.openai.com/email-verification"))
        } else {
            let emailJSON = String(decoding: try! JSONEncoder().encode(signedInEmail), as: UTF8.self)
            message.webView?.loadHTMLString("""
            <main>Signed in</main><script>
            window.fetch=async()=>({ok:true,json:async()=>({user:{email:\(emailJSON)}})});
            </script>
            """, baseURL: URL(string: "https://chatgpt.com/"))
        }
    }
}

@MainActor
@Suite(.serialized)
struct PasswordEmailAutomationTests {
    private let account = AccountRecord(credential: .init(
        email: "owner@example.com", password: "old-fixture", totpSecret: "JBSWY3DPEHPK3PXP"))

    private func fixture() -> BrowserSession {
        _ = NSApplication.shared
        return BrowserSession(dataStore: .nonPersistent()) { configuration in
            PasswordMailWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        }
    }

    private func load(_ html: String, in session: BrowserSession,
                      url: String = "https://auth.openai.com/email-verification") async throws {
        session.webView.navigationDelegate = nil
        session.webView.loadHTMLString(html, baseURL: URL(string: url))
        for _ in 0..<100 where session.webView.isLoading { try await Task.sleep(for: .milliseconds(25)) }
        try #require(!session.webView.isLoading)
    }

    private func codeForm(email: String = "owner@example.com", disabled: Bool = false) -> String {
        """
        <form onsubmit="event.preventDefault();document.body.dataset.submits=String(Number(document.body.dataset.submits||0)+1)">
          <p>Enter the code sent to <span id="recipient">\(email)</span></p>
          <input name="code" autocomplete="one-time-code">
          <button type="submit" \(disabled ? "disabled" : "")>Continue</button>
        </form>
        """
    }

    @Test(arguments: [MailVerificationPurpose.login, .passwordChange])
    func freshBaselineIsPreservedAndCodeSubmittedOnlyOnce(purpose: MailVerificationPurpose) async throws {
        let mailbox = PasswordMailboxFixture()
        let browser = ChatGPTAutomation(sessionManager: WebSessionManager(), passwordMailbox: mailbox)
        let session = fixture()
        try await browser.preparePasswordEmailRequest(account: account, in: session, purpose: purpose)
        try await load(codeForm(), in: session)
        try await browser.preparePasswordEmailRequest(account: account, in: session, purpose: purpose)
        #expect(try await browser.submitPasswordEmailCode(account: account, in: session, purpose: purpose))
        #expect(try await browser.submitPasswordEmailCode(account: account, in: session, purpose: purpose))
        #expect(mailbox.baselineCalls == 1)
        #expect(mailbox.purposes == [purpose])
        #expect(mailbox.aliases == [account.email])
        #expect(mailbox.exclusions == [Set(["existing-mail"])])
        #expect(mailbox.sinceDates.first.map { $0.timeIntervalSince1970 == floor($0.timeIntervalSince1970) } == true)
        #expect(try await session.evaluate("document.body.dataset.submits") as? String == "1")
        #expect(try await session.evaluate("document.querySelector('input').value") as? String == "123456")
    }

    @Test func alreadyRequestedCodeNeverCapturesLateBaseline() async throws {
        let mailbox = PasswordMailboxFixture()
        let browser = ChatGPTAutomation(sessionManager: WebSessionManager(), passwordMailbox: mailbox)
        let session = fixture()
        try await load(codeForm(), in: session)
        do {
            try await browser.preparePasswordEmailRequest(account: account, in: session, purpose: .passwordChange)
            Issue.record("A late baseline hid the pending email")
        } catch PasswordEmailAutomationError.baselineMissing {}
        #expect(mailbox.baselineCalls == 0)
        #expect(mailbox.purposes.isEmpty)
    }

    @Test func recipientChangesWhileMailIsPendingPreventSubmission() async throws {
        let mailbox = PasswordMailboxFixture()
        let browser = ChatGPTAutomation(sessionManager: WebSessionManager(), passwordMailbox: mailbox)
        let session = fixture()
        try await browser.preparePasswordEmailRequest(account: account, in: session, purpose: .passwordChange)
        try await load(codeForm(), in: session)
        mailbox.onCode = { _ = try await session.evaluate("document.querySelector('#recipient').textContent='other@example.com'") }
        do {
            _ = try await browser.submitPasswordEmailCode(account: account, in: session, purpose: .passwordChange)
            Issue.record("Code submitted after recipient changed")
        } catch PasswordEmailAutomationError.identityChanged {}
        #expect(try await session.evaluate("document.querySelector('input').value") as? String == "")
    }

    @Test func cancellationCancelsMailboxAndDiscardsReturnedCode() async throws {
        let mailbox = PasswordMailboxFixture()
        let browser = ChatGPTAutomation(sessionManager: WebSessionManager(), passwordMailbox: mailbox)
        let session = fixture()
        try await browser.preparePasswordEmailRequest(account: account, in: session, purpose: .login)
        try await load(codeForm(), in: session)
        mailbox.onCode = { browser.cancelActiveOperation() }
        do {
            _ = try await browser.submitPasswordEmailCode(account: account, in: session, purpose: .login)
            Issue.record("Cancelled mailbox result was submitted")
        } catch is CancellationError {}
        #expect(mailbox.cancelled)
        #expect(try await session.evaluate("document.querySelector('input').value") as? String == "")
    }

    @Test func unknownRouteAndWrongAccountNeverPollMailbox() async throws {
        let mailbox = PasswordMailboxFixture()
        let browser = ChatGPTAutomation(sessionManager: WebSessionManager(), passwordMailbox: mailbox)
        let session = fixture()
        try await browser.preparePasswordEmailRequest(account: account, in: session, purpose: .login)
        try await load(codeForm(), in: session, url: "https://auth.openai.com/reset-password/email-verification")
        do {
            _ = try await browser.submitPasswordEmailCode(account: account, in: session, purpose: .login)
            Issue.record("Unknown email-code route was accepted")
        } catch PasswordEmailAutomationError.challengeChanged {}
        try await load(codeForm(email: "other@example.com"), in: session)
        do {
            _ = try await browser.submitPasswordEmailCode(account: account, in: session, purpose: .login)
            Issue.record("Wrong visible account was accepted")
        } catch PasswordEmailAutomationError.identityChanged {}
        #expect(mailbox.purposes.isEmpty)
    }

    @Test func delayedFormAndDisabledButtonReuseFetchedMail() async throws {
        let mailbox = PasswordMailboxFixture()
        let browser = ChatGPTAutomation(sessionManager: WebSessionManager(), passwordMailbox: mailbox)
        let session = fixture()
        try await browser.preparePasswordEmailRequest(account: account, in: session, purpose: .login)
        let formJSON = String(decoding: try JSONEncoder().encode(codeForm(disabled: true)), as: UTF8.self)
        try await load("""
        <main>Loading</main><script>
        setTimeout(()=>document.body.innerHTML=\(formJSON),250);
        setTimeout(()=>document.querySelector('button').disabled=false,1600);
        </script>
        """, in: session)
        #expect(try await browser.submitPasswordEmailCode(account: account, in: session, purpose: .login))
        #expect(mailbox.purposes == [.login])
        #expect(try await session.evaluate("document.body.dataset.submits") as? String == "1")
    }

    @Test func timeoutResumesSameMailboxRequest() async throws {
        let mailbox = PasswordMailboxFixture()
        let browser = ChatGPTAutomation(sessionManager: WebSessionManager(), passwordMailbox: mailbox)
        let session = fixture()
        try await browser.preparePasswordEmailRequest(account: account, in: session, purpose: .login)
        try await load(codeForm(), in: session)
        mailbox.onCode = { throw MailVerificationError.timedOut }
        do {
            _ = try await browser.submitPasswordEmailCode(account: account, in: session, purpose: .login)
            Issue.record("Fixture timeout was ignored")
        } catch MailVerificationError.timedOut {}
        mailbox.onCode = nil
        try await browser.preparePasswordEmailRequest(account: account, in: session, purpose: .login)
        #expect(try await browser.submitPasswordEmailCode(account: account, in: session, purpose: .login))
        #expect(mailbox.baselineCalls == 1)
        #expect(mailbox.sinceDates.count == 2)
        #expect(mailbox.sinceDates.first == mailbox.sinceDates.last)
        #expect(mailbox.exclusions.first == mailbox.exclusions.last)
    }

    @Test(arguments: ["password-and-mail", "mail-only", "wrong-account"])
    func freshCandidateLoginRequiresPasswordAndMatchingIdentity(behavior: String) async throws {
        _ = NSApplication.shared
        let mailbox = PasswordMailboxFixture()
        let codeHTML = """
        <form onsubmit="event.preventDefault();if(document.querySelector('input').value==='123456')window.webkit.messageHandlers.transition.postMessage('mail')">
          <p>Code sent to owner@example.com</p><input name="code" autocomplete="one-time-code"><button>Continue</button>
        </form>
        """
        let transition = PasswordMailTransition(codeHTML: codeHTML,
            signedInEmail: behavior == "wrong-account" ? "other@example.com" : account.email)
        var windows: [NSWindow] = []
        defer { for window in windows { window.contentView = nil } }
        let manager = WebSessionManager(accountSessionFactory: { _ in savedSessionFixture() }, verificationSessionFactory: {
            let session = BrowserSession(dataStore: .nonPersistent()) { configuration in
                configuration.userContentController.add(transition, name: "transition")
                let web = PasswordMailWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
                web.onLoad = { #expect(mailbox.baselineCalls == 1) }
                web.initialHTML = behavior == "mail-only" ? codeHTML : """
                <form onsubmit="event.preventDefault();if(document.querySelector('input').value==='candidate-fixture')window.webkit.messageHandlers.transition.postMessage('password')">
                  <p>Sign in to owner@example.com</p><input type="password" autocomplete="current-password"><button>Continue</button>
                </form>
                """
                web.initialURL = URL(string: behavior == "mail-only"
                    ? "https://auth.openai.com/email-verification" : "https://auth.openai.com/log-in/password")
                return web
            }
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = session.webView
            windows.append(window)
            return session
        })
        let browser = ChatGPTAutomation(sessionManager: manager, passwordMailbox: mailbox)
        var pending = account
        pending.pendingPassword = "candidate-fixture"
        let result = await browser.changePassword(account: pending, newPassword: "candidate-fixture") {
            Issue.record("Candidate verification tried another password mutation")
        }
        if behavior == "password-and-mail" {
            guard case .success(let email) = result else { Issue.record("Password plus mail login failed"); return }
            #expect(email == account.email)
            #expect(transition.stages == ["password", "mail"])
        } else {
            if case .success = result { Issue.record("Candidate accepted without matching password login") }
        }
        #expect(mailbox.purposes == [.login])
        #expect(mailbox.baselineCalls == 1)
    }

    @Test func persistentPasswordMutationReadsMailAndVerifiesCandidateInSeparateSession() async throws {
        _ = NSApplication.shared
        let mailbox = PasswordMailboxFixture()
        let mutation = PasswordMutationTransition()
        let login = PasswordMailTransition(codeHTML: """
        <form onsubmit="event.preventDefault();if(document.querySelector('input').value==='123456')window.webkit.messageHandlers.transition.postMessage('mail')">
          <p>Code sent to owner@example.com</p><input name="code" autocomplete="one-time-code"><button>Continue</button>
        </form>
        """, signedInEmail: account.email)
        var sessions: [BrowserSession] = []
        var windows: [NSWindow] = []
        defer { for window in windows { window.contentView = nil } }
        func makeSession(isMutation: Bool) -> BrowserSession {
            let session = BrowserSession(dataStore: .nonPersistent()) { configuration in
                if isMutation { configuration.userContentController.add(mutation, name: "mutation") }
                else { configuration.userContentController.add(login, name: "transition") }
                let web = PasswordMailWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
                if isMutation {
                    web.initialHTML = PasswordMutationTransition.authenticatedHTML
                    web.initialURL = URL(string: "https://chatgpt.com/")
                    web.settingsHTML = PasswordMutationTransition.authenticatedHTML + """
                    <button onclick="window.webkit.messageHandlers.mutation.postMessage('reauthenticate')">Password Change</button>
                    """
                } else {
                    web.onLoad = { #expect(mailbox.baselineCalls == 3) }
                    web.initialURL = URL(string: "https://auth.openai.com/log-in/password")
                    web.initialHTML = """
                    <form onsubmit="event.preventDefault();if(document.querySelector('input').value==='candidate-fixture')window.webkit.messageHandlers.transition.postMessage('password')">
                      <p>Sign in to owner@example.com</p><input type="password" autocomplete="current-password"><button>Continue</button>
                    </form>
                    """
                }
                return web
            }
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = session.webView
            windows.append(window)
            sessions.append(session)
            return session
        }
        let manager = WebSessionManager(accountSessionFactory: { storeID in
            #expect(storeID == account.browserStoreID)
            return makeSession(isMutation: true)
        }, verificationSessionFactory: {
            makeSession(isMutation: false)
        })
        let browser = ChatGPTAutomation(sessionManager: manager, passwordMailbox: mailbox)
        let result = await browser.changePassword(account: account, newPassword: "candidate-fixture") {
            mutation.checkpointSaved = true
            #expect(mutation.stages == ["reauthenticate", "change-mail"])
        }
        guard case .success(let email) = result else { Issue.record("Full password mutation failed"); return }
        #expect(email == account.email)
        try #require(sessions.count == 2)
        #expect(manager.existingSession(for: account) === sessions[0])
        #expect(sessions[0] !== sessions[1])
        #expect(browser.browserSession(for: account) === sessions[0])
        #expect(!sessions[1].isVisible)
        browser.prepareBrowserSession(for: account)
        #expect(browser.twoFARotationSession(for: account) === sessions[0], "Next 2FA action must use the saved profile")
        #expect(mailbox.baselineCalls == 3)
        #expect(mailbox.purposes == [.passwordChange, .login])
        #expect(mutation.stages == ["reauthenticate", "change-mail", "changed"])
        #expect(login.stages == ["password", "mail"])
        #expect(try await browser.authorizationSession(for: account) === sessions[0])
        #expect(sessions.count == 2)
        #expect(login.stages == ["password", "mail"], "Next OAuth action must reuse the verified login without submitting credentials again")
    }

    @Test(arguments: ["home", "security", "wrong-email", "wrong-user", "identity-during-baseline", "repeated-home"])
    func passwordReauthenticationReopensOnlyForSameIdentityAndOnlyOnce(behavior: String) async throws {
        _ = NSApplication.shared
        let mailbox = PasswordMailboxFixture()
        let transition = PasswordReauthenticationTransition(behavior: behavior)
        let session = BrowserSession(dataStore: .nonPersistent()) { configuration in
            configuration.userContentController.add(transition, name: "reauthentication")
            let web = PasswordMailWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
            web.initialHTML = PasswordReauthenticationTransition.authenticatedHTML()
            web.initialURL = URL(string: "https://chatgpt.com/")
            web.settingsHTML = PasswordReauthenticationTransition.authenticatedHTML() + PasswordReauthenticationTransition.passwordControl
            return web
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = session.webView
        defer { window.contentView = nil }
        let browser = ChatGPTAutomation(sessionManager: WebSessionManager(accountSessionFactory: { _ in session }),
                                        passwordMailbox: mailbox)
        mailbox.onBaseline = {
            if behavior == "identity-during-baseline", mailbox.baselineCalls == 3 {
                session.webView.loadHTMLString(PasswordReauthenticationTransition.authenticatedHTML(userID: "other-fixture"),
                                              baseURL: session.webView.url)
                for _ in 0..<100 where session.webView.isLoading { try await Task.sleep(for: .milliseconds(20)) }
                #expect(!session.webView.isLoading)
            }
        }
        var checkpointReached = false
        var result: PasswordChangeOutcome?
        let task = Task {
            result = await browser.changePassword(account: account, newPassword: "candidate-fixture") {
                checkpointReached = true
                throw CancellationError() // Prove recovery without submitting a password mutation.
            }
        }
        for _ in 0..<180 {
            if result != nil { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        let completedBeforeCancellation = result != nil
        task.cancel()
        await task.value
        let web = try #require(session.webView as? PasswordMailWebView)
        let settingsLoads = web.loadedURLs.filter { $0.fragment == "settings/Security" }.count
        #expect(completedBeforeCancellation)
        if behavior == "home" || behavior == "security" {
            #expect(checkpointReached)
            #expect(transition.stages == ["open", "authenticated", "open", "new-password"])
            #expect(mailbox.baselineCalls == 3)
            #expect(mailbox.purposes == [.passwordChange])
            #expect(settingsLoads == (behavior == "home" ? 2 : 1))
            #expect(try await session.evaluate("document.querySelector('input')?.value") as? String == "")
        } else {
            #expect(!checkpointReached)
            #expect(mailbox.purposes.isEmpty)
            if behavior == "repeated-home" {
                #expect(settingsLoads == 2)
                #expect(transition.stages == ["open", "authenticated", "open", "authenticated"])
                guard case .manualActionRequired = result else { Issue.record("Repeated reauthentication must pause"); return }
            } else {
                #expect(settingsLoads == 1)
                #expect(transition.stages == ["open", "authenticated"])
                guard case .failure = result else { Issue.record("Changed identity must stop recovery"); return }
            }
        }
    }
}
