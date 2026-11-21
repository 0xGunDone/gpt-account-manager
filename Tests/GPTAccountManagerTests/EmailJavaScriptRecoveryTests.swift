import AppKit
import Foundation
import Testing
import WebKit
@testable import GPTAccountManager

@MainActor
private final class EmailJavaScriptFailureWebView: WKWebView {
    enum FailurePoint {
        case observation, loginEmailSubmission, passwordSubmission
    }

    var failurePoint = FailurePoint.observation
    var failuresRemaining = 0
    private(set) var injectedFailures = 0

    override func __callAsyncJavaScript(
        _ functionBody: String,
        arguments: [String: Any]?,
        inFrame frame: WKFrameInfo?,
        in contentWorld: WKContentWorld,
        completionHandler: (@MainActor @Sendable (Any?, (any Error)?) -> Void)?
    ) {
        // Fail only the selected bridge boundary; DOM submission still runs.
        let matches: Bool
        switch failurePoint {
        case .observation:
            matches = functionBody.contains("const frameText")
        case .loginEmailSubmission:
            matches = functionBody.contains("const authLogin =") && functionBody.contains("buttons[0].click()")
        case .passwordSubmission:
            matches = functionBody.contains("setter.call(field,") && functionBody.contains("submitters[0].click()")
        }
        guard matches, failuresRemaining > 0 else {
            super.__callAsyncJavaScript(functionBody, arguments: arguments, inFrame: frame,
                                        in: contentWorld, completionHandler: completionHandler)
            return
        }
        failuresRemaining -= 1
        injectedFailures += 1
        let failure = NSError(domain: WKError.errorDomain,
                              code: WKError.Code.javaScriptResultTypeIsUnsupported.rawValue)
        if failurePoint == .observation {
            completionHandler?(nil, failure)
        } else {
            super.__callAsyncJavaScript(functionBody, arguments: arguments, inFrame: frame,
                                        in: contentWorld) { value, error in
                completionHandler?(nil, error ?? failure)
            }
        }
    }
}

@MainActor
private final class EmailJavaScriptMailbox: EmailCodeReceiving {
    func captureBaseline() async throws -> Set<String> { ["before-login"] }
    func waitForCode(alias: String, since: Date, excluding: Set<String>) async throws -> MailVerificationCode {
        Issue.record("These local login fixtures must not request a mail code")
        throw CancellationError()
    }
    func cancel() {}
}

@MainActor
private final class EmailJavaScriptNavigationBlocker: NSObject, WKNavigationDelegate {
    private(set) var blockedNavigations = 0
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        blockedNavigations += 1
        decisionHandler(.cancel)
    }
}

@MainActor
@Suite(.serialized)
struct EmailJavaScriptRecoveryTests {
    private struct Fixture {
        let session: BrowserSession
        let web: EmailJavaScriptFailureWebView
        let changer: EmailChangeAutomation
        let navigationBlocker: EmailJavaScriptNavigationBlocker
    }

    private func fixture(path: String = "/log-in/password") async throws -> Fixture {
        _ = NSApplication.shared
        let session = BrowserSession(dataStore: .nonPersistent()) { configuration in
            EmailJavaScriptFailureWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600),
                                          configuration: configuration)
        }
        let web = try #require(session.webView as? EmailJavaScriptFailureWebView)
        web.navigationDelegate = nil
        let passwordForm = #"""
        <form onsubmit="event.preventDefault();window.passwordSubmissions++">
          <label>Password<input type="password" autocomplete="current-password"></label>
          <button>Continue</button>
        </form>
        """#
        let passwordHTML = String(decoding: try JSONEncoder().encode(passwordForm), as: UTF8.self)
        let initialForm = path == "/log-in" ? #"""
        <form onsubmit="event.preventDefault();window.emailSubmissions++;history.replaceState({},'', '/log-in/password');document.getElementById('flow').innerHTML=window.passwordForm">
          <label>Email<input type="email" name="username"></label><button>Continue</button>
        </form>
        """# : passwordForm
        web.loadHTMLString("""
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; form-action 'none'">
        <main id="flow">\(initialForm)</main>
        <script>
          window.emailSubmissions=0;window.passwordSubmissions=0;
          window.passwordForm=\(passwordHTML);window.fixtureReady=true;
        </script>
        """, baseURL: URL(string: "https://auth.openai.com\(path)"))
        let ready = try await waitUntil { (try? await session.evaluate("window.fixtureReady === true")) as? Bool == true }
        try #require(ready)
        let blocker = EmailJavaScriptNavigationBlocker()
        web.navigationDelegate = blocker
        let changer = EmailChangeAutomation(browser: ChatGPTAutomation(
            sessionManager: WebSessionManager(accountSessionFactory: { _ in session })), mailbox: EmailJavaScriptMailbox())
        return Fixture(session: session, web: web, changer: changer, navigationBlocker: blocker)
    }

    private func account() -> AccountRecord {
        var account = AccountRecord(credential: .init(email: "old@example.com", password: "fixture-password",
                                                     totpSecret: "JBSWY3DPEHPK3PXP"))
        account.pendingEmailChange = .init(aliasID: UUID(), originalEmail: account.email,
                                          newEmail: "new@example.com", phase: .reserved)
        return account
    }

    private func waitUntil(_ condition: () async throws -> Bool) async throws -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(4))
        while ContinuousClock.now < deadline {
            if try await condition() { return true }
            try await Task.sleep(for: .milliseconds(20))
        }
        return false
    }

    private func count(_ name: String, in fixture: Fixture) async throws -> Int {
        try #require(try await fixture.session.evaluate("window.\(name)") as? Int)
    }

    @Test(arguments: [1, 2])
    func transientUnsupportedObservationContinuesPasswordLoginWithoutReplay(failures: Int) async throws {
        let fixture = try await fixture()
        fixture.web.failuresRemaining = failures
        var finished = false
        let task = Task {
            let outcome = await fixture.changer.changeEmail(account: account()) { _ in Issue.record("Unexpected email request") }
            finished = true
            return outcome
        }
        defer { fixture.changer.cancel(); task.cancel() }
        _ = try await waitUntil {
            if finished { return true }
            return try await count("passwordSubmissions", in: fixture) > 0
        }
        let submissions = try await count("passwordSubmissions", in: fixture)
        #expect(submissions == 1)
        #expect(!finished)
        try await Task.sleep(for: .milliseconds(900))
        fixture.changer.cancel()
        _ = await task.value
        #expect(try await count("passwordSubmissions", in: fixture) == 1)
        #expect(fixture.web.injectedFailures == failures)
        #expect(fixture.navigationBlocker.blockedNavigations == 0)
    }

    @Test func unsupportedObservationStopsAfterTwoRetries() async throws {
        let fixture = try await fixture()
        fixture.web.failuresRemaining = 100
        let timeout = Task {
            try? await Task.sleep(for: .seconds(4))
            fixture.changer.cancel()
        }
        defer { timeout.cancel(); fixture.changer.cancel() }
        let outcome = await fixture.changer.changeEmail(account: account()) { _ in Issue.record("Unexpected email request") }
        guard case .manual = outcome else { Issue.record("Persistent observation failure must pause"); return }
        #expect(fixture.web.injectedFailures == 3)
        #expect(try await count("passwordSubmissions", in: fixture) == 0)
        #expect(fixture.navigationBlocker.blockedNavigations == 0)
    }

    @Test func unsupportedLoginEmailReplyAfterNavigationContinuesWithoutResending() async throws {
        let fixture = try await fixture(path: "/log-in")
        fixture.web.failurePoint = .loginEmailSubmission
        fixture.web.failuresRemaining = 1
        var finished = false
        let task = Task {
            let outcome = await fixture.changer.changeEmail(account: account()) { _ in Issue.record("Unexpected email request") }
            finished = true
            return outcome
        }
        defer { fixture.changer.cancel(); task.cancel() }
        _ = try await waitUntil {
            if finished { return true }
            return try await count("passwordSubmissions", in: fixture) > 0
        }
        #expect(fixture.session.webView.url?.path == "/log-in/password")
        #expect(try await count("passwordSubmissions", in: fixture) == 1)
        #expect(!finished)
        try await Task.sleep(for: .milliseconds(900))
        fixture.changer.cancel()
        _ = await task.value
        #expect(try await count("emailSubmissions", in: fixture) == 1)
        #expect(try await count("passwordSubmissions", in: fixture) == 1)
        #expect(fixture.web.injectedFailures == 1)
        #expect(fixture.navigationBlocker.blockedNavigations == 0)
    }

    @Test func unsupportedStationaryPasswordReplyPausesWithoutReplay() async throws {
        let fixture = try await fixture()
        fixture.web.failurePoint = .passwordSubmission
        fixture.web.failuresRemaining = 1
        defer { fixture.changer.cancel() }
        let outcome = await fixture.changer.changeEmail(account: account()) { _ in Issue.record("Unexpected email request") }
        guard case .manual = outcome else { Issue.record("Unacknowledged stationary mutation must pause"); return }
        #expect(fixture.session.webView.url?.path == "/log-in/password")
        #expect(try await count("passwordSubmissions", in: fixture) == 1)
        #expect(fixture.web.injectedFailures == 1)
        #expect(fixture.navigationBlocker.blockedNavigations == 0)
    }

    @Test func cancellingObservationRetryNeverSubmitsPassword() async throws {
        let fixture = try await fixture()
        fixture.web.failuresRemaining = 1
        let task = Task {
            await fixture.changer.changeEmail(account: account()) { _ in Issue.record("Unexpected email request") }
        }
        defer { fixture.changer.cancel(); task.cancel() }
        try #require(try await waitUntil { fixture.web.injectedFailures == 1 })
        fixture.changer.cancel()
        task.cancel()
        _ = await task.value
        try await Task.sleep(for: .milliseconds(400))
        #expect(try await count("passwordSubmissions", in: fixture) == 0)
        #expect(fixture.web.injectedFailures == 1)
        #expect(fixture.navigationBlocker.blockedNavigations == 0)
    }
}
