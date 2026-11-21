import Foundation

@MainActor
final class CodexAccAuthorization {
    enum State: Equatable {
        case waiting
        case manual(String)
    }

    enum AuthorizationError: LocalizedError {
        case invalidURL

        var errorDescription: String? {
            "CodexAcc вернул неподходящую ссылку авторизации. Импорт не начат."
        }
    }

    private struct Attempt {
        let session: BrowserSession
        let policy: OAuthNavigationPolicy
        let generation: Int
        var submitted: Set<String> = []
        var observedURL: URL?
        var observedAt = ContinuousClock.now
    }

    private let browser: ChatGPTAutomation
    private var attempts: [UUID: Attempt] = [:]

    init(browser: ChatGPTAutomation) {
        self.browser = browser
    }

    static func isAllowedAuthorizationURL(_ url: URL) -> Bool {
        guard let policy = OAuthNavigationPolicy(authorizationURL: url),
              url.fragment == nil,
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        else { return false }
        func value(_ name: String) -> String? {
            let matches = items.filter { $0.name == name }
            return matches.count == 1 ? matches[0].value : nil
        }
        let scopes = value("scope")?.split(whereSeparator: \.isWhitespace).map(String.init) ?? []
        let redirect = policy.redirectURL
        return value("client_id") == "app_EMoamEEZ73f0CkXaXp7hrann" &&
            value("response_type") == "code" &&
            value("state")?.isEmpty == false &&
            value("code_challenge_method") == "S256" &&
            value("code_challenge")?.isEmpty == false &&
            scopes.count == 4 && Set(scopes) == Set(["openid", "profile", "email", "offline_access"]) &&
            redirect.scheme == "http" &&
            ["localhost", "127.0.0.1"].contains(redirect.host?.lowercased() ?? "") &&
            redirect.port.map { (1...65535).contains($0) } == true &&
            redirect.path == "/auth/callback" && redirect.query == nil
    }

    func prepare(account: AccountRecord, authorizationURL: URL) async throws -> BrowserSession {
        guard Self.isAllowedAuthorizationURL(authorizationURL),
              let policy = OAuthNavigationPolicy(authorizationURL: authorizationURL)
        else { throw AuthorizationError.invalidURL }
        let session = try await browser.authorizationSession(for: account)
        try Task.checkCancellation()
        session.loadOAuth(authorizationURL, mode: .automatic)
        session.setVisible(true)
        attempts[account.id] = Attempt(session: session, policy: policy, generation: session.cancellationGeneration)
        return session
    }

    func advance(account: AccountRecord, in session: BrowserSession) async throws -> State {
        try Task.checkCancellation()
        guard let attempt = attempts[account.id], attempt.session === session,
              attempt.generation == session.cancellationGeneration
        else { throw CancellationError() }
        // BrowserSession forwards the callback to CodexAcc's listener. Never evaluate or fetch its code.
        if attempt.policy.allowsCallback(session.callbackURL) || attempt.policy.allowsCallback(session.webView.url) {
            return .waiting
        }
        guard let url = session.webView.url else { return .waiting }
        // WKWebView keeps the previous ChatGPT URL while the OAuth navigation starts.
        if TrustedChatGPTOrigin.allowsMetadata(url),
           ContinuousClock.now < attempt.observedAt.advanced(by: .seconds(30)) { return .waiting }
        guard TrustedChatGPTOrigin.allowsAuthentication(url), url.host?.lowercased() == "auth.openai.com" else {
            return .manual("Продолжите авторизацию Codex в браузере. На этой странице данные аккаунта не подставляются.")
        }
        if attempt.observedURL != url {
            attempts[account.id]?.observedURL = url
            attempts[account.id]?.observedAt = .now
        }
        let page = try await session.evaluate("""
        (() => {
          const frames = [...document.querySelectorAll('iframe')].filter(e => {
            const r = e.getBoundingClientRect(); return r.width > 1 && r.height > 1;
          }).map(e => `${e.src} ${e.title}`).join(' ');
          return {url:location.href, text:`${document.body?.innerText || ''} ${frames}`};
        })()
        """) as? [String: String] ?? [:]
        let text = page["text"] ?? ""
        guard page["url"] == url.absoluteString, session.webView.url == url,
              attempt.generation == session.cancellationGeneration else { return .waiting }
        if ChatGPTAutomation.detectsSecurityChallenge(url: url, text: text) {
            return .manual("Пройдите проверку безопасности OpenAI в браузере. Импорт продолжится после проверки.")
        }
        if ChatGPTAutomation.detectsDeactivatedAccount(url: url, text: text) {
            return .manual("OpenAI сообщает, что аккаунт удалён или деактивирован. Проверьте страницу входа.")
        }
        if ChatGPTAutomation.detectsAuthenticationServerError(url: url, text: text) {
            return .manual("OpenAI вернул ошибку сервера. Проверьте страницу авторизации.")
        }
        let path = url.path.lowercased()
        if path.contains("email-verification") || path.contains("verify-email") ||
            (path.hasPrefix("/mfa-challenge/") && Self.isEmailChallenge(text)) {
            return .manual("OpenAI запросил код из письма. Введите его в браузере; импорт продолжится после проверки.")
        }
        if path == "/log-in/password", PasswordChangeForm.rejectsPassword(text) {
            return .manual("OpenAI отклонил сохранённый пароль. Продолжите вход в браузере.")
        }
        if ChatGPTAutomation.detectsRejectedAuthenticatorCode(url: url, text: text) {
            return .manual("OpenAI отклонил код 2FA. Введите действующий код в браузере.")
        }

        let challenge = url.absoluteString
        guard !attempt.submitted.contains(challenge) else { return .waiting }
        var submitted = false
        switch path {
        case "/log-in":
            submitted = try await EmailChangeAutomation.submitLoginEmail(account.email, in: session)
        case "/log-in-or-create-account":
            submitted = try await browser.fillAndSubmit(
                selectors: ["input[type='email']"], value: account.email,
                context: .authentication, in: session) == .submitted
        case "/log-in/password":
            submitted = try await browser.fillAndSubmit(
                selectors: ["input[type='password']"], value: account.password,
                context: .authentication, in: session,
                expectedPageURL: url, expectedEmail: account.email) == .submitted
        case "/choose-an-account":
            submitted = try await Self.chooseAccount(email: account.email, in: session)
        case let route where route.hasPrefix("/mfa-challenge/"):
            let delay = TOTPService.safeSubmissionDelay()
            if delay > 0 { try await Task.sleep(for: .seconds(delay + 0.15)) }
            try Task.checkCancellation()
            guard session.webView.url == url, attempt.generation == session.cancellationGeneration else { return .waiting }
            let code = try TOTPService.code(secret: account.totpSecret)
            let result = try await browser.submitAuthenticationOTP(value: code, in: session)
            submitted = result == .submitted
            if ChatGPTAutomation.needsKeyboardMFAFallback(url: session.webView.url, formResult: result) {
                submitted = await session.submitMFAUsingKeyboard(code)
            }
        default:
            switch try await CodexConsentForm.advance(email: account.email, in: session) {
            case .submitted: submitted = true
            case .selected:
                attempts[account.id]?.observedAt = .now
                return .waiting
            case .waiting:
                if let observedAt = attempts[account.id]?.observedAt,
                   ContinuousClock.now < observedAt.advanced(by: .seconds(30)) { return .waiting }
            case .notFound: break
            }
        }
        if submitted {
            attempts[account.id]?.submitted.insert(challenge)
            return .waiting
        }
        let renderWait = ["/choose-an-account", "/codex/consent", "/sign-in-with-chatgpt/codex/consent"].contains(path) ? 30 : 2
        if let observedAt = attempts[account.id]?.observedAt,
           ContinuousClock.now < observedAt.advanced(by: .seconds(renderWait)) { return .waiting }
        return .manual("OpenAI ожидает действие в браузере. Проверьте выбранный аккаунт и продолжите авторизацию Codex.")
    }

    private static func isEmailChallenge(_ text: String) -> Bool {
        text.range(of: #"check your (email|inbox)|email (?:verification|code)|code (?:we |that we )?sent|sent (?:a |an |the )?code|код[^\n]*(?:почт|email|письм)|проверьте[^\n]*почт"#,
                   options: .regularExpression.union(.caseInsensitive)) != nil
    }

    private static let controlHelpers = #"""
      if (location.origin !== 'https://auth.openai.com') return false;
      const shown = e => {
        const r = e.getBoundingClientRect();
        return r.width > 0 && r.height > 0 && getComputedStyle(e).visibility !== 'hidden' &&
          !e.closest('[hidden], [aria-hidden="true"], [inert]');
      };
      const enabled = e => !e.disabled && e.getAttribute('aria-disabled') !== 'true';
      const text = e => (e.innerText || e.value || e.getAttribute('aria-label') || '').trim();
      const emails = e => {
        const walker = document.createTreeWalker(e, NodeFilter.SHOW_TEXT);
        const visible = [];
        while (walker.nextNode()) {
          if (shown(walker.currentNode.parentElement)) visible.push(walker.currentNode.textContent);
        }
        return [...new Set((visible.join(' ').toLowerCase().match(/[a-z0-9.!#$%&'*+/=?^_`{|}~-]+@[a-z0-9.-]+\.[a-z]{2,}/g) || []))];
      };
      const sameOrigin = raw => {
        try { const u = new URL(raw, location.href); return u.origin === location.origin && !u.username && !u.password; }
        catch { return false; }
      };
      const safeControl = e => enabled(e) &&
        (!e.hasAttribute('href') || sameOrigin(e.getAttribute('href'))) &&
        (!e.form || sameOrigin(e.form.action)) &&
        (!e.hasAttribute('formaction') || sameOrigin(e.getAttribute('formaction')));
    """#

    static func chooseAccount(email: String, in session: BrowserSession) async throws -> Bool {
        guard TrustedChatGPTOrigin.allowsAuthentication(session.webView.url),
              session.webView.url?.host?.lowercased() == "auth.openai.com",
              session.webView.url?.path == "/choose-an-account"
        else { return false }
        let expected = String(decoding: try JSONEncoder().encode(email.lowercased()), as: UTF8.self)
        return try await session.evaluate("""
        (() => {
          \(controlHelpers)
          if (location.pathname !== '/choose-an-account') return false;
          const allControls = [...document.querySelectorAll('button,a,[role="button"]')].filter(shown);
          let controls = allControls.filter(e => {
            const found = emails(e);
            return found.length === 1 && found[0] === \(expected) && !/(^|\\s)(remove|delete|удалить)/i.test(text(e));
          });
          if (controls.length === 0) controls = allControls.filter(e =>
            /^(Use another account|Использовать другой аккаунт)$/i.test(text(e)));
          if (controls.length !== 1 || !safeControl(controls[0])) return false;
          controls[0].click(); return true;
        })()
        """) as? Bool == true
    }

    static func confirmCodexConsent(email: String, in session: BrowserSession) async throws -> Bool {
        try await CodexConsentForm.advance(email: email, in: session) == .submitted
    }
}
