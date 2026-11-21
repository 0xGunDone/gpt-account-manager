import AppKit
import Foundation
import Testing
import WebKit
@testable import GPTAccountManager

@MainActor
private final class CodexAuthorizationFixtureWebView: WKWebView {
    override func load(_ request: URLRequest) -> WKNavigation? {
        super.loadHTMLString("<p>Authorization fixture</p><script>window.fetch=async()=>({ok:true,status:200,json:async()=>({})});</script>", baseURL: request.url)
    }
}

@MainActor
@Suite(.serialized)
struct CodexAccAuthorizationTests {
    private let account = AccountRecord(credential: .init(
        email: "owner@example.com", password: "fixture-password", totpSecret: "JBSWY3DPEHPK3PXP"))

    private func authorizationURL(changing key: String? = nil, to value: String? = nil) -> URL {
        var url = URLComponents(string: "https://auth.openai.com/oauth/authorize")!
        url.queryItems = [
            .init(name: "client_id", value: "app_EMoamEEZ73f0CkXaXp7hrann"),
            .init(name: "redirect_uri", value: "http://localhost:1455/auth/callback"),
            .init(name: "response_type", value: "code"),
            .init(name: "scope", value: "openid profile email offline_access"),
            .init(name: "state", value: "fixture-state"),
            .init(name: "code_challenge", value: String(repeating: "a", count: 43)),
            .init(name: "code_challenge_method", value: "S256"),
        ].map { item in item.name == key ? .init(name: item.name, value: value) : item }
        return url.url!
    }

    private func session() -> BrowserSession {
        _ = NSApplication.shared
        return BrowserSession(dataStore: .nonPersistent()) { configuration in
            CodexAuthorizationFixtureWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 700), configuration: configuration)
        }
    }

    private func load(_ html: String, in session: BrowserSession, path: String = "/codex/consent", host: String = "auth.openai.com") async throws {
        session.webView.navigationDelegate = nil
        session.webView.loadHTMLString(html, baseURL: URL(string: "https://\(host)\(path)"))
        for _ in 0..<100 where session.webView.isLoading { try await Task.sleep(for: .milliseconds(30)) }
        #expect(!session.webView.isLoading)
    }

    private func prepared() async throws -> (CodexAccAuthorization, BrowserSession) {
        let session = session()
        let browser = ChatGPTAutomation(sessionManager: WebSessionManager(accountSessionFactory: { _ in session }))
        let authorization = CodexAccAuthorization(browser: browser)
        #expect(try await authorization.prepare(account: account, authorizationURL: authorizationURL()) === session)
        for _ in 0..<100 where session.webView.isLoading { try await Task.sleep(for: .milliseconds(30)) }
        return (authorization, session)
    }

    private func form(_ field: String, extra: String = "") -> String {
        """
        <form onsubmit="event.preventDefault();document.body.dataset.count=String(Number(document.body.dataset.count||0)+1)">
        \(field)<button>Continue</button>\(extra)</form>
        """
    }

    private func consent(email: String = "owner@example.com", heading: String = "Sign in to Codex", extra: String = "", action: String = "") -> String {
        """
        <main><h1>\(heading)</h1><p>\(email)</p>
        <form action="\(action)" onsubmit="event.preventDefault();document.body.dataset.count=String(Number(document.body.dataset.count||0)+1)">
        <button>Continue</button>\(extra)</form></main>
        """
    }

    private func chatGPTCodexConsent(
        email: String = "owner@example.com", extra: String = "",
        radio: String = "checked disabled", buttonAttributes: String = ""
    ) -> String {
        """
        <title>Вход в Codex с помощью ChatGPT - OpenAI</title>
        <div id="consent">
          <div>Вход в Codex с помощью ChatGPT</div>
          <span>\(email)</span>
          <div>Выберите рабочую область</div>
          <label><input type="radio" name="workspace" \(radio)>Личная учетная запись</label>
          <a href="https://chatgpt.com">Отмена</a>
          <button \(buttonAttributes) onclick="document.body.dataset.count=String(Number(document.body.dataset.count||0)+1)">Продолжить</button>
          \(extra)
        </div>
        """
    }

    @Test func authorizationURLRequiresKnownClientScopesPKCEAndLoopbackCallback() {
        #expect(CodexAccAuthorization.isAllowedAuthorizationURL(authorizationURL()))
        #expect(CodexAccAuthorization.isAllowedAuthorizationURL(authorizationURL(changing: "redirect_uri", to: "http://127.0.0.1:45123/auth/callback")))
        for (key, value) in [
            ("client_id", "different-client"), ("state", ""),
            ("scope", "openid profile email offline_access payments"),
            ("scope", "openid profile email"), ("scope", "openid profile email email"),
            ("response_type", "token"), ("code_challenge", ""), ("code_challenge_method", "plain"),
            ("redirect_uri", "http://localhost.evil.example:1455/auth/callback"),
            ("redirect_uri", "https://localhost:1455/auth/callback"),
            ("redirect_uri", "http://localhost:1455/other"),
            ("redirect_uri", "http://localhost:1455/auth/callback?target=other"),
        ] {
            #expect(!CodexAccAuthorization.isAllowedAuthorizationURL(authorizationURL(changing: key, to: value)))
        }
        var changed = URLComponents(url: authorizationURL(), resolvingAgainstBaseURL: false)!
        changed.queryItems?.append(.init(name: "scope", value: "openid profile email offline_access"))
        #expect(!CodexAccAuthorization.isAllowedAuthorizationURL(changed.url!))
        changed = URLComponents(url: authorizationURL(), resolvingAgainstBaseURL: false)!
        changed.host = "auth.openai.com.evil.example"
        #expect(!CodexAccAuthorization.isAllowedAuthorizationURL(changed.url!))
    }

    @Test func prepareReusesAccountWebViewAndCookieStore() async throws {
        let session = session()
        var creations = 0
        let browser = ChatGPTAutomation(sessionManager: WebSessionManager(accountSessionFactory: { _ in
            creations += 1
            return session
        }))
        #expect(browser.accountSession(for: account) === session)
        let originalWebView = session.webView
        let originalStore = originalWebView.configuration.websiteDataStore
        let cookie = try #require(HTTPCookie(properties: [.domain: "auth.openai.com", .path: "/", .name: "fixture", .value: "retained"]))
        await originalStore.httpCookieStore.setCookie(cookie)
        let authorization = CodexAccAuthorization(browser: browser)
        #expect(try await authorization.prepare(account: account, authorizationURL: authorizationURL()) === session)
        #expect(session.webView === originalWebView)
        #expect(session.webView.configuration.websiteDataStore === originalStore)
        #expect(await originalStore.httpCookieStore.allCookies().contains { $0.name == "fixture" })
        #expect(session.isVisible && creations == 1)
        await #expect(throws: (any Error).self) {
            try await authorization.prepare(account: account, authorizationURL: authorizationURL(changing: "client_id", to: "other"))
        }
        #expect(creations == 1)
        session.cancelLoading()
    }

    @Test(arguments: ["email", "emailOrCreate", "password", "totp"])
    func ordinaryCredentialsSubmitOnlyOncePerChallenge(kind: String) async throws {
        let (authorization, session) = try await prepared()
        let isEmail = kind == "email" || kind == "emailOrCreate"
        let path = kind == "emailOrCreate" ? "/log-in-or-create-account" : kind == "email" ? "/log-in" : kind == "password" ? "/log-in/password" : "/mfa-challenge/fixture"
        let field = isEmail ? "<input type='email' aria-label='Адрес электронной почты'>" : kind == "password" ? "<input type='password'>" : "<label>Authenticator code<input name='code' inputmode='numeric'></label>"
        let html = kind == "emailOrCreate"
            ? "<h1>Вход или регистрация</h1><button>Продолжить с Google</button>" + form(field, extra: "<button type='button'>Продолжить с Apple</button>").replacingOccurrences(of: ">Continue<", with: ">Продолжить<")
            : form(field)
        try await load(html, in: session, path: path)
        #expect(try await authorization.advance(account: account, in: session) == .waiting)
        #expect(try await authorization.advance(account: account, in: session) == .waiting)
        #expect(try await session.evaluate("document.body.dataset.count") as? String == "1")
        let value = try await session.evaluate("document.querySelector('input').value") as? String
        if isEmail { #expect(value == account.email) }
        else if kind == "password" { #expect(value == account.password) }
        else { #expect(value?.count == 6 && value?.allSatisfy(\.isNumber) == true) }
    }

    @Test func untrustedOriginAndAmbiguousPasswordFormReceiveNoCredentials() async throws {
        let (authorization, session) = try await prepared()
        try await load(form("<input type='password'>"), in: session, path: "/log-in/password", host: "auth.openai.com.evil.example")
        guard case .manual = try await authorization.advance(account: account, in: session) else { Issue.record("Untrusted origin must require manual action"); return }
        #expect(try await session.webView.evaluateJavaScript("document.querySelector('input').value") as? String == "")
        try await load(form("<input type='password'>", extra: "<button>Other submit</button>"), in: session, path: "/log-in/password")
        #expect(try await authorization.advance(account: account, in: session) == .waiting)
        try await Task.sleep(for: .milliseconds(2100))
        guard case .manual = try await authorization.advance(account: account, in: session) else { Issue.record("Ambiguous form must require manual action"); return }
        #expect(try await session.evaluate("document.querySelector('input').value") as? String == "")
        #expect(try await session.evaluate("document.body.dataset.count === undefined") as? Bool == true)
    }

    @Test func accountChooserMatchesWholeEmailAndRejectsDuplicates() async throws {
        let session = session()
        try await load("""
        <button onclick="document.body.dataset.chosen='wrong'">owner@example.com.evil</button>
        <button onclick="document.body.dataset.chosen='remove'">Remove owner@example.com</button>
        <button onclick="document.body.dataset.chosen='correct'">Account name <span>owner@example.com</span></button>
        """, in: session, path: "/choose-an-account")
        #expect(try await CodexAccAuthorization.chooseAccount(email: account.email, in: session))
        #expect(try await session.evaluate("document.body.dataset.chosen") as? String == "correct")
        try await load("<button>owner@example.com</button><button>owner@example.com</button>", in: session, path: "/choose-an-account")
        #expect(try await !CodexAccAuthorization.chooseAccount(email: account.email, in: session))
        try await load("""
        <button>other@example.com</button>
        <button onclick="document.body.dataset.chosen='another'">Use another account</button>
        """, in: session, path: "/choose-an-account")
        #expect(try await CodexAccAuthorization.chooseAccount(email: account.email, in: session))
        #expect(try await session.evaluate("document.body.dataset.chosen") as? String == "another")
    }

    @Test func knownCodexConsentWithMatchingVisibleEmailSubmitsOnce() async throws {
        let (authorization, session) = try await prepared()
        try await load(consent(), in: session)
        #expect(try await authorization.advance(account: account, in: session) == .waiting)
        #expect(try await authorization.advance(account: account, in: session) == .waiting)
        #expect(try await session.evaluate("document.body.dataset.count") as? String == "1")
    }

    @Test func oauthNavigationWaitsForPreviousSavedChatGPTPageToLeave() async throws {
        let (authorization, session) = try await prepared()
        try await load("<main>Saved ChatGPT session</main>", in: session, path: "/", host: "chatgpt.com")
        #expect(try await authorization.advance(account: account, in: session) == .waiting)
        try await load(consent(), in: session)
        #expect(try await authorization.advance(account: account, in: session) == .waiting)
        #expect(try await session.evaluate("document.body.dataset.count") as? String == "1")
    }

    @Test(arguments: ["/choose-an-account", "/sign-in-with-chatgpt/codex/consent"])
    func delayedAccountSelectionRenderContinuesWithoutManualResume(path: String) async throws {
        let (authorization, session) = try await prepared()
        try await load("<main>Loading</main>", in: session, path: path)
        #expect(try await authorization.advance(account: account, in: session) == .waiting)
        try await Task.sleep(for: .milliseconds(2100))
        #expect(try await authorization.advance(account: account, in: session) == .waiting)
        let html = path == "/choose-an-account"
            ? "<button onclick=\"document.body.dataset.count='1'\">owner@example.com</button>"
            : """
              <form aria-label="Вход в Codex с помощью ChatGPT" onsubmit="event.preventDefault();document.body.dataset.count='1'">
                <span>owner@example.com</span><label><input type="radio" checked disabled style="opacity:0;width:12px;height:12px">
                <span aria-hidden="true">O</span><span>Личная учетная запись</span></label><button>Продолжить</button>
              </form>
              """
        let encoded = String(decoding: try JSONEncoder().encode(html), as: UTF8.self)
        _ = try await session.evaluate("(() => { document.title='Вход в Codex с помощью ChatGPT - OpenAI';document.body.innerHTML=\(encoded);return true; })()")
        #expect(try await authorization.advance(account: account, in: session) == .waiting)
        #expect(try await session.evaluate("document.body.dataset.count") as? String == "1")
        #expect(try await authorization.advance(account: account, in: session) == .waiting)
        #expect(try await session.evaluate("document.body.dataset.count") as? String == "1")
    }

    @Test(arguments: ["input", "button", "labelledButton"])
    func observedRussianConsentWithSelectedPersonalWorkspaceSubmitsWithoutForm(radioKind: String) async throws {
        let (authorization, session) = try await prepared()
        let customRadio = radioKind == "labelledButton"
            ? "<button type='button' role='radio' aria-checked='true' aria-labelledby='personal-workspace' disabled style='width:20px;height:20px'></button><span id='personal-workspace'>Личная учетная запись</span>"
            : "<button type='button' role='radio' aria-checked='true' disabled>Личная учетная запись</button>"
        let html = radioKind == "input" ? chatGPTCodexConsent() : chatGPTCodexConsent().replacingOccurrences(
            of: "<label><input type=\"radio\" name=\"workspace\" checked disabled>Личная учетная запись</label>",
            with: customRadio)
        try await load(html, in: session, path: "/sign-in-with-chatgpt/codex/consent")
        #expect(try await authorization.advance(account: account, in: session) == .waiting)
        #expect(try await authorization.advance(account: account, in: session) == .waiting)
        #expect(try await session.evaluate("document.body.dataset.count") as? String == "1")
    }

    @Test func observedConsentKeepsIdentityWorkspaceAndActionGuards() async throws {
        let session = session()
        let fixtures = [
            chatGPTCodexConsent(email: "other@example.com"),
            chatGPTCodexConsent(email: "owner@example.com.evil"),
            chatGPTCodexConsent(email: "<span hidden>owner@example.com</span>"),
            chatGPTCodexConsent(extra: "<button>Продолжить</button>"),
            chatGPTCodexConsent(radio: "disabled"),
            chatGPTCodexConsent(extra: "<input type='password'>"),
            chatGPTCodexConsent(extra: "<input type='email'>"),
            chatGPTCodexConsent(buttonAttributes: "formaction='https://other.example/submit'"),
            "<form action='https://other.example/submit'>" + chatGPTCodexConsent() + "</form>",
            chatGPTCodexConsent().replacingOccurrences(of: "Личная учетная запись", with: "Рабочая область команды"),
            chatGPTCodexConsent().replacingOccurrences(of: "<title>Вход в Codex с помощью ChatGPT - OpenAI</title>", with: "<title>Another App - OpenAI</title>"),
            "<p>owner@example.com</p>" + chatGPTCodexConsent(email: "other@example.com"),
        ]
        for html in fixtures {
            try await load(html, in: session, path: "/sign-in-with-chatgpt/codex/consent")
            #expect(try await !CodexAccAuthorization.confirmCodexConsent(email: account.email, in: session))
            #expect(try await session.evaluate("document.body.dataset.count === undefined") as? Bool == true)
        }
        try await load(chatGPTCodexConsent(), in: session, path: "/some-other-consent")
        #expect(try await !CodexAccAuthorization.confirmCodexConsent(email: account.email, in: session))
    }

    @Test func consentRejectsUnrelatedPagesHiddenOrWrongIdentityAndAmbiguousControls() async throws {
        let session = session()
        let fixtures = [
            consent(heading: "Sign in to Other App"), consent(email: "other@example.com"),
            consent(email: "owner@example.com.evil"), consent(extra: "<button>Continue</button>"),
            consent(action: "https://other.example/submit"),
            consent(email: "<span aria-hidden='true'>owner@example.com</span>"),
            "<p>owner@example.com</p>" + consent(email: "other@example.com"),
            "<h1>Sign in to Codex</h1><main><p>owner@example.com</p>" + form("") + "</main>",
        ]
        for html in fixtures {
            try await load(html, in: session)
            #expect(try await !CodexAccAuthorization.confirmCodexConsent(email: account.email, in: session))
            #expect(try await session.evaluate("document.body.dataset.count === undefined") as? Bool == true)
        }
        try await load(consent(), in: session, host: "chatgpt.com")
        #expect(try await !CodexAccAuthorization.confirmCodexConsent(email: account.email, in: session))
    }

    @Test(arguments: ["Check your email. Enter the code we sent.", "Verify you are human"])
    func emailAndSecurityChallengesNeverReceiveTOTP(message: String) async throws {
        let (authorization, session) = try await prepared()
        try await load("<p>\(message)</p>" + form("<input name='code'>"), in: session, path: "/mfa-challenge/fixture")
        guard case .manual = try await authorization.advance(account: account, in: session) else { Issue.record("Manual challenge was not recognized"); return }
        #expect(try await session.evaluate("document.querySelector('input').value") as? String == "")
        #expect(try await session.evaluate("document.body.dataset.count === undefined") as? Bool == true)
    }

    @Test func codexPrefersPasswordAndUsesConfiguredMailboxCodeOnce() async throws {
        var configured = account
        configured.externalMailbox = try ExternalMailboxConfiguration(address: "inbox@example.com", codeURL: "https://inbox.example.com/code")
        let session = session()
        let mailbox = ExternalLoginMailboxFixture()
        let browser = ChatGPTAutomation(sessionManager: WebSessionManager(accountSessionFactory: { _ in session }),
                                        makeExternalMailbox: { _ in mailbox })
        let authorization = CodexAccAuthorization(browser: browser)
        _ = try await authorization.prepare(account: configured, authorizationURL: authorizationURL())
        try await load("""
        \(form("<input type='email'>"))
        <a href='/log-in/password' onclick='event.preventDefault();document.body.dataset.password="chosen"'>Continue with password</a>
        """, in: session, path: "/log-in-or-create-account")
        #expect(try await authorization.advance(account: configured, in: session) == .waiting)
        #expect(try await authorization.advance(account: configured, in: session) == .waiting)
        #expect(try await session.evaluate("document.body.dataset.password") as? String == "chosen")
        #expect(try await session.evaluate("document.querySelector('input').value") as? String == "")
        #expect(mailbox.captures == 0)

        try await load("<main><p>owner@example.com</p>\(form("<input type='password'>"))</main>", in: session, path: "/log-in/password")
        mailbox.beforeCapture = { () async throws in
            let value = try await session.evaluate("document.querySelector('input').value") as? String
            #expect(value == "")
        }
        #expect(try await authorization.advance(account: configured, in: session) == .waiting)
        #expect(try await session.evaluate("document.body.dataset.count") as? String == "1")
        #expect(mailbox.captures == 1)

        try await load("<main><p>Code sent to owner@example.com</p>\(form("<input name='code' autocomplete='one-time-code'>"))</main>",
                       in: session, path: "/email-verification")
        #expect(try await authorization.advance(account: configured, in: session) == .waiting)
        #expect(try await authorization.advance(account: configured, in: session) == .waiting)
        #expect(try await session.evaluate("document.querySelector('input').value") as? String == "123456")
        #expect(try await session.evaluate("document.body.dataset.count") as? String == "1")
        #expect(mailbox.reads == 1)
    }
}
