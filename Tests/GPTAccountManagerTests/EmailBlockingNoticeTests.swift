import AppKit
import Foundation
import Testing
import WebKit
@testable import GPTAccountManager

@MainActor
private final class BlockingNoticeMailbox: EmailCodeReceiving {
    var baselineCalls = 0
    var codeCalls = 0
    var onBaseline: (() async throws -> Void)?
    var onCode: ((String, Date, Set<String>) async throws -> Void)?

    func captureBaseline() async throws -> Set<String> {
        baselineCalls += 1
        try await onBaseline?()
        return ["before-request"]
    }

    func waitForCode(alias: String, since: Date, excluding: Set<String>) async throws -> MailVerificationCode {
        codeCalls += 1
        try await onCode?(alias, since, excluding)
        return .init(messageID: "fresh-message", code: "123456")
    }

    func cancel() {}
}

@MainActor
private final class BlockingNoticeNavigationBlocker: NSObject, WKNavigationDelegate {
    var blockedNavigations = 0
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        blockedNavigations += 1
        decisionHandler(.cancel)
    }
}

@MainActor
@Suite(.serialized)
struct EmailBlockingNoticeTests {
    private func account(phase: EmailChangePhase) -> AccountRecord {
        var account = AccountRecord(credential: .init(email: "old@example.com", password: "fixture-password",
                                                     totpSecret: "JBSWY3DPEHPK3PXP"))
        account.pendingEmailChange = .init(aliasID: UUID(), originalEmail: account.email,
            newEmail: "new@example.com", phase: phase, baselineMessageIDs: ["before-request"],
            requestedAt: Date(timeIntervalSince1970: 1_700_000_000), originalUserID: "same-user")
        return account
    }

    private func fixture(code: Bool = false) async throws -> (BrowserSession, BlockingNoticeNavigationBlocker) {
        _ = NSApplication.shared
        let session = BrowserSession(dataStore: .nonPersistent())
        session.webView.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        session.webView.navigationDelegate = nil
        let notice = String(decoding: try JSONEncoder().encode("""
        <div role="dialog" id="renewal"><h2>Продлите подписку на ChatGPT Plus</h2>
          <p>Не удалось обработать платёж.</p>
          <button onclick="window.paymentActions++">Добавить способ оплаты</button>
          <button onclick="window.dismissals++;document.getElementById('email-background').removeAttribute('inert');document.getElementById('renewal').remove()">Закрыть</button>
          <button onclick="window.paymentActions++">Оплатить сейчас</button>
          <button aria-label="Закрыть диалог" onclick="window.genericCloses++">×</button>
        </div>
        """), as: UTF8.self)
        let input = code
            ? "<p>Code sent to new@example.com</p><label>Verification code<input autocomplete='one-time-code'></label><button>Verify</button>"
            : "<label>Email address<input type='email'></label><button>Send verification email</button>"
        session.webView.loadHTMLString("""
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; form-action 'none'">
        <section id="email-background"><div role="dialog"><h2>Edit email address</h2>
          <form onsubmit="event.preventDefault();window.submissions++">\(input)</form>
        </div></section>
        <script>
          window.submissions=0;window.dismissals=0;window.paymentActions=0;window.genericCloses=0;
          window.fetch=async()=>({ok:true,json:async()=>({user:{email:'old@example.com',id:'same-user'}})});
          window.blockEmail=()=>{
            document.getElementById('email-background').setAttribute('inert','');
            document.body.insertAdjacentHTML('beforeend',\(notice));
            return true;
          };
          window.fixtureReady=true;
        </script>
        """, baseURL: URL(string: "https://chatgpt.com/settings/account"))
        try #require(try await waitUntil { (try? await session.evaluate("window.fixtureReady === true")) as? Bool == true })
        let blocker = BlockingNoticeNavigationBlocker()
        session.webView.navigationDelegate = blocker
        return (session, blocker)
    }

    private func waitUntil(_ condition: () async throws -> Bool) async throws -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline {
            if try await condition() { return true }
            try await Task.sleep(for: .milliseconds(20))
        }
        return false
    }

    @Test func noticeAppearingDuringFinalBaselineDoesNotLoseOrRepeatEmailSubmission() async throws {
        let (session, blocker) = try await fixture()
        let mailbox = BlockingNoticeMailbox()
        mailbox.onBaseline = {
            if mailbox.baselineCalls == 2 { _ = try await session.evaluate("window.blockEmail()") }
        }
        let changer = EmailChangeAutomation(browser: ChatGPTAutomation(
            sessionManager: WebSessionManager(accountSessionFactory: { _ in session })), mailbox: mailbox)
        let candidate = account(phase: .reserved)
        var checkpoints: [PendingEmailChange] = []
        var finished = false
        let task = Task {
            let outcome = await changer.changeEmail(account: candidate) { checkpoints.append($0) }
            finished = true
            return outcome
        }
        defer { changer.cancel(); task.cancel() }
        _ = try await waitUntil {
            if finished { return true }
            return (try await session.evaluate("window.submissions") as? Int) == 1
        }
        #expect(!finished)
        #expect(try await session.evaluate("window.submissions === 1 && window.dismissals === 1 && window.paymentActions === 0 && window.genericCloses === 0") as? Bool == true)
        try await Task.sleep(for: .milliseconds(1100))
        changer.cancel()
        _ = await task.value
        #expect(checkpoints.map(\.phase) == [.reserved, .requested])
        let requested = try #require(checkpoints.last)
        #expect(requested.operationID == candidate.pendingEmailChange?.operationID)
        #expect(requested.baselineMessageIDs == ["before-request"])
        #expect(requested.requestedAt != nil && requested.requestAttemptID != nil)
        #expect(mailbox.baselineCalls == 2 && mailbox.codeCalls == 0)
        #expect(try await session.evaluate("window.submissions === 1 && document.querySelector('input').value === 'new@example.com'") as? Bool == true)
        #expect(blocker.blockedNavigations == 0)
    }

    @Test func noticeAppearingDuringMailReadDoesNotLoseOrRepeatCodeSubmission() async throws {
        let (session, blocker) = try await fixture(code: true)
        let mailbox = BlockingNoticeMailbox()
        let candidate = account(phase: .requested)
        let pending = try #require(candidate.pendingEmailChange)
        mailbox.onCode = { alias, since, excluding in
            #expect(alias == pending.newEmail)
            #expect(since == pending.requestedAt)
            #expect(excluding == pending.baselineMessageIDs)
            _ = try await session.evaluate("window.blockEmail()")
        }
        let changer = EmailChangeAutomation(browser: ChatGPTAutomation(
            sessionManager: WebSessionManager(accountSessionFactory: { _ in session })), mailbox: mailbox)
        var checkpoints: [PendingEmailChange] = []
        var finished = false
        let task = Task {
            let outcome = await changer.changeEmail(account: candidate) { checkpoints.append($0) }
            finished = true
            return outcome
        }
        defer { changer.cancel(); task.cancel() }
        _ = try await waitUntil {
            if finished { return true }
            return (try await session.evaluate("window.submissions") as? Int) == 1
        }
        #expect(!finished)
        #expect(try await session.evaluate("window.submissions === 1 && window.dismissals === 1 && window.paymentActions === 0 && window.genericCloses === 0") as? Bool == true)
        changer.cancel()
        _ = await task.value
        #expect(checkpoints.map(\.phase) == [.confirming])
        let confirming = try #require(checkpoints.last)
        #expect(confirming.operationID == pending.operationID)
        #expect(confirming.requestedAt == pending.requestedAt)
        #expect(confirming.baselineMessageIDs == pending.baselineMessageIDs)
        #expect(mailbox.baselineCalls == 0 && mailbox.codeCalls == 1)
        #expect(try await session.evaluate("window.submissions === 1 && document.querySelector('input').value === '123456'") as? Bool == true)
        #expect(blocker.blockedNavigations == 0)
    }
}
