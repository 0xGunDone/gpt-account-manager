import AppKit
import Foundation
import Testing
@testable import GPTAccountManager

@MainActor
final class ExternalLoginMailboxFixture: EmailCodeReceiving {
    var captures = 0
    var reads = 0
    var beforeCapture: (() async throws -> Void)?
    var beforeRead: (() async throws -> Void)?

    func captureBaseline() async throws -> Set<String> {
        captures += 1
        try await beforeCapture?()
        return ["external-mailbox:none"]
    }

    func waitForCode(alias: String, since: Date, excluding: Set<String>) async throws -> MailVerificationCode {
        try await waitForCode(alias: alias, since: since, excluding: excluding, purpose: .login)
    }

    func waitForCode(alias: String, since: Date, excluding: Set<String>, purpose: MailVerificationPurpose) async throws -> MailVerificationCode {
        reads += 1
        #expect(alias == "owner@example.com")
        #expect(purpose == .login)
        #expect(excluding == ["external-mailbox:none"])
        #expect(abs(Date().timeIntervalSince(since)) < 30)
        try await beforeRead?()
        return MailVerificationCode(messageID: "fixture-fresh", code: "123456")
    }

    func cancel() {}
}

@MainActor
@Suite(.serialized)
struct ExternalLoginMailTests {
    private func account() throws -> AccountRecord {
        var account = AccountRecord(credential: .init(email: "owner@example.com", password: "fixture-password", totpSecret: ""))
        account.externalMailbox = try ExternalMailboxConfiguration(address: "inbox@example.com", codeURL: "https://inbox.example.com/code")
        return account
    }

    private func session(at path: String, choosePassword: Bool, repeatEmailChallenge: Bool) async throws -> BrowserSession {
        _ = NSApplication.shared
        let session = BrowserSession(dataStore: .nonPersistent())
        session.webView.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        session.webView.navigationDelegate = nil
        let code = """
        <main><p>Code sent to owner@example.com</p><form onsubmit="event.preventDefault(); window.codes.push(this.code.value)">
          <input name="code" autocomplete="one-time-code"><button>Continue</button>
          <button type="button" onclick="window.resends++">Resend email</button></form></main>
        """
        let passwordChoice = "<a href='/log-in/password' onclick=\"event.preventDefault(); showPassword()\">Continue with password</a>"
        let password = """
        <main><p>owner@example.com</p><form onsubmit="event.preventDefault(); window.passwords.push(this.password.value); showCode()">
          <input type="password" name="password"><button>Continue</button></form></main>
        """
        let initialChoice = choosePassword ? passwordChoice : ""
        let emailChallenge = repeatEmailChallenge ? code + passwordChoice : code
        func encoded(_ value: String) throws -> String { String(decoding: try JSONEncoder().encode(value), as: UTF8.self) }
        session.webView.loadHTMLString("""
        <form onsubmit="event.preventDefault(); window.emails.push(this.username.value); showEmailChallenge()">
          <input type="email" name="username"><button>Continue</button></form>
        \(initialChoice)
        <script>
          window.codes=[]; window.emails=[]; window.passwords=[]; window.resends=0;
          function render(path, html) { history.replaceState({}, '', path); document.body.innerHTML=html; }
          function showEmailChallenge() { render('/email-verification', \(try encoded(emailChallenge))); }
          function showCode() { render('/email-verification', \(try encoded(code))); }
          function showPassword() { render('/log-in/password', \(try encoded(password))); }
        </script>
        """, baseURL: URL(string: "https://auth.openai.com\(path)"))
        for _ in 0..<100 where session.webView.isLoading { try await Task.sleep(for: .milliseconds(25)) }
        try #require(!session.webView.isLoading)
        return session
    }

    @Test(arguments: [false, true])
    func configuredAccountUsesFreshCodeAndPrefersPasswordWhenOffered(choosePassword: Bool) async throws {
        let session = try await session(at: "/log-in-or-create-account", choosePassword: choosePassword, repeatEmailChallenge: false)
        let mailbox = ExternalLoginMailboxFixture()
        mailbox.beforeCapture = { () async throws in
            let count = try await session.evaluate("window.emails.length + window.passwords.length") as? Int
            #expect(count == 0)
        }
        mailbox.beforeRead = { () async throws in
            let count = try await session.evaluate("window.emails.length + window.passwords.length") as? Int
            #expect(count == 1)
        }
        let browser = ChatGPTAutomation(sessionManager: WebSessionManager(), makeExternalMailbox: { _ in mailbox })
        let result = await browser.signIn(account: try account(), secret: "", in: session, loginTimeoutSeconds: 3)

        guard case .manual(_, let proof) = result else { Issue.record("Fixture stays on code form"); return }
        #expect(proof.passwordSubmitted == choosePassword)
        #expect(mailbox.captures == 1 && mailbox.reads == 1)
        #expect(try await session.evaluate("window.codes.join(',')") as? String == "123456")
        #expect(try await session.evaluate("window.resends") as? Int == 0)
        _ = await browser.signIn(account: try account(), secret: "", in: session, loginTimeoutSeconds: 2)
        #expect(mailbox.reads == 1)
        #expect(try await session.evaluate("window.codes.join(',')") as? String == "123456")
    }

    @Test func replacementWithSameURLDiscardsFetchedCode() async throws {
        let session = try await session(at: "/log-in", choosePassword: false, repeatEmailChallenge: false)
        let mailbox = ExternalLoginMailboxFixture()
        mailbox.beforeRead = {
            _ = try await session.evaluate("(() => { const form=document.querySelector('form'); form.replaceWith(form.cloneNode(true)); })()")
        }
        let browser = ChatGPTAutomation(sessionManager: WebSessionManager(), makeExternalMailbox: { _ in mailbox })
        _ = await browser.signIn(account: try account(), secret: "", in: session, loginTimeoutSeconds: 3)
        #expect(mailbox.captures == 1 && mailbox.reads == 1)
        #expect(try await session.evaluate("window.codes.length") as? Int == 0)
        #expect(try await session.evaluate("document.querySelector('input').value") as? String == "")
    }

    @Test func pendingCodeFromBypassedChallengeCannotBeUsedAfterPassword() async throws {
        let session = try await session(at: "/log-in", choosePassword: false, repeatEmailChallenge: true)
        let mailbox = ExternalLoginMailboxFixture()
        let browser = ChatGPTAutomation(sessionManager: WebSessionManager(), makeExternalMailbox: { _ in mailbox })
        let result = await browser.signIn(account: try account(), secret: "", in: session, loginTimeoutSeconds: 3)
        guard case .manual(let message, let proof) = result else { Issue.record("Overlapping requests need manual code"); return }
        #expect(message == ExternalLoginMailError.baselineUnavailable.errorDescription)
        #expect(proof.passwordSubmitted)
        #expect(mailbox.captures == 2 && mailbox.reads == 0)
        #expect(try await session.evaluate("window.codes.length") as? Int == 0)
        #expect(try await session.evaluate("window.resends") as? Int == 0)
    }
}
