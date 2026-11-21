import AppKit
import Foundation
import Testing
import WebKit
@testable import GPTAccountManager

@MainActor
private final class ContinuousEmailMailbox: EmailCodeReceiving {
    struct Request {
        let since: Date
        let excluding: Set<String>
    }
    var baselineCalls = 0
    var requests: [Request] = []
    var onTimeout: (() -> Void)?
    var baselineTimeouts = 0

    func captureBaseline() async throws -> Set<String> {
        baselineCalls += 1
        if baselineCalls <= baselineTimeouts { throw MailVerificationError.timedOut }
        return ["before-request"]
    }

    func waitForCode(alias: String, since: Date, excluding: Set<String>) async throws -> MailVerificationCode {
        #expect(alias == "new@example.com")
        requests.append(.init(since: since, excluding: excluding))
        if requests.count == 1 {
            onTimeout?()
            throw MailVerificationError.timedOut
        }
        return .init(messageID: "fresh-message", code: "123456")
    }

    func cancel() {}
}

@MainActor
private final class ContinuousEmailNavigationBlocker: NSObject, WKNavigationDelegate {
    var requestedURLs: [URL] = []
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        if let url = action.request.url { requestedURLs.append(url) }
        decisionHandler(.cancel)
    }
}

@MainActor
@Suite(.serialized)
struct EmailContinuousWaitTests {
    private func account(phase: EmailChangePhase = .reserved) -> AccountRecord {
        var account = AccountRecord(credential: .init(email: "old@example.com", password: "fixture-password",
                                                     totpSecret: "JBSWY3DPEHPK3PXP"))
        account.pendingEmailChange = .init(aliasID: UUID(), originalEmail: account.email,
            newEmail: "new@example.com", phase: phase, baselineMessageIDs: ["before-request"],
            requestedAt: Date(timeIntervalSince1970: 1_700_000_000), originalUserID: "same-user")
        return account
    }

    private func load(_ html: String, url: String, in session: BrowserSession) async throws {
        _ = NSApplication.shared
        session.webView.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        session.webView.navigationDelegate = nil
        session.webView.loadHTMLString("""
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; form-action 'none'">
        \(html)
        <script>window.fixtureReady=true;</script>
        """, baseURL: URL(string: url))
        try await waitUntil { (try? await session.evaluate("window.fixtureReady === true")) as? Bool == true }
    }

    private func waitUntil(_ condition: () async throws -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while ContinuousClock.now < deadline {
            if try await condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw FixtureError.timedOut
    }

    private enum FixtureError: Error { case timedOut }

    @Test func baselineTimeoutBeforeRequestIsRetriedWithoutAdvancingCheckpoint() async throws {
        let session = BrowserSession(dataStore: .nonPersistent())
        try await load(Self.emailEntry + """
        <script>window.fetch=async()=>({ok:true,json:async()=>({user:{email:'old@example.com',id:'same-user'}})});</script>
        """, url: "https://chatgpt.com/settings/account", in: session)
        let mailbox = ContinuousEmailMailbox()
        mailbox.baselineTimeouts = 1
        let changer = EmailChangeAutomation(browser: ChatGPTAutomation(
            sessionManager: WebSessionManager(accountSessionFactory: { _ in session })), mailbox: mailbox)
        var phases: [EmailChangePhase] = []
        _ = await changer.changeEmail(account: account()) {
            phases.append($0.phase)
            if $0.phase == .requested { throw CancellationError() }
        }
        #expect(phases == [.reserved, .requested])
        #expect(mailbox.baselineCalls == 3)
        #expect(try await session.evaluate("document.querySelector('input').value === ''") as? Bool == true)
    }

    @Test(arguments: [1, 2, 3, 4], [false, true])
    func verificationRetriesTransientIdentityReadsWithoutLoggingInAgain(failedRead: Int, networkFailure: Bool) async throws {
        let original = BrowserSession(dataStore: .nonPersistent())
        try await load("""
        <script>window.fetch=async()=>({ok:true,json:async()=>({user:{email:'new@example.com',id:'same-user'}})});</script>
        """, url: "https://chatgpt.com/", in: original)
        let changer = EmailChangeAutomation(browser: ChatGPTAutomation(
            sessionManager: WebSessionManager(accountSessionFactory: { _ in original })), mailbox: ContinuousEmailMailbox())
        let candidate = account(phase: .confirming)
        #expect(changer.resetVerificationSession(for: candidate))
        let verification = try #require(changer.browserSession(for: candidate))
        try await load("""
        <script>window.reads=0;window.fetch=async()=>{window.reads++;
          if (window.reads===\(failedRead) && \(networkFailure)) throw new TypeError('Load failed');
          return {ok:window.reads!==\(failedRead),status:window.reads===\(failedRead)?503:200,
          json:async()=>({user:{email:'new@example.com',id:'same-user'}})};};</script>
        """, url: "https://chatgpt.com/", in: verification)
        let outcome = await changer.changeEmail(account: candidate) { _ in Issue.record("Unexpected checkpoint") }
        guard case .success(let proof) = outcome else { Issue.record("Transient identity read paused verification"); return }
        #expect(proof == .init(email: "new@example.com", userID: "same-user"))
        #expect((try await verification.evaluate("window.reads") as? Int ?? 0) > failedRead)
    }

    @Test func slowEditorRequestMailboxAndVerificationContinueWithoutReplay() async throws {
        let original = BrowserSession(dataStore: .nonPersistent())
        let entry = String(decoding: try JSONEncoder().encode(Self.emailEntry), as: UTF8.self)
        let code = String(decoding: try JSONEncoder().encode(Self.emailCode), as: UTF8.self)
        try await load("""
        <main id="flow"><button aria-label="Change email address: old@example.com" onclick="window.opens++">Edit</button></main>
        <script>
          window.opens=0; window.emailSubmissions=0; window.codeSubmissions=0;
          window.fetch=async()=>({ok:true,json:async()=>({user:{email:window.codeSubmissions ? 'new@example.com' : 'old@example.com',id:'same-user'}})});
          window.showEntry=()=>document.getElementById('flow').innerHTML=\(entry);
          window.showCode=()=>document.getElementById('flow').innerHTML=\(code);
        </script>
        """, url: "https://chatgpt.com/settings/account", in: original)
        let originalBlocker = ContinuousEmailNavigationBlocker()
        original.webView.navigationDelegate = originalBlocker
        let mailbox = ContinuousEmailMailbox()
        let changer = EmailChangeAutomation(browser: ChatGPTAutomation(
            sessionManager: WebSessionManager(accountSessionFactory: { _ in original })),
            mailbox: mailbox, waitNoticeInterval: .milliseconds(50))
        let candidate = account()
        var verificationAccount = candidate
        verificationAccount.pendingEmailChange?.phase = .confirming
        #expect(changer.resetVerificationSession(for: verificationAccount))
        let verification = try #require(changer.browserSession(for: verificationAccount))
        try await load("""
        <p>Waiting for login response</p><script>
          window.allowLogin=false;
          window.fetch=async()=>({ok:true,json:async()=>window.allowLogin ? {user:{email:'new@example.com',id:'same-user'}} : {}});
        </script>
        """, url: "https://chatgpt.com/", in: verification)
        let verificationBlocker = ContinuousEmailNavigationBlocker()
        verification.webView.navigationDelegate = verificationBlocker
        var checkpoints: [PendingEmailChange] = []
        var finished = false
        let task = Task {
            let result = await changer.changeEmail(account: candidate) { checkpoints.append($0) }
            finished = true
            return result
        }
        defer { changer.cancel(); task.cancel() }

        try await waitUntil { original.operationMessage?.contains("продолжается автоматически") == true }
        #expect(!finished && checkpoints.map(\.phase) == [.reserved])
        #expect(try await original.evaluate("window.opens") as? Int == 1)
        _ = try await original.evaluate("(() => { window.showEntry(); return true; })()")
        try await waitUntil { (try? await original.evaluate("window.emailSubmissions === 1")) as? Bool == true }
        // Cross the next stage's wait notice before releasing its response.
        try await waitUntil { original.operationMessage?.contains("ожидается подтверждение OpenAI") == true }
        try await waitUntil { original.operationMessage?.contains("продолжается автоматически") == true }
        #expect(!finished && checkpoints.map(\.phase) == [.reserved, .requested])
        #expect(try await original.evaluate("window.opens === 1 && window.emailSubmissions === 1") as? Bool == true)
        _ = try await original.evaluate("(() => { window.showCode(); return true; })()")
        try await waitUntil { verification.operationMessage?.contains("продолжается автоматически") == true }
        #expect(!finished && checkpoints.map(\.phase) == [.reserved, .requested, .confirming])
        #expect(try await original.evaluate("window.emailSubmissions === 1 && window.codeSubmissions === 1") as? Bool == true)
        _ = try await verification.evaluate("(() => { window.allowLogin=true; return true; })()")
        try await waitUntil { finished }
        guard case .success(let proof) = await task.value else { Issue.record("Delayed email workflow did not complete"); return }
        #expect(proof == .init(email: "new@example.com", userID: "same-user"))
        #expect(mailbox.requests.count == 2)
        let requested = try #require(checkpoints.first { $0.phase == .requested })
        #expect(mailbox.requests.allSatisfy { $0.since == requested.requestedAt && $0.excluding == requested.baselineMessageIDs })
        #expect(mailbox.baselineCalls == 3) // Original login, email request, isolated verification login.
        #expect(originalBlocker.requestedURLs.isEmpty && verificationBlocker.requestedURLs.isEmpty)
    }

    @Test func cancellationDuringMailboxTimeoutDoesNotRetryOrAdvanceCheckpoint() async throws {
        let session = BrowserSession(dataStore: .nonPersistent())
        try await load(Self.emailCode, url: "https://chatgpt.com/settings/account", in: session)
        let mailbox = ContinuousEmailMailbox()
        let changer = EmailChangeAutomation(browser: ChatGPTAutomation(
            sessionManager: WebSessionManager(accountSessionFactory: { _ in session })),
            mailbox: mailbox, waitNoticeInterval: .milliseconds(50))
        mailbox.onTimeout = { changer.cancel() }
        let outcome = await changer.changeEmail(account: account(phase: .requested)) { _ in
            Issue.record("Cancelled mailbox wait advanced checkpoint")
        }
        guard case .manual(let message) = outcome else { Issue.record("Cancelled wait did not stop"); return }
        #expect(message.contains("остановлена"))
        #expect(mailbox.requests.count == 1 && mailbox.baselineCalls == 0)
        #expect(try await session.evaluate("document.querySelector('input').value === ''") as? Bool == true)
    }

    @Test(arguments: ["Verify you are human", "Server Error 500", "account_deactivated", "Incorrect password"])
    func explicitChallengesAndErrorsStopWithoutSubmitting(text: String) async throws {
        let session = BrowserSession(dataStore: .nonPersistent())
        try await load("""
        <p>\(text)</p><form onsubmit="event.preventDefault();window.submitted=true">
          <input type="password"><button>Continue</button>
        </form>
        """, url: "https://auth.openai.com/log-in/password", in: session)
        let mailbox = ContinuousEmailMailbox()
        let changer = EmailChangeAutomation(browser: ChatGPTAutomation(
            sessionManager: WebSessionManager(accountSessionFactory: { _ in session })), mailbox: mailbox)
        let outcome = await changer.changeEmail(account: account()) { _ in Issue.record("Unexpected checkpoint") }
        guard case .manual = outcome else { Issue.record("Explicit challenge/error was ignored"); return }
        #expect(try await session.evaluate("document.querySelector('input').value === '' && window.submitted !== true") as? Bool == true)
        #expect(mailbox.requests.isEmpty)
    }

    private static let emailEntry = """
    <div role="dialog"><h2>Edit email address</h2><form onsubmit="event.preventDefault();window.emailSubmissions++">
      <input type="email"><button>Send verification email</button>
    </form></div>
    """

    private static let emailCode = """
    <div role="dialog"><h2>Verify your email</h2>
      <p>Code sent to new@example.com to finish updating your email</p>
      <form onsubmit="event.preventDefault();window.codeSubmissions=(window.codeSubmissions || 0)+1">
        <label>Verification code<input name="code"></label><button>Verify</button>
      </form>
    </div>
    """
}
