import AppKit
import Testing
import WebKit
@testable import GPTAccountManager

@MainActor
private final class MFAProofFixtureWebView: WKWebView {
    var reportedURL: URL?
    override var url: URL? { reportedURL ?? super.url }
}

@MainActor
@Suite(.serialized)
struct MissingPasswordMFAProofTests {
    private let account = AccountRecord(credential: .init(
        email: "fixture@example.com", password: "fixture", totpSecret: "JBSWY3DPEHPK3PXP"))

    private func fixture(path: String = "/mfa-challenge/fixture") async throws -> BrowserSession {
        _ = NSApplication.shared
        let session = BrowserSession(dataStore: .nonPersistent()) { configuration in
            MFAProofFixtureWebView(frame: NSRect(x: 0, y: 0, width: 720, height: 500),
                                  configuration: configuration)
        }
        session.webView.navigationDelegate = nil
        session.webView.loadHTMLString("""
        <form onsubmit="event.preventDefault();document.body.dataset.submits='1'">
          <input id="code" autocomplete="one-time-code"><button>Continue</button>
        </form>
        """, baseURL: URL(string: "https://auth.openai.com" + path)!)
        for _ in 0..<100 where session.webView.isLoading {
            try await Task.sleep(for: .milliseconds(50))
        }
        try #require(!session.webView.isLoading)
        return session
    }

    @Test(arguments: [false, true])
    func automaticMFARequiresProofOfPasswordSubmission(passwordSubmitted: Bool) async throws {
        let session = try await fixture()
        defer { session.cancelLoading() }
        let browser = ChatGPTAutomation(sessionManager: WebSessionManager())
        let result = await browser.signIn(account: account, secret: account.totpSecret, in: session,
            initialProof: .init(passwordSubmitted: passwordSubmitted, pendingOTPSubmitted: false),
            requireExplicitProof: true, loginTimeoutSeconds: 1, automaticallyWaitForTransitions: true)

        guard case .manual(let message, let proof) = result else {
            Issue.record("Unauthenticated MFA fixture must pause without accepting the account")
            return
        }
        if passwordSubmitted {
            #expect(try await session.evaluate("document.body.dataset.submits") as? String == "1")
            #expect(proof.pendingOTPSubmitted)
        } else {
            #expect(message.contains("2FA до ввода пароля"))
            #expect(try await session.evaluate("document.querySelector('#code').value") as? String == "")
            #expect(try await session.evaluate("document.body.dataset.submits === undefined") as? Bool == true)
            #expect(proof == .none)
        }
        #expect(!proof.isSufficient)
    }

    @Test func staleMFAURLWaitsForMatchingDocumentBeforeReportingMissingPassword() async throws {
        let session = try await fixture(path: "/log-in")
        defer { session.cancelLoading() }
        let web = try #require(session.webView as? MFAProofFixtureWebView)
        web.reportedURL = URL(string: "https://auth.openai.com/mfa-challenge/fixture")!
        let browser = ChatGPTAutomation(sessionManager: WebSessionManager())
        let result = await browser.signIn(account: account, secret: account.totpSecret, in: session,
            requireExplicitProof: true, loginTimeoutSeconds: 1, automaticallyWaitForTransitions: true)

        guard case .manual(let message, let proof) = result else {
            Issue.record("Stale MFA URL must wait without entering a code")
            return
        }
        #expect(message.contains("timed out"))
        #expect(try await session.evaluate("document.querySelector('#code').value") as? String == "")
        #expect(try await session.evaluate("document.body.dataset.submits === undefined") as? Bool == true)
        #expect(proof == .none)
    }
}
