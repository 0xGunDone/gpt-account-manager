import AppKit
import Foundation
import Testing
import WebKit
@testable import GPTAccountManager

@MainActor
private final class RecoveryLoginFixtureWebView: WKWebView, WKNavigationDelegate {
    var reportedURL: URL?
    override var url: URL? { reportedURL ?? super.url }
    override func load(_ request: URLRequest) -> WKNavigation? { nil }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        decisionHandler(.cancel)
    }
}

@MainActor
@Suite(.serialized)
struct RegistrationRecoveryLoginTests {
    private let account = AccountRecord(credential: .init(
        email: "recovery@example.com", password: "saved-fixture-password", totpSecret: ""))

    private func fixture(_ html: String, path: String = "/about-you",
                         authenticatedEmail: String? = nil) async throws -> BrowserSession {
        _ = NSApplication.shared
        let session = BrowserSession(dataStore: .nonPersistent()) { configuration in
            RecoveryLoginFixtureWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600),
                                       configuration: configuration)
        }
        let emailJSON = String(decoding: try JSONEncoder().encode(authenticatedEmail), as: UTF8.self)
        let fetchMock = """
        <script>
        window.fetch = async () => ({ok:true,json:async()=>({user:{email:\(emailJSON)}})});
        </script>
        """
        session.webView.navigationDelegate = nil
        let origin = authenticatedEmail == nil ? "https://auth.openai.com" : "https://chatgpt.com"
        session.webView.loadHTMLString(fetchMock + html, baseURL: URL(string: origin + path))
        for _ in 0..<100 where session.webView.isLoading {
            try await Task.sleep(for: .milliseconds(50))
        }
        try #require(!session.webView.isLoading)
        session.webView.navigationDelegate = session.webView as? RecoveryLoginFixtureWebView
        return session
    }

    private var profileForm: String {
        """
        <form onsubmit="event.preventDefault();document.body.dataset.submits=String(Number(document.body.dataset.submits||0)+1)">
          <label>Full name <input name="name"></label>
          <label>Age <input name="age" type="number"></label><button>Continue</button>
        </form>
        """
    }

    @Test func emptySecretWaitsForDelayedProfileAndSubmitsOnlyOnce() async throws {
        let formJSON = String(decoding: try JSONEncoder().encode(profileForm), as: UTF8.self)
        let session = try await fixture("""
        <main>Loading</main>
        <script>setTimeout(()=>document.body.innerHTML=\(formJSON),700)</script>
        """)
        let browser = ChatGPTAutomation(sessionManager: WebSessionManager())
        var calls = 0
        var successfulSubmissions = 0
        let result = await browser.signIn(account: account, secret: "", in: session,
                                         loginTimeoutSeconds: 2, automaticallyWaitForTransitions: true,
                                         registrationProfileHandler: { page in
            calls += 1
            let submitted = try await RegistrationForm.submitProfile(fullName: "Fixture Person", age: 29, in: page)
            if submitted { successfulSubmissions += 1 }
            return submitted
        })
        guard case .manual(_, let proof) = result else {
            Issue.record("Unchanged profile must time out without attempting an authenticator code")
            return
        }
        #expect(calls >= 1)
        #expect(successfulSubmissions == 1)
        #expect(!proof.pendingOTPSubmitted)
        #expect(try await session.evaluate("document.body.dataset.submits") as? String == "1")
        #expect(try await session.evaluate("document.querySelector('[name=name]').value") as? String == "Fixture Person")
        #expect(try await session.evaluate("document.querySelector('[name=age]').value") as? String == "29")
    }

    @Test func continuousLoginWaitPreservesSubmittedStagesAndStopCancelsIt() async throws {
        let session = try await fixture("""
        <script>window.submits=0;</script>
        <form onsubmit="event.preventDefault();window.submits++">
          <input type="password"><button>Continue</button>
        </form>
        """, path: "/log-in/password")
        let browser = ChatGPTAutomation(sessionManager: WebSessionManager())
        let task = Task { await browser.signIn(account: account, secret: "", in: session,
            requireExplicitProof: true, loginTimeoutSeconds: 1, automaticallyWaitForTransitions: true,
            continueWaitingOnTimeout: true, humanChallengeTimeoutSeconds: 1) }
        try await Task.sleep(for: .milliseconds(3300))
        #expect(try await session.evaluate("window.submits") as? Int == 1)
        #expect(session.operationMessage?.contains("продолжается автоматически") == true)
        session.cancelLoading()
        let result = await task.value
        guard case .failure(let message) = result else { Issue.record("Stop must cancel continuous login"); return }
        #expect(message == "Stopped")
    }

    @Test func passwordMailBaselineExcludesDefaultCodeAndSurvivesPollingAndResume() async throws {
        let session = try await fixture("""
        <script>window.passwordCount=0;</script>
        <form onsubmit="event.preventDefault();window.passwordCount++;history.replaceState({},'', '/email-verification');document.body.innerHTML='<main><p>Code sent to recovery@example.com</p><form><input name=code autocomplete=one-time-code><button>Continue</button></form></main>'">
          <p>recovery@example.com</p><input type=password disabled><button>Continue</button>
        </form>
        """, path: "/log-in/password")
        let browser = ChatGPTAutomation(sessionManager: WebSessionManager())
        let receivedAt = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
        let messages = ["default", "password"].enumerated().map { index, id in
            MailVerificationMessage(messageID: id, sender: "noreply@openai.com", recipient: account.email,
                originalSender: nil, receivedAt: receivedAt, subject: "Your temporary ChatGPT login code",
                body: "Enter this code: \(index == 0 ? "111111" : "222222")")
        }
        #expect(throws: MailVerificationError.ambiguousMessage) {
            try MailVerificationMatcher.match(messages: messages, alias: account.email, since: receivedAt,
                                               excluding: [], now: Date(), purpose: .login)
        }
        var baseline: Set<String> = []
        var since = receivedAt
        var hookCalls = 0
        var mailCalls = 0
        let hook: @MainActor (BrowserSession) async throws -> Void = { page in
            hookCalls += 1
            baseline = ["default"]
            since = receivedAt
            _ = try await page.evaluate("(() => { setTimeout(()=>document.querySelector('input').disabled=false,200); return true; })()")
        }
        let mail: @MainActor (BrowserSession) async throws -> Bool = { _ in
            mailCalls += 1
            #expect(try MailVerificationMatcher.match(messages: messages, alias: account.email, since: since,
                excluding: baseline, now: Date(), purpose: .login)?.messageID == "password")
            throw MailVerificationError.timedOut
        }
        let result = await browser.signIn(account: account, secret: "", in: session,
            loginTimeoutSeconds: 3, automaticallyWaitForTransitions: true,
            registrationProfileHandler: { _ in false }, beforePasswordSubmission: hook, emailCodeHandler: mail)
        guard case .manual(_, let proof) = result else { Issue.record("Slow mail must keep login proof"); return }
        #expect(hookCalls == 1 && mailCalls == 1 && proof.passwordSubmitted)
        #expect(try await session.evaluate("window.passwordCount") as? Int == 1)
        _ = await browser.signIn(account: account, secret: "", in: session, initialProof: proof,
            loginTimeoutSeconds: 1, automaticallyWaitForTransitions: true,
            registrationProfileHandler: { _ in false }, beforePasswordSubmission: hook, emailCodeHandler: mail)
        #expect(hookCalls == 1 && mailCalls == 2)
        #expect(baseline == ["default"] && since == receivedAt)
        #expect(try await session.evaluate("window.passwordCount") as? Int == 1)
    }

    @Test(arguments: ["navigation", "cancellation", "recipient"])
    func passwordMailPreparationRechecksPageBeforeSending(change: String) async throws {
        let session = try await fixture("""
        <form onsubmit="event.preventDefault();document.body.dataset.sent='yes'">
          <p>recovery@example.com</p><input type=password><button>Continue</button>
        </form>
        """, path: "/log-in/password")
        let browser = ChatGPTAutomation(sessionManager: WebSessionManager())
        var calls = 0
        _ = await browser.signIn(account: account, secret: "", in: session,
            loginTimeoutSeconds: 1, automaticallyWaitForTransitions: true,
            registrationProfileHandler: { _ in false }, beforePasswordSubmission: { page in
                calls += 1
                try await Task.sleep(for: .milliseconds(20))
                if change == "cancellation" { page.cancelLoading() }
                else if change == "navigation" {
                    _ = try await page.evaluate("history.replaceState({},'', '/email-verification')")
                } else {
                    _ = try await page.evaluate("document.querySelector('p').textContent='wrong@example.com'")
                }
            })
        #expect(calls == 1)
        #expect(try await session.evaluate("document.body.dataset.sent || null") is NSNull)
        #expect(try await session.evaluate("document.querySelector('input').value") as? String == "")
    }

    @Test func profileHandlerRetriesDisabledButtonUntilOneSuccessfulSubmission() async throws {
        let session = try await fixture(profileForm.replacingOccurrences(of: "<button>", with: "<button disabled>"))
        let browser = ChatGPTAutomation(sessionManager: WebSessionManager())
        var calls = 0
        var successfulSubmissions = 0
        let result = await browser.signIn(account: account, secret: "", in: session,
                                         loginTimeoutSeconds: 3, automaticallyWaitForTransitions: true,
                                         registrationProfileHandler: { page in
            calls += 1
            let submitted = try await RegistrationForm.submitProfile(fullName: "Fixture Person", age: 29, in: page)
            if submitted { successfulSubmissions += 1 }
            if calls == 1 {
                #expect(!submitted)
                _ = try await page.evaluate("(() => { setTimeout(()=>document.querySelector('button').disabled=false,100); return true; })()")
            }
            return submitted
        })
        guard case .manual = result else { Issue.record("Submitted profile fixture must remain unauthenticated"); return }
        #expect(calls == 2)
        #expect(successfulSubmissions == 1)
        #expect(try await session.evaluate("document.body.dataset.submits") as? String == "1")
    }

    @Test func rejectedProfileRecoveryDelegatesOneRetryToSavedDraftPolicy() async throws {
        let session = try await fixture("""
        <script>window.submits=0;</script>
        <form onsubmit="event.preventDefault();window.submits++;if(window.submits===1)document.querySelector('p').hidden=false;else document.body.innerHTML='<main>Loading</main>'">
          <input name="name"><input name="age" type="number"><button>Continue</button>
          <p hidden>We cannot create your account due to our terms of use.</p>
        </form>
        """)
        let browser = ChatGPTAutomation(sessionManager: WebSessionManager())
        var retried = false
        var calls = 0
        _ = await browser.signIn(account: account, secret: "", in: session,
                                loginTimeoutSeconds: 2, automaticallyWaitForTransitions: true,
                                registrationProfileHandler: { page in
            calls += 1
            if try await RegistrationForm.inspect(in: page).kind == .registrationRejected {
                guard !retried else { throw RegistrationForm.ProfileRetryError.exhausted }
                return try await RegistrationForm.retryRejectedProfile(fullName: "Fixture Person", age: 29, in: page) {
                    retried = true
                }
            }
            return try await RegistrationForm.submitProfile(fullName: "Fixture Person", age: 29, in: page)
        })
        #expect(retried && calls == 2)
        #expect(try await session.evaluate("window.submits") as? Int == 2)
    }

    @Test func actualMFAWithoutSavedSecretFailsWithoutSubmittingCode() async throws {
        let session = try await fixture("""
        <form onsubmit="event.preventDefault();document.body.dataset.submits='1'">
          <input name="code" autocomplete="one-time-code"><button>Continue</button>
        </form>
        """, path: "/mfa-challenge/fixture")
        let browser = ChatGPTAutomation(sessionManager: WebSessionManager())
        var profileCalls = 0
        let result = await browser.signIn(account: account, secret: "", in: session,
                                         loginTimeoutSeconds: 2, automaticallyWaitForTransitions: true,
                                         registrationProfileHandler: { _ in profileCalls += 1; return false })
        guard case .failure(let message) = result else {
            Issue.record("Actual MFA requires a clear missing-secret failure")
            return
        }
        #expect(message.contains("2FA"))
        #expect(profileCalls == 0)
        #expect(try await session.evaluate("document.querySelector('input').value") as? String == "")
        #expect(try await session.evaluate("document.body.dataset.submits === undefined") as? Bool == true)
    }

    @Test(arguments: [0, 1])
    func authenticatedIdentityMustMatchSavedAccount(loginTimeout: Int) async throws {
        let session = try await fixture("<main>ChatGPT</main>", path: "/", authenticatedEmail: "wrong@example.com")
        let browser = ChatGPTAutomation(sessionManager: WebSessionManager())
        var profileCalls = 0
        let result = await browser.signIn(account: account, secret: "", in: session,
                                         loginTimeoutSeconds: loginTimeout, automaticallyWaitForTransitions: true,
                                         registrationProfileHandler: { _ in profileCalls += 1; return false })
        switch result {
        case .failure, .manual: break
        case .success, .restart: Issue.record("Wrong account must be rejected even after the wait deadline")
        }
        #expect(profileCalls == 0)
    }

    @Test(arguments: ["/create-account/password", "/reset-password", "/reset-password/password"])
    func recoveryNeverCreatesOrResetsPassword(path: String) async throws {
        let session = try await fixture("""
        <form onsubmit="event.preventDefault();document.body.dataset.submits='1'">
          <label>Password <input type="password"></label><button>Continue</button>
        </form>
        """, path: path)
        let browser = ChatGPTAutomation(sessionManager: WebSessionManager())
        var profileCalls = 0
        let result = await browser.signIn(account: account, secret: "", in: session,
                                         loginTimeoutSeconds: 1, automaticallyWaitForTransitions: true,
                                         registrationProfileHandler: { _ in profileCalls += 1; return false })
        if case .success = result { Issue.record("Password creation/reset cannot complete recovery") }
        #expect(profileCalls == 0)
        #expect(try await session.evaluate("document.querySelector('input').value") as? String == "")
        #expect(try await session.evaluate("document.body.dataset.submits === undefined") as? Bool == true)
    }

    @Test func recoveryDoesNotFillPasswordForWrongVisibleEmail() async throws {
        let session = try await fixture("""
        <form onsubmit="event.preventDefault();document.body.dataset.submits='1'">
          <p>Sign in to wrong@example.com</p>
          <label>Password <input type="password"></label><button>Continue</button>
        </form>
        """, path: "/log-in/password")
        let browser = ChatGPTAutomation(sessionManager: WebSessionManager())
        let result = await browser.signIn(account: account, secret: "", in: session,
                                         loginTimeoutSeconds: 1, automaticallyWaitForTransitions: true,
                                         registrationProfileHandler: { _ in false })
        guard case .manual = result else { Issue.record("Wrong password-page recipient must pause recovery"); return }
        #expect(try await session.evaluate("document.querySelector('input').value") as? String == "")
        #expect(try await session.evaluate("document.body.dataset.submits === undefined") as? Bool == true)
    }

    @Test func recoveryDoesNotFillPasswordWhenNativeURLAndDocumentDisagree() async throws {
        let session = try await fixture("""
        <form onsubmit="event.preventDefault();document.body.dataset.submits='1'">
          <p>Sign in to recovery@example.com</p>
          <label>Password <input type="password"></label><button>Continue</button>
        </form>
        """, path: "/create-account/password")
        let webView = try #require(session.webView as? RecoveryLoginFixtureWebView)
        webView.reportedURL = URL(string: "https://auth.openai.com/log-in/password")
        let browser = ChatGPTAutomation(sessionManager: WebSessionManager())
        let result = await browser.signIn(account: account, secret: "", in: session,
                                         loginTimeoutSeconds: 1, automaticallyWaitForTransitions: true,
                                         registrationProfileHandler: { _ in false })
        guard case .manual = result else { Issue.record("Stale document must remain untouched while navigation settles"); return }
        #expect(try await session.evaluate("location.pathname") as? String == "/create-account/password")
        #expect(try await session.evaluate("document.querySelector('input').value") as? String == "")
        #expect(try await session.evaluate("document.body.dataset.submits === undefined") as? Bool == true)
    }

    @Test func rejectedSavedPasswordStopsRecovery() async throws {
        let session = try await fixture("""
        <p>Incorrect email address or password.</p>
        <form onsubmit="event.preventDefault();document.body.dataset.submits='1'">
          <input type="password"><button>Continue</button>
        </form>
        """, path: "/log-in/password")
        let browser = ChatGPTAutomation(sessionManager: WebSessionManager())
        let result = await browser.signIn(account: account, secret: "", in: session,
                                         loginTimeoutSeconds: 1, automaticallyWaitForTransitions: true,
                                         registrationProfileHandler: { _ in Issue.record("Unexpected profile"); return false })
        guard case .failure = result else { Issue.record("Rejected saved password must stop recovery"); return }
        #expect(try await session.evaluate("document.querySelector('input').value") as? String == "")
        #expect(try await session.evaluate("document.body.dataset.submits === undefined") as? Bool == true)
    }

    @Test func cancellationStopsWaitingForProfile() async throws {
        let session = try await fixture("<main>Loading</main>")
        let browser = ChatGPTAutomation(sessionManager: WebSessionManager())
        let cancellation = Task { @MainActor in
            try await Task.sleep(for: .milliseconds(300))
            session.cancelLoading()
        }
        let result = await browser.signIn(account: account, secret: "", in: session,
                                         loginTimeoutSeconds: 3, automaticallyWaitForTransitions: true,
                                         registrationProfileHandler: { _ in false })
        try await cancellation.value
        guard case .failure(let message) = result else { Issue.record("Cancelled recovery must stop"); return }
        #expect(message == "Stopped")
    }
}
