import AppKit
import Foundation
import Testing
import WebKit
@testable import GPTAccountManager

@MainActor
private final class RegistrationMFAEmailResumeWebView: WKWebView {
    var fixtureHTML = ""
    var loadedURLs: [URL] = []

    override func load(_ request: URLRequest) -> WKNavigation? {
        if let url = request.url { loadedURLs.append(url) }
        return super.loadHTMLString(fixtureHTML, baseURL: request.url)
    }
}

@MainActor
@Suite(.serialized)
struct RegistrationMFAEmailReauthenticationTests {
    private let email = "fixture@example.com"
    private let secret = "JBSWY3DPEHPK3PXP"

    private var emailForm: String {
        """
        <main><h1>Во-первых, подтвердите, что это вы</h1><p>Код отправлен на \(email)</p>
        <form onsubmit="event.preventDefault();document.body.dataset.submits=String(Number(document.body.dataset.submits||0)+1)">
          <input name="code" autocomplete="one-time-code"><button>Продолжить</button>
          <button type="button" onclick="document.body.dataset.resent='yes'">Отправить код ещё раз</button>
        </form></main>
        """
    }

    private func load(_ html: String, url: String, in session: BrowserSession) async throws {
        session.webView.loadHTMLString(html, baseURL: URL(string: url))
        for _ in 0..<100 where session.webView.isLoading {
            try await Task.sleep(for: .milliseconds(30))
        }
        try #require(!session.webView.isLoading)
    }

    private func fixture(_ html: String? = nil, url: String = "https://auth.openai.com/email-verification") async throws -> BrowserSession {
        _ = NSApplication.shared
        let session = BrowserSession(dataStore: .nonPersistent())
        session.webView.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        session.webView.navigationDelegate = nil
        try await load(html ?? emailForm, url: url, in: session)
        return session
    }

    @Test(arguments: [false, true])
    func mailboxReauthenticationResumesSecurityInspectionWithoutCertifyingMissingKey(hasPendingSecret: Bool) async throws {
        let session = try await fixture()
        defer { session.cancelLoading() }
        let browser = ChatGPTAutomation(sessionManager: WebSessionManager())
        var calls = 0
        let result = await browser.enrollNewAuthenticator(in: session,
            pendingSecret: hasPendingSecret ? secret : nil, automaticallyWaitForTransitions: true,
            transitionTimeoutSeconds: 3, humanChallengeTimeoutSeconds: 1,
            reauthenticationHandler: { page in
                calls += 1
                #expect(try await page.evaluate("document.querySelector('input').value") as? String == "")
                #expect(try await RegistrationForm.submitEmailCode("123456", expectedEmail: email, in: page))
                #expect(try await page.evaluate("document.querySelector('input').value") as? String == "123456")
                try await load("<button role='switch' aria-label='Authenticator app' aria-checked='true'>Authenticator app</button>",
                               url: "https://chatgpt.com/settings/security", in: page)
                return true
            }) { _ in
                Issue.record("Reauthentication must not replace or invent a pending authenticator key")
            }
        #expect(calls == 1)
        if hasPendingSecret {
            #expect(result == .enabled(secret: secret))
        } else {
            guard case .manual = result else {
                Issue.record("Email confirmation and an enabled switch cannot certify an unsaved key")
                return
            }
        }
    }

    @Test func submittedEmailFormIsHandledOnceAndDoesNotEnableMFA() async throws {
        let session = try await fixture()
        defer { session.cancelLoading() }
        let browser = ChatGPTAutomation(sessionManager: WebSessionManager())
        var calls = 0
        let result = await browser.enrollNewAuthenticator(in: session, pendingSecret: secret,
            automaticallyWaitForTransitions: true, transitionTimeoutSeconds: 2, humanChallengeTimeoutSeconds: 1,
            reauthenticationHandler: { page in
                calls += 1
                let pageURL = try #require(page.webView.url)
                #expect(try await RegistrationForm.emailCodeScreenMatches(in: page, expectedEmail: email,
                    pageURL: pageURL, token: "fixture-mailbox-wait", capture: true))
                return try await RegistrationForm.submitEmailCode("123456", expectedEmail: email, in: page)
            }) { _ in Issue.record("Existing pending key must remain unchanged") }
        guard case .manual = result else {
            Issue.record("Submitting email code is not proof that MFA enabled")
            return
        }
        #expect(calls == 1)
        #expect(try await session.evaluate("document.body.dataset.submits") as? String == "1")
        #expect(try await session.evaluate("document.body.dataset.resent === undefined") as? Bool == true)
    }

    @Test(arguments: [false, true])
    func mailboxCancellationAfterSecurityTransitionReturnsForReinspection(screenChanged: Bool) async throws {
        let session = try await fixture()
        defer { session.cancelLoading() }
        let store = AccountStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathComponent("accounts.json"))
        let coordinator = RegistrationCoordinator(
            store: store, browser: ChatGPTAutomation(sessionManager: WebSessionManager()),
            mailbox: MailRuMailbox(expectedMailbox: "fixture@mail.ru"))
        var reads = 0

        do {
            let code = try await coordinator.waitForEmailCode(in: session, expectedEmail: email) {
                reads += 1
                if screenChanged {
                    try await load("""
                    <section role="dialog"><h2>Настройка приложения для аутентификации</h2>
                      <p>Вам понадобится приложение для аутентификации или менеджер паролей, который генерирует коды подтверждения.
                      Используйте приложение, которое у вас уже есть, или скачайте одно из следующих:</p>
                      <button type="button" onclick="document.body.dataset.continued='yes'">Продолжить</button>
                    </section>
                    <script>window.fetch=async()=>({ok:false});</script>
                    """, url: "https://chatgpt.com/settings/security", in: session)
                }
                throw MailVerificationError.cancelled
            }
            #expect(screenChanged)
            #expect(code == nil)
        } catch MailVerificationError.cancelled {
            #expect(!screenChanged)
        }

        #expect(reads == 1)
        if screenChanged {
            #expect(try await session.evaluate("document.body.dataset.continued === undefined && document.querySelector('input') === null") as? Bool == true)
        } else {
            #expect(try await session.evaluate("document.querySelector('input').value === '' && document.body.dataset.submits === undefined && document.body.dataset.resent === undefined") as? Bool == true)
        }
    }

    @Test func replacedEmailFormAtSameURLIsHandledAgainAfterFirstCallbackReturns() async throws {
        let session = try await fixture()
        defer { session.cancelLoading() }
        let browser = ChatGPTAutomation(sessionManager: WebSessionManager())
        var calls = 0
        let result = await browser.enrollNewAuthenticator(in: session, pendingSecret: secret,
            automaticallyWaitForTransitions: true, transitionTimeoutSeconds: 3, humanChallengeTimeoutSeconds: 1,
            reauthenticationHandler: { page in
                calls += 1
                if calls == 1 {
                    let pageURL = try #require(page.webView.url)
                    #expect(try await RegistrationForm.emailCodeScreenMatches(in: page, expectedEmail: email,
                        pageURL: pageURL, token: "fixture-mailbox-wait", capture: true))
                    let encodedForm = String(decoding: try JSONEncoder().encode(emailForm), as: UTF8.self)
                    _ = try await page.evaluate("(() => { document.body.innerHTML=\(encodedForm); return true; })()")
                    #expect(page.webView.url == pageURL)
                    #expect(try await RegistrationForm.inspect(in: page).displayedEmail == email)
                    return true
                }
                #expect(calls == 2)
                try await load("<button role='switch' aria-label='Authenticator app' aria-checked='true'>Authenticator app</button>",
                               url: "https://chatgpt.com/settings/security", in: page)
                return true
            }) { _ in Issue.record("A replacement email form must preserve pending key") }
        #expect(calls == 2)
        #expect(result == .enabled(secret: secret))
    }

    @Test func unavailableMailboxCodeLeavesEmailFormUntouched() async throws {
        let session = try await fixture()
        defer { session.cancelLoading() }
        let browser = ChatGPTAutomation(sessionManager: WebSessionManager())
        var calls = 0
        let result = await browser.enrollNewAuthenticator(in: session, pendingSecret: secret,
            automaticallyWaitForTransitions: true, transitionTimeoutSeconds: 1, humanChallengeTimeoutSeconds: 1,
            reauthenticationHandler: { _ in calls += 1; return false }) { _ in
                Issue.record("Mailbox wait must preserve pending key")
            }
        guard case .manual = result else {
            Issue.record("Unavailable email code must leave enrollment unconfirmed")
            return
        }
        #expect(calls > 0)
        #expect(try await session.evaluate("document.querySelector('input').value") as? String == "")
        #expect(try await session.evaluate("document.body.dataset.submits === undefined && document.body.dataset.resent === undefined") as? Bool == true)
    }

    @Test(arguments: ["captcha", "unknownRoute", "untrustedOrigin"])
    func mailboxHandlerRequiresRecognizedTrustedEmailScreen(screen: String) async throws {
        let html = emailForm + (screen == "captcha" ? "<h2>Verify you are human</h2>" : "")
        let url = screen == "unknownRoute" ? "https://auth.openai.com/unknown-step"
            : screen == "untrustedOrigin" ? "https://other.example/email-verification"
            : "https://auth.openai.com/email-verification"
        let session = try await fixture(html, url: url)
        defer { session.cancelLoading() }
        let browser = ChatGPTAutomation(sessionManager: WebSessionManager())
        var calls = 0
        let result = await browser.enrollNewAuthenticator(in: session, pendingSecret: secret,
            automaticallyWaitForTransitions: true, transitionTimeoutSeconds: 1, humanChallengeTimeoutSeconds: 1,
            reauthenticationHandler: { _ in calls += 1; return true }) { _ in
                Issue.record("Unsupported screen must preserve pending key")
            }
        guard case .manual = result else {
            Issue.record("Unsupported screen cannot complete enrollment")
            return
        }
        #expect(calls == 0)
        if screen != "untrustedOrigin" {
            #expect(try await session.evaluate("document.querySelector('input').value") as? String == "")
        }
    }

    @Test func cancellationDuringMailboxReauthenticationStopsEnrollment() async throws {
        let session = try await fixture()
        defer { session.cancelLoading() }
        let browser = ChatGPTAutomation(sessionManager: WebSessionManager())
        var calls = 0
        let result = await browser.enrollNewAuthenticator(in: session, pendingSecret: secret,
            automaticallyWaitForTransitions: true, transitionTimeoutSeconds: 2, humanChallengeTimeoutSeconds: 1,
            reauthenticationHandler: { page in
                calls += 1
                page.cancelLoading()
                return false
            }) { _ in Issue.record("Cancellation must preserve pending key") }
        guard case .failure = result else {
            Issue.record("Cancelling browser during email wait must stop enrollment")
            return
        }
        #expect(calls == 1)
        #expect(try await session.evaluate("document.body.dataset.submits === undefined") as? Bool == true)
    }

    @Test func cancellationWhilePreparingMailboxDoesNotStartAuthenticatorSetup() async throws {
        let session = try await fixture("""
        <button role='switch' aria-label='Authenticator app' aria-checked='false'
          onclick="document.body.dataset.started='yes'">Authenticator app</button>
        """, url: "https://chatgpt.com/settings/security")
        defer { session.cancelLoading() }
        let browser = ChatGPTAutomation(sessionManager: WebSessionManager())
        var calls = 0
        let result = await browser.enrollNewAuthenticator(in: session, pendingSecret: nil,
            automaticallyWaitForTransitions: true, transitionTimeoutSeconds: 2, humanChallengeTimeoutSeconds: 1,
            beforeSetup: { page in
                calls += 1
                page.cancelLoading()
                return true
            }) { _ in Issue.record("Cancelled preparation must not capture a key") }
        guard case .failure = result else {
            Issue.record("Cancelled mailbox preparation must stop enrollment")
            return
        }
        #expect(calls == 1)
        #expect(try await session.evaluate("document.body.dataset.started === undefined") as? Bool == true)
    }

    @Test func savedMFAEmailChallengeResumesAtMailFormWithoutRequestingAnotherCode() async throws {
        _ = NSApplication.shared
        let store = AccountStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathComponent("accounts.json"))
        let session = BrowserSession(dataStore: .nonPersistent()) { configuration in
            RegistrationMFAEmailResumeWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600),
                                            configuration: configuration)
        }
        let web = try #require(session.webView as? RegistrationMFAEmailResumeWebView)
        web.fixtureHTML = emailForm + """
        <button role='switch' aria-label='Authenticator app' aria-checked='false'
          onclick="document.body.dataset.factorStarted='yes'">Authenticator app</button>
        """
        let draft = try store.beginRegistration(email: email, fullName: "Fixture Person", age: 29, password: "fixture-password")
        var pending = try #require(draft.pendingRegistration)
        pending.phase = .enablingTwoFA
        pending.passwordWasSubmitted = true
        pending.mfaEmailVerificationPending = true
        pending.requestedAt = Date(timeIntervalSince1970: 1_700_000_000)
        pending.baselineMessageIDs = ["original-request-baseline"]
        try store.checkpointRegistration(id: draft.id, registration: pending)
        let browser = ChatGPTAutomation(sessionManager: WebSessionManager(accountSessionFactory: { _ in session }))
        let coordinator = RegistrationCoordinator(store: store, browser: browser, mailbox: MailRuMailbox(expectedMailbox: ""))
        defer {
            coordinator.stop()
            session.cancelLoading()
            try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent())
        }
        coordinator.resume(id: draft.id)
        for _ in 0..<200 where coordinator.isRunning { try await Task.sleep(for: .milliseconds(30)) }
        try #require(!coordinator.isRunning)
        #expect(web.loadedURLs == [URL(string: "https://auth.openai.com/email-verification")!])
        let saved = try #require(store.accounts.first)
        #expect(saved.pendingRegistration == pending)
        #expect(saved.pendingRegistration?.pendingSecret == nil)
        #expect(saved.status != .ready && saved.totpSecret.isEmpty && store.groups.isEmpty)
        #expect(try await session.evaluate("document.querySelector('input').value") as? String == "")
        #expect(try await session.evaluate("document.body.dataset.submits === undefined && document.body.dataset.resent === undefined && document.body.dataset.factorStarted === undefined") as? Bool == true)
    }

    @Test func pendingMFAEmailCheckpointRoundTripsAndLegacyDraftDefaultsToNil() throws {
        let legacyData = Data(#"{"fullName":"Fixture Person","age":29,"passwordWasSubmitted":true,"phase":"enablingTwoFA","baselineMessageIDs":["original-request-baseline"],"termsAccepted":true}"#.utf8)
        var pending = try JSONDecoder().decode(PendingRegistration.self, from: legacyData)
        #expect(pending.mfaEmailVerificationPending == nil)
        pending.mfaEmailVerificationPending = true
        pending.requestedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let restored = try JSONDecoder().decode(PendingRegistration.self, from: JSONEncoder().encode(pending))
        #expect(restored == pending)
        #expect(restored.mfaEmailVerificationPending == true)
    }
}
