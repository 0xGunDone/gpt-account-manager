import AppKit
import Foundation
import Testing
@testable import GPTAccountManager

@MainActor
private final class ReauthenticationMailbox: EmailCodeReceiving {
    struct Request {
        let alias: String
        let since: Date
        let excluding: Set<String>
        let purpose: MailVerificationPurpose
    }
    var baselineCalls = 0
    var requests: [Request] = []
    var onBaseline: (() async throws -> Void)?
    var onCode: (() async throws -> Void)?

    func captureBaseline() async throws -> Set<String> {
        baselineCalls += 1
        try await onBaseline?()
        return ["before-login"]
    }

    func waitForCode(alias: String, since: Date, excluding: Set<String>) async throws -> MailVerificationCode {
        Issue.record("Authentication must specify login purpose")
        throw CancellationError()
    }

    func waitForCode(alias: String, since: Date, excluding: Set<String>, purpose: MailVerificationPurpose) async throws -> MailVerificationCode {
        requests.append(.init(alias: alias, since: since, excluding: excluding, purpose: purpose))
        try await onCode?()
        return .init(messageID: "fresh-login", code: "123456")
    }

    func cancel() {}
}

@MainActor
@Suite(.serialized)
struct EmailReauthenticationCodeTests {
    private func account(phase: EmailChangePhase = .reserved) -> AccountRecord {
        var account = AccountRecord(credential: .init(email: "old@example.com", password: "fixture-password",
                                                       totpSecret: "JBSWY3DPEHPK3PXP"))
        account.pendingEmailChange = .init(aliasID: UUID(), originalEmail: account.email,
            newEmail: "reserved@icloud.com", phase: phase, originalUserID: "original-user")
        return account
    }

    private func load(_ html: String, path: String, in session: BrowserSession) async throws {
        _ = NSApplication.shared
        session.webView.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        session.webView.navigationDelegate = nil
        session.webView.loadHTMLString("""
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; form-action 'none'">
        \(html)
        """, baseURL: URL(string: "https://auth.openai.com\(path)"))
        for _ in 0..<100 where session.webView.isLoading { try await Task.sleep(for: .milliseconds(20)) }
        try #require(!session.webView.isLoading)
    }

    private func codeForm(email: String) -> String {
        """
        <form onsubmit="event.preventDefault();document.body.dataset.code=document.querySelector('input').value;document.body.dataset.submissions=String(Number(document.body.dataset.submissions||0)+1)">
          <p>We emailed a sign-in code to \(email)</p>
          <label>Verification code<input autocomplete="one-time-code" name="code"></label>
          <button>Continue</button>
        </form>
        """
    }

    private func passwordThenCode(email: String) throws -> String {
        let form = String(decoding: try JSONEncoder().encode(codeForm(email: email)), as: UTF8.self)
        return """
        <form onsubmit="event.preventDefault();openCode()"><input type="password"><button>Continue</button></form>
        <script>function openCode(){history.replaceState({},'', '/email-verification');document.body.innerHTML=\(form);}</script>
        """
    }

    private func waitForCodeSubmission(in session: BrowserSession) async throws {
        for _ in 0..<200 {
            if try await session.evaluate("document.body.dataset.code === '123456'") as? Bool == true { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("Authentication code was not submitted")
    }

    @Test(arguments: [false, true])
    func delayedLoginCodeKeepsPollingWithOriginalBaselineAndSubmitsOnlyOnce(interruptedReply: Bool) async throws {
        let session = BrowserSession(dataStore: .nonPersistent())
        try await load(passwordThenCode(email: "old@example.com"), path: "/log-in/password", in: session)
        if interruptedReply {
            _ = try await session.evaluate("""
            (() => {
              const button=document.querySelector('button');
              button.click=function(){ HTMLButtonElement.prototype.click.call(this); throw new Error('Navigation interrupted reply'); };
              return true;
            })()
            """)
        }
        let mailbox = ReauthenticationMailbox()
        let changer = EmailChangeAutomation(browser: ChatGPTAutomation(
            sessionManager: WebSessionManager(accountSessionFactory: { _ in session })), mailbox: mailbox)
        let candidate = account()
        mailbox.onBaseline = {
            #expect(session.webView.url?.path == "/log-in/password")
            let value = try await session.evaluate("document.querySelector('input').value") as? String
            #expect(value == "")
        }
        mailbox.onCode = {
            if mailbox.requests.count == 1 { throw MailVerificationError.timedOut }
        }
        let task = Task { await changer.changeEmail(account: candidate) { _ in Issue.record("Unexpected checkpoint") } }
        defer { changer.cancel(); task.cancel() }
        try await waitForCodeSubmission(in: session)
        try await Task.sleep(for: .milliseconds(800))
        changer.cancel()
        _ = await task.value

        #expect(mailbox.baselineCalls == 1 && mailbox.requests.count == 2)
        let previous = try #require(mailbox.requests.first)
        let resumed = try #require(mailbox.requests.last)
        #expect(resumed.alias == "old@example.com" && resumed.purpose == .login)
        #expect(resumed.since == previous.since && resumed.excluding == ["before-login"])
        #expect(try await session.evaluate("document.body.dataset.submissions") as? String == "1")
    }

    @Test(arguments: ["old@example.com", "reserved@icloud.com"])
    func existingAuthenticationChallengeWithoutBaselineNeverReadsCode(displayedEmail: String) async throws {
        let session = BrowserSession(dataStore: .nonPersistent())
        try await load(codeForm(email: displayedEmail), path: "/email-verification", in: session)
        let mailbox = ReauthenticationMailbox()
        let changer = EmailChangeAutomation(browser: ChatGPTAutomation(
            sessionManager: WebSessionManager(accountSessionFactory: { _ in session })), mailbox: mailbox)
        let outcome = await changer.changeEmail(account: account()) { _ in Issue.record("Unexpected checkpoint") }
        guard case .manual = outcome else { Issue.record("Unproven request should pause"); return }
        #expect(mailbox.baselineCalls == 0 && mailbox.requests.isEmpty)
        #expect(try await session.evaluate("document.querySelector('input').value") as? String == "")
    }

    @Test func currentAccountChallengeCannotConsumeReservedAliasCode() async throws {
        let session = BrowserSession(dataStore: .nonPersistent())
        try await load(passwordThenCode(email: "reserved@icloud.com"), path: "/log-in/password", in: session)
        let mailbox = ReauthenticationMailbox()
        let changer = EmailChangeAutomation(browser: ChatGPTAutomation(
            sessionManager: WebSessionManager(accountSessionFactory: { _ in session })), mailbox: mailbox)
        let outcome = await changer.changeEmail(account: account()) { _ in Issue.record("Unexpected checkpoint") }
        guard case .manual = outcome else { Issue.record("Wrong recipient should pause"); return }
        #expect(mailbox.baselineCalls == 1 && mailbox.requests.isEmpty)
        #expect(try await session.evaluate("document.querySelector('input').value") as? String == "")
    }

    @Test func cancellationAfterMailboxReadPreventsCodeSubmission() async throws {
        let session = BrowserSession(dataStore: .nonPersistent())
        try await load(passwordThenCode(email: "old@example.com"), path: "/log-in/password", in: session)
        let mailbox = ReauthenticationMailbox()
        let changer = EmailChangeAutomation(browser: ChatGPTAutomation(
            sessionManager: WebSessionManager(accountSessionFactory: { _ in session })), mailbox: mailbox)
        mailbox.onCode = { changer.cancel() }
        let outcome = await changer.changeEmail(account: account()) { _ in Issue.record("Unexpected checkpoint") }
        guard case .manual = outcome else { Issue.record("Cancelled operation should pause"); return }
        #expect(mailbox.requests.count == 1)
        #expect(try await session.evaluate("document.querySelector('input').value") as? String == "")
    }

    @Test func fetchedCodeWaitsForDisabledButtonWithoutAnotherMailboxRead() async throws {
        let session = BrowserSession(dataStore: .nonPersistent())
        try await load(passwordThenCode(email: "old@example.com"), path: "/log-in/password", in: session)
        let mailbox = ReauthenticationMailbox()
        let changer = EmailChangeAutomation(browser: ChatGPTAutomation(
            sessionManager: WebSessionManager(accountSessionFactory: { _ in session })), mailbox: mailbox)
        mailbox.onCode = {
            _ = try await session.evaluate("(() => { document.querySelector('button').disabled=true;setTimeout(()=>document.querySelector('button').disabled=false,1800);return true; })()")
        }
        let task = Task { await changer.changeEmail(account: account()) { _ in Issue.record("Unexpected checkpoint") } }
        defer { changer.cancel(); task.cancel() }
        try await waitForCodeSubmission(in: session)
        changer.cancel()
        _ = await task.value
        #expect(mailbox.requests.count == 1)
        #expect(try await session.evaluate("document.body.dataset.submissions") as? String == "1")
    }

    @Test func finalVerificationRequestsLoginCodeForReservedAddress() async throws {
        let original = BrowserSession(dataStore: .nonPersistent())
        let mailbox = ReauthenticationMailbox()
        let changer = EmailChangeAutomation(browser: ChatGPTAutomation(
            sessionManager: WebSessionManager(accountSessionFactory: { _ in original })), mailbox: mailbox)
        let candidate = account(phase: .confirming)
        #expect(changer.resetVerificationSession(for: candidate))
        let verification = try #require(changer.browserSession(for: candidate))
        try await load(passwordThenCode(email: "reserved@icloud.com"), path: "/log-in/password", in: verification)
        mailbox.onCode = { throw MailVerificationError.ambiguousMessage }
        let outcome = await changer.changeEmail(account: candidate) { _ in Issue.record("Unexpected checkpoint") }
        guard case .manual(let message) = outcome else { Issue.record("Ambiguous mailbox should pause verification"); return }
        #expect(message.contains("несколько подходящих кодов"))
        #expect(mailbox.baselineCalls == 1 && mailbox.requests.count == 1)
        #expect(mailbox.requests.first?.alias == "reserved@icloud.com")
        #expect(mailbox.requests.first?.purpose == .login)
        #expect(try await verification.evaluate("document.querySelector('input').value") as? String == "")
    }
}
