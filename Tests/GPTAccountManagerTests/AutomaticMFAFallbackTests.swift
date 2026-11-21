import AppKit
import SwiftUI
import Testing
import WebKit
@testable import GPTAccountManager

@MainActor
@Suite(.serialized)
struct AutomaticMFAFallbackTests {
    private let account = AccountRecord(credential: .init(
        email: "fixture@example.com", password: "fixture", totpSecret: "JBSWY3DPEHPK3PXP"))

    private func fixture(_ html: String) async throws -> BrowserSession {
        _ = NSApplication.shared
        let session = BrowserSession(dataStore: .nonPersistent())
        session.webView.frame = NSRect(x: 0, y: 0, width: 720, height: 500)
        session.webView.navigationDelegate = nil
        session.webView.loadHTMLString(html,
            baseURL: URL(string: "https://auth.openai.com/mfa-challenge/fixture")!)
        for _ in 0..<100 where session.webView.isLoading {
            try await Task.sleep(for: .milliseconds(50))
        }
        try #require(!session.webView.isLoading)
        return session
    }

    @Test func automaticLoginUsesKeyboardWhenMFAFieldIsMissingFromDOMQueries() async throws {
        let session = try await fixture("""
        <a id="before" href="#">OpenAI</a>
        <form id="mfa"><input id="code"><button>Continue</button></form>
        <script>
          document.querySelector('#mfa').addEventListener('submit', event => {
            event.preventDefault();
            document.body.dataset.submits = String(Number(document.body.dataset.submits || 0) + 1);
            document.body.dataset.code = document.querySelector('#code').value;
          });
          // The real field remains keyboard-focusable while WebKit's DOM lookup misses it.
          const queryAll = document.querySelectorAll.bind(document);
          document.querySelectorAll = selector => selector.startsWith('input') ? [] : queryAll(selector);
        </script>
        """)
        let host = NSHostingView(rootView: BrowserView(session: session))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 500),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        defer { session.cancelLoading(); window.contentView = nil }
        session.setVisible(true)
        host.layoutSubtreeIfNeeded()
        try #require(await session.waitUntilAttached(seconds: 2))
        _ = try await session.evaluate("document.querySelector('#before').focus()")

        let browser = ChatGPTAutomation(sessionManager: WebSessionManager())
        let result = await browser.signIn(account: account, secret: account.totpSecret, in: session,
            initialProof: .init(passwordSubmitted: true, pendingOTPSubmitted: false),
            requireExplicitProof: true, loginTimeoutSeconds: 1, automaticallyWaitForTransitions: true)

        #expect(try await session.evaluate("document.body.dataset.submits") as? String == "1")
        #expect(try await session.evaluate("/^\\d{6}$/.test(document.body.dataset.code || '')") as? Bool == true)
        guard case .manual(_, let proof) = result else {
            Issue.record("Submitted fixture must await authentication in the same MFA session")
            return
        }
        #expect(proof.pendingOTPSubmitted)
        #expect(!proof.isSufficient)
    }

    @Test func automaticLoginWaitsForDelayedMFAFieldWhenBrowserIsNotMounted() async throws {
        let session = try await fixture("""
        <main>Loading</main>
        <script>
          const queryAll = document.querySelectorAll.bind(document);
          document.querySelectorAll = selector => {
            if (selector === "input:not([type='hidden'])" && !window.fieldScheduled) {
              window.fieldScheduled = true;
              setTimeout(() => {
                document.body.innerHTML = '<form><input id="code"><button>Continue</button></form>';
                document.querySelector('form').addEventListener('submit', event => {
                  event.preventDefault();
                  document.body.dataset.submits = String(Number(document.body.dataset.submits || 0) + 1);
                  document.body.dataset.code = document.querySelector('#code').value;
                });
              }, 2300);
            }
            return queryAll(selector);
          };
        </script>
        """)
        defer { session.cancelLoading() }
        #expect(session.webView.window == nil)
        let browser = ChatGPTAutomation(sessionManager: WebSessionManager())
        let login = Task {
            await browser.signIn(account: account, secret: account.totpSecret, in: session,
                initialProof: .init(passwordSubmitted: true, pendingOTPSubmitted: false),
                requireExplicitProof: true, loginTimeoutSeconds: 10, automaticallyWaitForTransitions: true)
        }
        defer { login.cancel() }
        for _ in 0..<120 {
            if try await session.evaluate("document.body.dataset.submits") as? String == "1" { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        login.cancel()
        _ = await login.value

        #expect(try await session.evaluate("document.body.dataset.submits") as? String == "1")
        #expect(try await session.evaluate("/^\\d{6}$/.test(document.body.dataset.code || '')") as? Bool == true)
    }
}
