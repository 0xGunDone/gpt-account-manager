import AppKit
import Foundation
import Testing
@testable import GPTAccountManager

@MainActor
private final class EmailLoginFixtureMailbox: EmailCodeReceiving {
    var baselineCalls = 0
    var onBaseline: (() async throws -> Void)?
    func captureBaseline() async throws -> Set<String> {
        baselineCalls += 1
        try await onBaseline?()
        return []
    }
    func waitForCode(alias: String, since: Date, excluding: Set<String>) async throws -> MailVerificationCode {
        throw CancellationError()
    }
    func cancel() {}
}

@MainActor
@Suite(.serialized)
struct EmailLoginFormTests {
    private func fixture(_ html: String, url: String = "https://auth.openai.com/log-in") async throws -> BrowserSession {
        _ = NSApplication.shared
        let session = BrowserSession(dataStore: .nonPersistent())
        session.webView.frame = NSRect(x: 0, y: 0, width: 900, height: 700)
        session.webView.navigationDelegate = nil
        session.webView.loadHTMLString(html, baseURL: URL(string: url))
        for _ in 0..<60 where session.webView.isLoading {
            try await Task.sleep(for: .milliseconds(50))
        }
        return session
    }

    private func form(label: String = "Continue", delay: Int = 100) -> String {
        """
        <form onsubmit="event.preventDefault();document.body.dataset.count=String(Number(document.body.dataset.count || 0)+1)">
        <label>Email<input type="email" oninput="setTimeout(()=>document.querySelector('button').disabled=false,\(delay))"
            onchange="document.body.dataset.changed='yes'"></label>
        <button type="submit" disabled>\(label)</button></form>
        """
    }

    private func pendingAccount() -> AccountRecord {
        var account = AccountRecord(credential: .init(email: "old@example.com", password: "fixture-password", totpSecret: "JBSWY3DPEHPK3PXP"))
        account.pendingEmailChange = .init(aliasID: UUID(), originalEmail: account.email, newEmail: "new@example.com", phase: .requested,
                                           requestedAt: Date(), originalUserID: "fixture-user")
        return account
    }

    private func automation(session: BrowserSession) -> EmailChangeAutomation {
        EmailChangeAutomation(browser: ChatGPTAutomation(sessionManager: WebSessionManager(accountSessionFactory: { _ in session })),
                              mailbox: EmailLoginFixtureMailbox())
    }

    @Test func disabledContinueReceivesNativeInputEventsBeforeSubmission() async throws {
        for label in ["Continue", "Продолжить"] {
            let session = try await fixture(form(label: label))
            #expect(try await EmailChangeAutomation.submitLoginEmail("new+fixture@example.com", in: session))
            #expect(try await session.evaluate("document.querySelector('input').value") as? String == "new+fixture@example.com")
            #expect(try await session.evaluate("document.body.dataset.changed") as? String == "yes")
            #expect(try await session.evaluate("document.body.dataset.count") as? String == "1")
        }
    }

    @Test func freshChatGPTHomepageLoginDialogSubmitsNewEmail() async throws {
        let session = try await fixture("""
        <div role="dialog"><h2>Войти или зарегистрироваться</h2>
        <a href="/auth/login_with?connection=google">Продолжить с Google</a>
        <button>Продолжить с номером телефона</button>
        <label>Адрес электронной почты<input type="email" oninput="setTimeout(()=>document.querySelector('#continue').disabled=false,50)"></label>
        <button id="continue" disabled onclick="document.body.dataset.submitted=document.querySelector('input').value">Продолжить</button>
        </div>
        """, url: "https://chatgpt.com/")
        #expect(try await EmailChangeAutomation.submitLoginEmail("new@icloud.com", in: session))
        #expect(try await session.evaluate("document.body.dataset.submitted") as? String == "new@icloud.com")
    }

    @Test func currentOpenAILoginRouteSubmitsVerificationEmail() async throws {
        let session = try await fixture(form(label: "Продолжить"), url: "https://auth.openai.com/log-in-or-create-account")
        #expect(try await EmailChangeAutomation.submitLoginEmail("new@icloud.com", in: session))
        #expect(try await session.evaluate("document.querySelector('input').value") as? String == "new@icloud.com")
        #expect(try await session.evaluate("document.body.dataset.count") as? String == "1")
    }

    @Test func homepageEmailInputOutsideLoginDialogNeverReceivesCredentials() async throws {
        let session = try await fixture("<form><input type='email'><button>Continue</button></form>", url: "https://chatgpt.com/")
        #expect(try await !EmailChangeAutomation.submitLoginEmail("new@icloud.com", in: session))
        #expect(try await session.evaluate("document.querySelector('input').value") as? String == "")
    }

    @Test func stoppingWhileContinueIsDisabledPreventsLaterSubmission() async throws {
        let session = try await fixture(form(delay: 400))
        let task = Task { try await EmailChangeAutomation.submitLoginEmail("new@example.com", in: session) }
        var filled = false
        for _ in 0..<30 {
            if try await session.evaluate("document.querySelector('input').value.length > 0") as? Bool == true { filled = true; break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(filled)
        session.cancelLoading()
        do {
            _ = try await task.value
            Issue.record("Stopped login email submission did not cancel")
        } catch is CancellationError {}
        try await Task.sleep(for: .milliseconds(500))
        #expect(try await session.evaluate("document.body.dataset.count === undefined") as? Bool == true)
    }

    @Test func otherRoutesAndAmbiguousFormsNeverReceiveLoginEmail() async throws {
        for url in ["https://auth.openai.com/log-in/password", "https://auth.openai.com/email-verification", "https://chatgpt.com/settings/account"] {
            let session = try await fixture(form(), url: url)
            #expect(try await !EmailChangeAutomation.submitLoginEmail("new@example.com", in: session))
            #expect(try await session.evaluate("document.querySelector('input').value") as? String == "")
        }
        for html in [form() + form(), "<form><input type='email'><button>Continue</button><button>Продолжить</button></form>"] {
            let session = try await fixture(html)
            #expect(try await !EmailChangeAutomation.submitLoginEmail("new@example.com", in: session))
            #expect(try await session.evaluate("[...document.querySelectorAll('input')].every(e=>e.value==='')") as? Bool == true)
        }
    }

    @Test func routeChangeWhileContinueEnablesDoesNotSubmit() async throws {
        let session = try await fixture("""
        <form onsubmit="event.preventDefault();document.body.dataset.saved='yes'">
        <input type="email" oninput="history.replaceState(null,'','/email-verification');document.querySelector('button').disabled=false">
        <button disabled>Continue</button></form>
        """)
        #expect(try await !EmailChangeAutomation.submitLoginEmail("new@example.com", in: session))
        #expect(try await session.evaluate("document.body.dataset.saved === undefined") as? Bool == true)
    }

    @Test func requestedEmailFormWaitsForTransitionWithoutResending() async throws {
        let session = try await fixture("""
        <div role="dialog"><h2>Edit email address</h2>
        <form onsubmit="event.preventDefault();document.body.dataset.saved='yes'">
        <input type="email"><button>Send verification email</button></form></div>
        """, url: "https://chatgpt.com/settings/account")
        let changer = automation(session: session)
        var finished = false
        let task = Task {
            let outcome = await changer.changeEmail(account: pendingAccount(), onCheckpoint: { _ in })
            finished = true
            return outcome
        }
        try await Task.sleep(for: .milliseconds(1600))
        #expect(!finished)
        #expect(try await session.evaluate("document.querySelector('input').value") as? String == "")
        #expect(try await session.evaluate("document.body.dataset.saved === undefined") as? Bool == true)
        changer.cancel()
        _ = await task.value
    }

    @Test func requestedEmailChangeStopsOnObservedOAuthCallbackErrorWithoutSubmittingOrReadingMail() async throws {
        let session = try await fixture("""
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline'; form-action 'none'">
        <h2>Войти или зарегистрироваться</h2><p>Не удалось войти. Повторите попытку.</p>
        <form onsubmit="event.preventDefault();window.submissions++">
          <label>Email<input type="email"></label><button>Продолжить</button>
        </form><script>window.submissions=0;window.fetch=async()=>({ok:true,json:async()=>({})});</script>
        """, url: "https://chatgpt.com/auth/login?callbackUrl=%2Fsettings%2Faccount&error=OAuthCallback")
        let mailbox = EmailLoginFixtureMailbox()
        let changer = EmailChangeAutomation(browser: ChatGPTAutomation(
            sessionManager: WebSessionManager(accountSessionFactory: { _ in session })), mailbox: mailbox)
        var timedOut = false
        let timeout = Task {
            do { try await Task.sleep(for: .seconds(4)) } catch { return }
            timedOut = true
            changer.cancel()
        }
        defer { timeout.cancel(); changer.cancel() }
        let outcome = await changer.changeEmail(account: pendingAccount()) { _ in Issue.record("Callback error must not advance email checkpoint") }
        guard case .manual(let message) = outcome else { Issue.record("Callback error must pause email change"); return }
        #expect(!timedOut)
        #expect(message.contains("OpenAI") && message.contains("подтверждение личности"))
        #expect(mailbox.baselineCalls == 0)
        #expect(try await session.evaluate("window.submissions === 0 && document.querySelector('input').value === ''") as? Bool == true)
    }

    @Test func passwordFieldCanArriveLateAndSubmittedChallengeIsNotRepeated() async throws {
        let session = try await fixture("""
        <div id="pending">Loading password form…</div>
        <script>setTimeout(() => {
          document.querySelector('#pending').innerHTML = '<form onsubmit="event.preventDefault();document.body.dataset.count=String(Number(document.body.dataset.count || 0)+1)"><input type="password"><button>Continue</button></form>';
        }, 600);</script>
        """, url: "https://auth.openai.com/log-in/password")
        let changer = automation(session: session)
        var finished = false
        let task = Task {
            let outcome = await changer.changeEmail(account: pendingAccount(), onCheckpoint: { _ in })
            finished = true
            return outcome
        }
        try await Task.sleep(for: .milliseconds(2200))
        #expect(!finished)
        #expect(try await session.evaluate("document.body.dataset.count") as? String == "1")
        changer.cancel()
        _ = await task.value
    }

    @Test func visiblePasswordRejectionStopsInsteadOfSubmittingAgain() async throws {
        let session = try await fixture("""
        <div>Incorrect password</div><form onsubmit="event.preventDefault();document.body.dataset.saved='yes'">
        <input type="password"><button>Continue</button></form>
        """, url: "https://auth.openai.com/log-in/password")
        let changer = automation(session: session)
        let outcome = await changer.changeEmail(account: pendingAccount(), onCheckpoint: { _ in })
        guard case .manual(let message) = outcome else { Issue.record("Rejected password did not request manual handling"); return }
        #expect(message.contains("отклонил пароль"))
        #expect(try await session.evaluate("document.querySelector('input').value") as? String == "")
        #expect(try await session.evaluate("document.body.dataset.saved === undefined") as? Bool == true)
    }

    @Test func reservedOpeningReauthenticatesBeforeRequestCheckpoint() async throws {
        let session = try await fixture("""
        <button aria-label="Change email address: old@example.com" onclick="document.body.dataset.opened='yes'">Edit</button>
        <script>window.fetch = async () => ({ok:true,json:async()=>({user:{email:'old@example.com',id:'fixture-user'}})});</script>
        """, url: "https://chatgpt.com/settings/account")
        var account = pendingAccount()
        account.pendingEmailChange?.phase = .reserved
        account.pendingEmailChange?.originalUserID = nil
        account.pendingEmailChange?.requestedAt = nil
        let mailbox = EmailLoginFixtureMailbox()
        let changer = EmailChangeAutomation(browser: ChatGPTAutomation(sessionManager: WebSessionManager(accountSessionFactory: { _ in session })), mailbox: mailbox)
        var checkpoints: [EmailChangePhase] = []
        mailbox.onBaseline = {
            if mailbox.baselineCalls == 2 {
                let state = try await EmailChangeForm.inspect(in: session)
                #expect(state.kind == .emailEntry)
                #expect(checkpoints == [.reserved])
            }
        }
        let task = Task {
            await changer.changeEmail(account: account) { change in
                checkpoints.append(change.phase)
                if change.phase == .requested { throw CancellationError() }
            }
        }
        defer { changer.cancel(); task.cancel() }
        try await waitFor("document.body.dataset.opened === 'yes'", in: session)
        #expect(checkpoints == [.reserved])
        #expect(mailbox.baselineCalls == 1)
        try await load("""
        <h1>First, verify it's you</h1><form onsubmit="event.preventDefault();document.body.dataset.password=document.querySelector('input').value">
        <input type="password"><button>Continue</button></form>
        """, url: "https://auth.openai.com/log-in/password", in: session)
        try await waitFor("document.body.dataset.password === 'fixture-password'", in: session)
        #expect(checkpoints == [.reserved])
        #expect(mailbox.baselineCalls == 1)
        try await load("""
        <h1>Проверьте приложение для аутентификации</h1>
        <form onsubmit="event.preventDefault();document.body.dataset.otp=document.querySelector('input').value">
        <label>One-time code<input name="code" autocomplete="one-time-code" inputmode="numeric"></label><button>Continue</button></form>
        """, url: "https://auth.openai.com/mfa-challenge/fixture", in: session)
        try await waitFor("/^[0-9]{6}$/.test(document.body.dataset.otp || '')", in: session)
        #expect(checkpoints == [.reserved])
        #expect(mailbox.baselineCalls == 1)
        try await load(Self.emailEntryHTML, url: "https://chatgpt.com/settings/account", in: session)
        _ = await task.value
        #expect(checkpoints == [.reserved, .requested])
        #expect(mailbox.baselineCalls == 2)
        #expect(try await session.evaluate("document.querySelector('input').value") as? String == "")
    }

    @Test func reservedResumePreservesAlreadyOpenEmailEntry() async throws {
        let session = try await fixture(Self.emailEntryHTML, url: "https://chatgpt.com/settings/account")
        var account = pendingAccount()
        account.pendingEmailChange?.phase = .reserved
        account.pendingEmailChange?.requestedAt = nil
        let changer = automation(session: session)
        var reachedRequest = false
        _ = await changer.changeEmail(account: account) { change in
            if change.phase == .requested { reachedRequest = true; throw CancellationError() }
        }
        #expect(reachedRequest)
        #expect(try await EmailChangeForm.inspect(in: session).kind == .emailEntry)
        #expect(try await session.evaluate("document.querySelector('input').value") as? String == "")
    }

    private static let emailEntryHTML = """
    <div role="dialog"><h2>Edit email address</h2><form><input type="email"><button>Send verification email</button></form></div>
    <script>window.fetch = async () => ({ok:true,json:async()=>({user:{email:'old@example.com',id:'fixture-user'}})});</script>
    """

    private func load(_ html: String, url: String, in session: BrowserSession) async throws {
        session.webView.loadHTMLString(html, baseURL: URL(string: url))
        for _ in 0..<60 where session.webView.isLoading { try await Task.sleep(for: .milliseconds(25)) }
    }

    private func waitFor(_ condition: String, in session: BrowserSession) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(12))
        while ContinuousClock.now < deadline {
            if try await session.evaluate(condition) as? Bool == true { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw FixtureError.timedOut
    }

    private enum FixtureError: Error { case timedOut }
}
