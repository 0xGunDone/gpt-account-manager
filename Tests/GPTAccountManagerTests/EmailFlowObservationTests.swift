import AppKit
import Foundation
import Testing
import WebKit
@testable import GPTAccountManager

@MainActor
private final class ObservedEmailMailbox: EmailCodeReceiving {
    private(set) var baselineCalls = 0
    private(set) var baselineWaiting = false
    private var continuation: CheckedContinuation<Set<String>, any Error>?

    func captureBaseline() async throws -> Set<String> {
        baselineCalls += 1
        if baselineCalls == 2 {
            baselineWaiting = true
            return try await withCheckedThrowingContinuation { continuation = $0 }
        }
        return ["before-request"]
    }

    func releaseBaseline() {
        baselineWaiting = false
        let pending = continuation
        continuation = nil
        pending?.resume(returning: ["before-request"])
    }

    func waitForCode(alias: String, since: Date, excluding: Set<String>) async throws -> MailVerificationCode {
        Issue.record("Observation fixture must not request a verification code")
        throw CancellationError()
    }

    func cancel() {
        let pending = continuation
        continuation = nil
        pending?.resume(throwing: CancellationError())
    }
}

@MainActor
private final class ObservedEmailNavigationBlocker: NSObject, WKNavigationDelegate {
    private(set) var blockedNavigations = 0
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        blockedNavigations += 1
        decisionHandler(.cancel)
    }
}

@MainActor
@Suite(.serialized)
struct EmailFlowObservationTests {
    private func waitUntil(_ condition: () async throws -> Bool) async throws -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline {
            if try await condition() { return true }
            try await Task.sleep(for: .milliseconds(20))
        }
        return false
    }

    @Test func visibleWaitStagesDistinguishIdentityMailboxAndRecheckWithoutAdvancingRequest() async throws {
        _ = NSApplication.shared
        let session = BrowserSession(dataStore: .nonPersistent())
        session.webView.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        session.webView.navigationDelegate = nil
        session.webView.loadHTMLString("""
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline'; form-action 'none'">
        <div role="dialog"><h2>Edit email address</h2>
          <form onsubmit="event.preventDefault();window.submissions++">
            <label>Email address<input type="email"></label><button>Send verification email</button>
          </form>
        </div><script>
          window.identityReads=0;window.awaitedIdentity=0;window.submissions=0;
          window.fetch=async()=>{
            const read=++window.identityReads;
            if(read===3||read===4) {
              window.awaitedIdentity=read;
              await new Promise(resolve=>window.releaseIdentity=resolve);
            }
            return {ok:true,json:async()=>({user:{email:'old@example.com',id:'same-user'}})};
          };
          window.fixtureReady=true;
        </script>
        """, baseURL: URL(string: "https://chatgpt.com/settings/account"))
        try #require(try await waitUntil { (try? await session.evaluate("window.fixtureReady === true")) as? Bool == true })
        let blocker = ObservedEmailNavigationBlocker()
        session.webView.navigationDelegate = blocker
        let mailbox = ObservedEmailMailbox()
        let changer = EmailChangeAutomation(browser: ChatGPTAutomation(
            sessionManager: WebSessionManager(accountSessionFactory: { _ in session })), mailbox: mailbox)
        var account = AccountRecord(credential: .init(email: "old@example.com", password: "fixture-password",
                                                     totpSecret: "JBSWY3DPEHPK3PXP"))
        account.pendingEmailChange = .init(aliasID: UUID(), originalEmail: account.email,
                                          newEmail: "new@example.com", phase: .reserved)
        var checkpoints: [PendingEmailChange] = []
        let task = Task { await changer.changeEmail(account: account) { checkpoints.append($0) } }
        defer { changer.cancel(); task.cancel() }

        try #require(try await waitUntil { (try await session.evaluate("window.awaitedIdentity") as? Int) == 3 })
        #expect(session.operationMessage == "Смена email: проверяется исходный аккаунт перед чтением почты…")
        #expect(checkpoints.map(\.phase) == [.reserved])
        #expect(mailbox.baselineCalls == 1)

        _ = try await session.evaluate("(() => { window.releaseIdentity(); return true; })()")
        try #require(try await waitUntil { mailbox.baselineWaiting })
        #expect(session.operationMessage == "Смена email: фиксируется исходное состояние почты…")
        #expect(checkpoints.map(\.phase) == [.reserved])
        #expect(try await session.evaluate("window.submissions === 0 && document.querySelector('input').value === ''") as? Bool == true)

        mailbox.releaseBaseline()
        try #require(try await waitUntil { (try await session.evaluate("window.awaitedIdentity") as? Int) == 4 })
        #expect(session.operationMessage == "Смена email: повторно проверяется исходный аккаунт…")
        #expect(checkpoints.map(\.phase) == [.reserved])
        changer.cancel()
        task.cancel()
        let outcome = await task.value
        guard case .manual = outcome else { Issue.record("Cancelled observation must leave operation pending"); return }
        #expect(checkpoints.count == 1 && checkpoints[0].requestedAt == nil)
        #expect(mailbox.baselineCalls == 2)
        #expect(try await session.evaluate("window.submissions === 0 && document.querySelector('input').value === ''") as? Bool == true)
        #expect(blocker.blockedNavigations == 0)
    }
}
