import Foundation
import Testing
import WebKit
@testable import GPTAccountManager

@MainActor
@Suite struct BrowserAutomationSafetyTests {
    private func fixtureSession(
        _ html: String,
        baseURL: URL = URL(string: "https://chatgpt.com/#settings/Security")!
    ) async throws -> BrowserSession {
        let session = BrowserSession(dataStore: .nonPersistent())
        session.webView.navigationDelegate = nil
        session.webView.loadHTMLString(html, baseURL: baseURL)
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(3))
        while session.webView.isLoading, clock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(TrustedChatGPTOrigin.allowsTopLevelNavigation(session.webView.url))
        return session
    }

    @Test func recoveryKeepsAnOpenSecurityActionPageInsteadOfReloadingIt() async throws {
        let session = try await fixtureSession(
            """
            <html><body data-recovery-dialog="kept">
              <section>
                <span>Authenticator app</span>
                <button role="switch" aria-label="Authenticator app"
                        aria-checked="true" style="width:44px;height:24px"></button>
              </section>
            </body></html>
            """,
            baseURL: URL(string:
                "https://chatgpt.com/?action=disable&factor_id=test#settings/Security")!)
        let automation = ChatGPTAutomation(sessionManager: WebSessionManager())

        let opened = await automation.openSecuritySettings(in: session, seconds: 1)

        #expect(opened)
        #expect(session.webView.url?.query?.contains("action=disable") == true)
        #expect(try await session.evaluate(
            "document.body.dataset.recoveryDialog") as? String == "kept")
    }

    @Test func explicitProofRejectsPreauthenticatedSessionWithoutFreshCredentials() {
        #expect(ChatGPTAutomation.explicitLoginDecision(
            authenticated: true,
            proof: .none) == .restartFreshSession)
        #expect(ChatGPTAutomation.explicitLoginDecision(
            authenticated: false,
            proof: .none) == .continueLogin)
        #expect(ChatGPTAutomation.explicitLoginDecision(
            authenticated: true,
            proof: .init(
                passwordSubmitted: true,
                pendingOTPSubmitted: true,
                authenticatedImmediatelyAfterPendingOTP: true)
        ) == .acceptAuthenticated)
    }

    @Test func manualMFACompletionRequiresPasswordChallengeAndAuthentication() {
        let passwordProof = CleanLoginProof(
            passwordSubmitted: true,
            pendingOTPSubmitted: false,
            authenticatedImmediatelyAfterPendingOTP: false)

        let completed = ChatGPTAutomation.manualMFACompletionProof(
            proof: passwordProof,
            challengeObserved: true,
            authenticated: true)

        #expect(completed.isSufficient)
        #expect(!ChatGPTAutomation.manualMFACompletionProof(
            proof: .none,
            challengeObserved: true,
            authenticated: true).isSufficient)
        #expect(!ChatGPTAutomation.manualMFACompletionProof(
            proof: passwordProof,
            challengeObserved: false,
            authenticated: true).isSufficient)
        #expect(!ChatGPTAutomation.manualMFACompletionProof(
            proof: passwordProof,
            challengeObserved: true,
            authenticated: false).isSufficient)
    }

    @Test func cleanLoginTimeoutKeepsTheCurrentMFASessionForManualContinuation() async throws {
        let session = try await fixtureSession(
            """
            <html><body>
              <form id="mfa">
                <label>One-time code<input name="code" inputmode="numeric"></label>
                <button type="submit">Continue</button>
              </form>
              <script>
                document.querySelector('#mfa').addEventListener('submit', event => {
                  event.preventDefault();
                  document.body.dataset.submitted = 'yes';
                });
              </script>
            </body></html>
            """,
            baseURL: URL(string: "https://auth.openai.com/mfa-challenge/test")!)
        let account = AccountRecord(credential: .init(
            email: "owner@example.com",
            password: "pw",
            totpSecret: "JBSWY3DPEHPK3PXP"))
        let automation = ChatGPTAutomation(sessionManager: WebSessionManager())
        session.setVisible(true)

        let result = await automation.signIn(
            account: account,
            secret: account.totpSecret,
            in: session,
            initialProof: .init(passwordSubmitted: true, pendingOTPSubmitted: false),
            requireExplicitProof: true,
            immediateAuthenticationWaitSeconds: 0)

        guard case .manual = result else {
            Issue.record("A slow redirect must pause in the current verification session")
            return
        }
        #expect(session.isVisible)
        #expect(try await session.evaluate("document.body.dataset.submitted") as? String == "yes")
    }

    @Test func missingMFAFieldRequestsKeyboardFallbackImmediately() {
        let mfaURL = URL(string: "https://auth.openai.com/mfa-challenge/test")!

        #expect(ChatGPTAutomation.needsKeyboardMFAFallback(
            url: mfaURL,
            formResult: .notFound))
        #expect(!ChatGPTAutomation.needsKeyboardMFAFallback(
            url: mfaURL,
            formResult: .submitted))
        #expect(!ChatGPTAutomation.needsKeyboardMFAFallback(
            url: URL(string: "https://chatgpt.com/")!,
            formResult: .notFound))
    }

    @Test func cleanLoginKeepsTheBrowserVisibleWhileWaitingForTheNewCodeToBeAccepted() async throws {
        let session = try await fixtureSession(
            """
            <form id="mfa"><input name="code" inputmode="numeric"><button>Continue</button></form>
            <script>
              document.querySelector('#mfa').addEventListener('submit', event => {
                event.preventDefault();
                document.body.dataset.submitted = 'yes';
              });
            </script>
            """,
            baseURL: URL(string: "https://auth.openai.com/mfa-challenge/test")!)
        let account = AccountRecord(credential: .init(
            email: "fixture@example.com", password: "fixture", totpSecret: "JBSWY3DPEHPK3PXP"))
        let automation = ChatGPTAutomation(sessionManager: WebSessionManager())
        session.setVisible(true)
        let task = Task {
            await automation.signIn(
                account: account, secret: "KRUGS4ZANFZSAYJA", in: session,
                initialProof: .init(passwordSubmitted: true, pendingOTPSubmitted: false),
                requireExplicitProof: true, immediateAuthenticationWaitSeconds: 2)
        }
        defer { task.cancel() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(8))
        while session.operationMessage?.contains("новый код отправлен") != true,
              ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(try await session.evaluate("document.body.dataset.submitted") as? String == "yes")
        #expect(session.operationMessage?.contains("новый код отправлен") == true)
        #expect(session.isVisible)
        guard case .manual(_, let proof) = await task.value else {
            Issue.record("Unconfirmed redirect must preserve pending proof for continuation")
            return
        }
        #expect(proof.pendingOTPSubmitted)
        #expect(!proof.isSufficient)
    }

    @Test func retryingMFACheckKeepsVisibleChallengeSessionMounted() {
        let mfaURL = URL(string: "https://auth.openai.com/mfa-challenge/test")!

        #expect(ChatGPTAutomation.shouldKeepAuthenticationSessionVisible(
            isVisible: true,
            url: mfaURL))
        #expect(!ChatGPTAutomation.shouldKeepAuthenticationSessionVisible(
            isVisible: false,
            url: mfaURL))
        #expect(ChatGPTAutomation.shouldKeepAuthenticationSessionVisible(
            isVisible: true,
            url: URL(string: "https://auth.openai.com/log-in/password")!))
        #expect(ChatGPTAutomation.shouldKeepAuthenticationSessionVisible(
            isVisible: true,
            url: URL(string: "https://chatgpt.com/")!))
        #expect(!ChatGPTAutomation.shouldKeepAuthenticationSessionVisible(
            isVisible: true,
            url: URL(string: "https://example.com/")!))
    }

    @Test func continuingCleanLoginKeepsTheSameVerificationSession() {
        let manager = WebSessionManager()
        let account = AccountRecord(credential: .init(
            email: "one@example.com",
            password: "pw",
            totpSecret: "JBSWY3DPEHPK3PXP"))
        let automation = ChatGPTAutomation(sessionManager: manager)

        let first = automation.cleanLoginSession(for: account)
        first.setVisible(true)
        let second = automation.cleanLoginSession(for: account)

        #expect(first === second)
        #expect(second.isVisible)
        #expect(automation.browserSession(for: account) === first)
    }

    @Test func cleanLoginWaitsLongEnoughForSlowMFARedirect() {
        #expect(ChatGPTAutomation.cleanLoginAuthenticationWaitSeconds == 30)
    }

    @Test func detectsCloudflareChallengeBeforeLoginTimeout() {
        #expect(ChatGPTAutomation.detectsSecurityChallenge(
            url: URL(string: "https://auth.openai.com/api/accounts/authorize")!,
            text: "Этот веб-сайт использует сервис безопасности для защиты от вредоносных ботов."))
        #expect(ChatGPTAutomation.detectsSecurityChallenge(
            url: URL(string: "https://challenges.cloudflare.com/cdn-cgi/challenge-platform/turnstile")!,
            text: ""))
        #expect(!ChatGPTAutomation.detectsSecurityChallenge(
            url: URL(string: "https://auth.openai.com/log-in/password")!,
            text: "Введите ваш пароль"))
    }

    @Test func hiddenTurnstileFrameDoesNotBlockPasswordForm() async throws {
        let session = try await fixtureSession(
            """
            <form><input type="password"><button>Continue</button></form>
            <iframe src="https://challenges.cloudflare.com/cdn-cgi/challenge-platform/turnstile"
                    style="display: none"></iframe>
            """,
            baseURL: URL(string: "https://auth.openai.com/log-in/password")!)
        let automation = ChatGPTAutomation(sessionManager: WebSessionManager())

        #expect(!(try await automation.hasSecurityChallenge(in: session)))
    }

    @Test func detectsAuthenticationServerErrorBeforeLoginTimeout() {
        let mfaURL = URL(string: "https://auth.openai.com/mfa-challenge/test")!

        #expect(ChatGPTAutomation.detectsAuthenticationServerError(
            url: mfaURL,
            text: "Упс, произошла ошибка! Server error 500"))
        #expect(!ChatGPTAutomation.detectsAuthenticationServerError(
            url: URL(string: "https://auth.openai.com/log-in/password")!,
            text: "Введите ваш пароль"))
        #expect(!ChatGPTAutomation.detectsAuthenticationServerError(
            url: URL(string: "https://chatgpt.com/")!,
            text: "Server error 500"))
    }

    @Test func detectsAuthenticationCallbackErrorBeforeLoginTimeout() {
        #expect(ChatGPTAutomation.detectsAuthenticationCallbackError(
            url: URL(string: "https://chatgpt.com/auth/error?error=undefined")!))
        #expect(!ChatGPTAutomation.detectsAuthenticationCallbackError(
            url: URL(string: "https://chatgpt.com/")!))
    }

    @Test func detectsDeactivatedAccountBeforeLoginTimeout() {
        let passwordURL = URL(string: "https://auth.openai.com/log-in/password")!

        #expect(ChatGPTAutomation.detectsDeactivatedAccount(
            url: passwordURL,
            text: "Ошибка аутентификации error_code: account_deactivated"))
        #expect(ChatGPTAutomation.detectsDeactivatedAccount(
            url: passwordURL,
            text: "Your account was deleted or deactivated"))
        #expect(!ChatGPTAutomation.detectsDeactivatedAccount(
            url: URL(string: "https://chatgpt.com/")!,
            text: "error_code: account_deactivated"))
    }

    @Test func readsDeactivatedAccountFromRenderedAuthenticationPage() async throws {
        let session = try await fixtureSession(
            "<main>Ошибка аутентификации <code>error_code: account_deactivated</code></main>",
            baseURL: URL(string: "https://auth.openai.com/log-in/password")!)
        let automation = ChatGPTAutomation(sessionManager: WebSessionManager())

        #expect(try await automation.hasDeactivatedAccount(in: session))
    }

    @Test func detectsRejectedAuthenticatorCodeBeforeRetryingIt() {
        let mfaURL = URL(string: "https://auth.openai.com/mfa-challenge/test")!

        #expect(ChatGPTAutomation.detectsRejectedAuthenticatorCode(
            url: mfaURL,
            text: "Неверный код. Попробуйте еще раз."))
        #expect(ChatGPTAutomation.detectsRejectedAuthenticatorCode(
            url: mfaURL,
            text: "Incorrect code. Try again."))
        #expect(!ChatGPTAutomation.detectsRejectedAuthenticatorCode(
            url: URL(string: "https://chatgpt.com/")!,
            text: "Неверный код"))
    }

    @Test func cleanLoginPresentationPrefersIsolatedVerificationBrowser() {
        let accountID = UUID()
        let persistent = BrowserSession(dataStore: .nonPersistent())
        let verification = BrowserSession(dataStore: .nonPersistent())

        let selected = ChatGPTAutomation.displaySession(
            accountID: accountID,
            verificationSessions: [accountID: verification],
            persistent: persistent)
        let fallback = ChatGPTAutomation.displaySession(
            accountID: accountID,
            verificationSessions: [:],
            persistent: persistent)

        #expect(selected === verification)
        #expect(fallback === persistent)
    }

    @Test func completedSubscriptionCheckLeavesItsBrowserVisible() async {
        let account = AccountRecord(credential: .init(
            email: "owner@example.com",
            password: "pw",
            totpSecret: "JBSWY3DPEHPK3PXP"))
        let automation = ChatGPTAutomation(sessionManager: WebSessionManager())
        let session = automation.subscriptionCheckSession(for: account)
        session.setVisible(true)
        let snapshot = SubscriptionSnapshot(
            signedInEmail: account.email,
            planLabel: "plus",
            activeUntil: Date(timeIntervalSince1970: 1_790_000_000),
            willRenew: true)

        let outcome = await automation.verifiedSubscription(
            snapshot,
            for: account,
            session: session)

        guard case .success = outcome else {
            Issue.record("A matching subscription snapshot should succeed")
            return
        }
        #expect(session.isVisible)
    }

    @Test func guestLoginControlCanBeClickedOnTrustedAuthenticationPage() async throws {
        let session = try await fixtureSession(
            """
            <html><body>
              <button id="login">Log in</button>
              <script>
                document.querySelector('#login').addEventListener('click', () => {
                  document.body.dataset.clicked = 'login';
                });
              </script>
            </body></html>
            """,
            baseURL: URL(string: "https://chatgpt.com/")!)
        let automation = ChatGPTAutomation(sessionManager: WebSessionManager())

        let result = try await automation.clickUniqueControl(
            labels: ["Log in", "Войти"],
            click: true,
            in: session)

        #expect(result == .clicked)
        let clicked = try await session.evaluate("document.body.dataset.clicked || null")
        #expect(clicked as? String == "login")
    }

    @Test func cookieConsentPrefersOnlyNecessaryCookies() async throws {
        let session = try await fixtureSession(
            """
            <html><body>
              <button id="necessary">Сохранять только обязательные</button>
              <button id="all">Принять все</button>
              <script>
                for (const id of ['necessary', 'all']) {
                  document.querySelector(`#${id}`).addEventListener('click', () => {
                    document.body.dataset.clicked = id;
                  });
                }
              </script>
            </body></html>
            """,
            baseURL: URL(string: "https://chatgpt.com/")!)
        let automation = ChatGPTAutomation(sessionManager: WebSessionManager())

        let result = await automation.dismissCookieConsent(in: session)

        #expect(result == .clicked)
        let clicked = try await session.evaluate("document.body.dataset.clicked || null")
        #expect(clicked as? String == "necessary")
    }

    @Test func logoutAllSessionsClicksTheEnglishControlAndItsConfirmation() async throws {
        let session = try await fixtureSession("""
        <html><body>
          <button id="sessions">Active sessions Review signed-in devices</button>
          <section id="active" style="display:none">
            <button id="start">Log out all devices</button>
          </section>
          <script>
            document.querySelector('#sessions').addEventListener('click', () => {
              document.querySelector('#active').style.display = 'block';
            });
            document.querySelector('#start').addEventListener('click', () => {
              document.body.dataset.started = 'yes';
              const dialog = document.createElement('section');
              dialog.innerHTML = `
                <div><h2>Log out of all devices?</h2></div>
                <button>Cancel</button>
                <button id="confirm">Log out</button>`;
              document.body.append(dialog);
              document.querySelector('#confirm').addEventListener('click', () => {
                document.body.dataset.confirmed = 'yes';
                setTimeout(() => dialog.remove(), 250);
              });
            });
          </script>
        </body></html>
        """)
        let automation = ChatGPTAutomation(sessionManager: WebSessionManager())

        let result = await automation.logOutAllSessions(
            in: session,
            navigateToSecurityRoot: false,
            confirmationSeconds: 2)

        #expect(result == .completed)
        #expect(try await session.evaluate("document.body.dataset.started") as? String == "yes")
        #expect(try await session.evaluate("document.body.dataset.confirmed") as? String == "yes")
        #expect(try await session.evaluate("document.querySelector('#confirm') || null") is NSNull)
    }

    @Test func logoutAllSessionsSupportsRussianControls() async throws {
        let session = try await fixtureSession("""
        <html><body>
          <button id="sessions">Активные сеансы Просмотрите все устройства</button>
          <section id="active" style="display:none">
            <button id="start">Выйти из всех сеансов</button>
          </section>
          <script>
            document.querySelector('#sessions').addEventListener('click', () => {
              document.querySelector('#active').style.display = 'block';
            });
            document.querySelector('#start').addEventListener('click', () => {
              const dialog = document.createElement('section');
              dialog.innerHTML = `
                <div><h2>Выйти со всех устройств?</h2></div>
                <button>Отмена</button>
                <button id="confirm">Выйти со всех устройств</button>`;
              document.body.append(dialog);
              document.querySelector('#confirm').addEventListener('click', () => {
                document.body.dataset.confirmed = 'yes';
                setTimeout(() => dialog.remove(), 250);
              });
            });
          </script>
        </body></html>
        """)
        let automation = ChatGPTAutomation(sessionManager: WebSessionManager())

        let result = await automation.logOutAllSessions(
            in: session,
            navigateToSecurityRoot: false,
            confirmationSeconds: 2)

        #expect(result == .completed)
        #expect(try await session.evaluate("document.body.dataset.confirmed") as? String == "yes")
    }

    @Test func logoutAllSessionsDoesNotCompleteWhileConfirmationRemainsOpen() async throws {
        let session = try await fixtureSession("""
        <html><body>
          <button id="sessions">Active sessions Review signed-in devices</button>
          <section id="active" style="display:none">
            <button id="start">Log out all devices</button>
          </section>
          <script>
            document.querySelector('#sessions').addEventListener('click', () => {
              document.querySelector('#active').style.display = 'block';
            });
            document.querySelector('#start').addEventListener('click', () => {
              const dialog = document.createElement('section');
              dialog.innerHTML = `
                <div><h2>Log out of all devices?</h2></div>
                <button>Cancel</button>
                <button id="confirm">Log out</button>`;
              document.body.append(dialog);
              document.querySelector('#confirm').addEventListener('click', () => {
                document.body.dataset.confirmed = 'yes';
              });
            });
          </script>
        </body></html>
        """)
        let automation = ChatGPTAutomation(sessionManager: WebSessionManager())

        let result = await automation.logOutAllSessions(
            in: session,
            navigateToSecurityRoot: false,
            confirmationSeconds: 1)

        #expect(result == .ambiguous)
        #expect(try await session.evaluate("document.body.dataset.confirmed") as? String == "yes")
        #expect(try await session.evaluate(
            "Boolean(document.querySelector('#confirm'))") as? Bool == true)
    }

    @Test func logoutAllSessionsTracksTheDialogWhenItsHeadingChanges() async throws {
        let session = try await fixtureSession("""
        <html><body>
          <button id="sessions">Active sessions Review signed-in devices</button>
          <section id="active" style="display:none">
            <button id="start">Log out all devices</button>
          </section>
          <script>
            document.querySelector('#sessions').addEventListener('click', () => {
              document.querySelector('#active').style.display = 'block';
            });
            document.querySelector('#start').addEventListener('click', () => {
              const dialog = document.createElement('section');
              dialog.id = 'logout-dialog';
              dialog.innerHTML = `
                <h2>Log out of all devices?</h2>
                <button>Cancel</button>
                <button id="confirm">Log out</button>`;
              document.body.append(dialog);
              document.querySelector('#confirm').addEventListener('click', () => {
                dialog.querySelector('h2').textContent = 'Signing out…';
              });
            });
          </script>
        </body></html>
        """)
        let automation = ChatGPTAutomation(sessionManager: WebSessionManager())

        let result = await automation.logOutAllSessions(
            in: session,
            navigateToSecurityRoot: false,
            confirmationSeconds: 1)

        #expect(result == .ambiguous)
        #expect(try await session.evaluate(
            "Boolean(document.querySelector('#logout-dialog'))") as? Bool == true)
    }

    @Test func logoutAllSessionsFailsClosedWhenTheControlIsAmbiguous() async throws {
        let session = try await fixtureSession("""
        <html><body>
          <button id="sessions">Active sessions Review signed-in devices</button>
          <section id="active" style="display:none">
            <button class="logout">Log out all devices</button>
            <button class="logout">Log out all devices</button>
          </section>
          <script>
            document.querySelector('#sessions').addEventListener('click', () => {
              document.querySelector('#active').style.display = 'block';
            });
            for (const control of document.querySelectorAll('.logout')) {
              control.addEventListener('click', () => {
                document.body.dataset.clicked = 'yes';
              });
            }
          </script>
        </body></html>
        """)
        let automation = ChatGPTAutomation(sessionManager: WebSessionManager())

        let result = await automation.logOutAllSessions(
            in: session,
            navigateToSecurityRoot: false)

        #expect(result == .ambiguous)
        #expect(try await session.evaluate("document.body.dataset.clicked || null") is NSNull)
    }

    @Test func rotationCompletesOnlyAfterConfirmedSessionLogout() {
        #expect(ChatGPTAutomation.logoutAllowsRotationCompletion(.completed))
        #expect(!ChatGPTAutomation.logoutAllowsRotationCompletion(.notFound))
        #expect(!ChatGPTAutomation.logoutAllowsRotationCompletion(.ambiguous))
    }

    @Test func accountChooserSelectsEmailWithoutClickingRemoveAccount() async throws {
        let session = try await fixtureSession(
            """
            <html><body>
              <button id="select">Выбрать учетную запись User a@example.com</button>
              <button id="remove" aria-label="Удалить учетную запись: a@example.com"></button>
              <script>
                for (const id of ['select', 'remove']) {
                  document.querySelector(`#${id}`).addEventListener('click', () => {
                    document.body.dataset.clicked = id;
                  });
                }
              </script>
            </body></html>
            """,
            baseURL: URL(string: "https://auth.openai.com/choose-an-account")!)
        let automation = ChatGPTAutomation(sessionManager: WebSessionManager())

        let result = try await automation.clickUniqueControl(
            labels: ["a@example.com"],
            click: true,
            in: session)

        #expect(result == .clicked)
        let clicked = try await session.evaluate("document.body.dataset.clicked || null")
        #expect(clicked as? String == "select")
    }

    @Test(arguments: ["data-login-button", "data-testid='login-button'"])
    func loggedOutPageUsesThePrimaryLoginButtonAmongDuplicateEntries(attribute: String) async throws {
        let session = try await fixtureSession(
            """
            <button onclick="document.body.dataset.clicked='sidebar'">Войти</button>
            <button id="primary" \(attribute) onclick="document.body.dataset.clicked='primary'">Войти</button>
            """,
            baseURL: URL(string: "https://chatgpt.com/")!)
        let automation = ChatGPTAutomation(sessionManager: WebSessionManager())
        let result = try await automation.clickUniqueControl(
            labels: ["Log in", "Войти"], click: true, in: session)
        #expect(result == .clicked)
        #expect(try await session.evaluate("document.body.dataset.clicked") as? String == "primary")

        _ = try await session.evaluate("(() => { const button = document.getElementById('primary'); button.removeAttribute('data-login-button'); button.removeAttribute('data-testid'); delete document.body.dataset.clicked; })()")
        #expect(try await automation.clickUniqueControl(
            labels: ["Log in", "Войти"], click: true, in: session) == .ambiguous)
        #expect(try await session.evaluate("document.body.dataset.clicked || null") is NSNull)
    }

    @Test func browserSessionAwaitsPromiseResults() async throws {
        let session = try await fixtureSession(
            "<html><body>ready</body></html>",
            baseURL: URL(string: "https://chatgpt.com/")!)

        let value = try await session.evaluate(
            "Promise.resolve({ state: 'loginRequired' })")

        let dictionary = try #require(value as? [String: Any])
        #expect(dictionary["state"] as? String == "loginRequired")
    }

    @Test(arguments: ["Вход", "Sign in"])
    func extraLoginLabelsAreLimitedToChatGPTEntry(label: String) async throws {
        let automation = ChatGPTAutomation(sessionManager: WebSessionManager())
        let html = "<button onclick=\"document.body.dataset.clicked='yes'\">\(label)</button>"
        let homepage = try await fixtureSession(html, baseURL: URL(string: "https://chatgpt.com/")!)
        #expect(try await automation.clickUniqueControl(labels: ["Log in", "Войти"], click: true, in: homepage) == .clicked)
        let passwordPage = try await fixtureSession(html, baseURL: URL(string: "https://auth.openai.com/log-in/password")!)
        #expect(try await automation.clickUniqueControl(labels: ["Log in", "Войти"], click: true, in: passwordPage) == .notFound)
        #expect(try await passwordPage.evaluate("document.body.dataset.clicked || null") is NSNull)
    }

    @Test func subscriptionRequestAuthenticatesAndReadsTheMatchingAccountDate() async throws {
        let session = try await fixtureSession(
            """
            <main>Signed in</main>
            <script>
              window.fetch = async (url, options) => {
                if (url === '/api/auth/session') return { ok: true, json: async () => ({
                  user: { email: 'owner@example.com' }, accessToken: 'fixture-access-token',
                  account: { id: 'selected-account', planType: 'plus' }
                }) };
                const authorized = url === '/backend-api/subscriptions?account_id=selected-account' &&
                  options?.headers?.Authorization === 'Bearer fixture-access-token';
                return { ok: authorized, json: async () => [
                  { account_id: 'other-account', plan_type: 'pro', active_until: '2030-01-01T00:00:00Z' },
                  { account_id: 'selected-account', plan_type: 'plus',
                    active_until: '2026-10-24T07:56:09Z', will_renew: true }
                ] };
              };
            </script>
            """,
            baseURL: URL(string: "https://chatgpt.com/")!)
        let automation = ChatGPTAutomation(sessionManager: WebSessionManager())
        let account = AccountRecord(credential: .init(
            email: "owner@example.com", password: "fixture", totpSecret: "JBSWY3DPEHPK3PXP"))
        let result = await automation.signIn(account: account, secret: account.totpSecret, in: session)
        guard case .success(let snapshot, _) = result else {
            Issue.record("Authenticated subscription must be read without a second login")
            return
        }
        #expect(snapshot.signedInEmail == "owner@example.com")
        #expect(snapshot.planLabel == "plus")
        #expect(snapshot.activeUntil == ISO8601DateFormatter().date(from: "2026-10-24T07:56:09Z"))
        #expect(snapshot.dateKind == .renews)
    }

    @Test func pricingDateComesOnlyFromVisibleCurrentPlanCard() async throws {
        let session = try await fixtureSession(
            """
            <html lang="ru-RU"><body>
              <section style="display:none">
                <h3>Plus</h3>
                <span>до 01 янв. 2030 г.</span>
                <button disabled>Ваш текущий план</button>
              </section>
              <section>
                <h3>Plus</h3>
                <span>до 30 сент. 2026 г.</span>
                <button disabled>Ваш текущий план</button>
              </section>
              <section>
                <h3>Pro</h3>
                <span>до 15 окт. 2026 г.</span>
                <button>Перейти на Pro</button>
              </section>
            </body></html>
            """,
            baseURL: URL(string: "https://chatgpt.com/#pricing")!)
        let automation = ChatGPTAutomation(sessionManager: WebSessionManager())

        let details = try #require(await automation.pricingDetails(in: session))

        #expect(details.activeUntilText == "до 30 сент. 2026 г.")
        #expect(details.localeIdentifier == "ru-RU")
    }

    @Test func genericControlOutsideAuthenticatorContainerIsNeverClicked() async throws {
        let session = try await fixtureSession("""
        <html><body>
          <button id="outside">Manage</button>
          <section><span>Authenticator app</span></section>
          <script>
            document.querySelector('#outside').addEventListener('click', () => {
              document.body.dataset.clicked = 'outside';
            });
          </script>
        </body></html>
        """)
        let automation = ChatGPTAutomation(sessionManager: WebSessionManager())

        let result = try await automation.clickUniqueControl(
            labels: ["Manage"],
            click: true,
            in: session)

        #expect(result == .notFound)
        let clicked = try await session.evaluate("document.body.dataset.clicked || null")
        #expect(clicked is NSNull)
    }

    @Test func authenticatorSwitchCanBeClickedWithoutTouchingOtherSwitches() async throws {
        let session = try await fixtureSession("""
        <html><body>
          <section>
            <span>Authenticator app</span>
            <button id="authenticator" role="switch"
                    aria-label="Authenticator app" aria-checked="true"></button>
          </section>
          <button id="other" role="switch"
                  aria-label="Text message" aria-checked="false"></button>
          <script>
            for (const id of ['authenticator', 'other']) {
              document.querySelector(`#${id}`).addEventListener('click', () => {
                document.body.dataset.clicked = id;
              });
            }
          </script>
        </body></html>
        """)
        let automation = ChatGPTAutomation(sessionManager: WebSessionManager())

        let result = try await automation.clickUniqueControl(
            labels: ["Authenticator app"],
            click: true,
            in: session)

        #expect(result == .clicked)
        let clicked = try await session.evaluate("document.body.dataset.clicked || null")
        #expect(clicked as? String == "authenticator")
    }

    @Test func newSecurityPageRecognizesLocalizedAuthenticatorSwitch() async throws {
        let session = try await fixtureSession(
            """
            <h1>Безопасность и вход</h1>
            <span id="auth-label">Приложение для аутентификации</span>
            <button role="switch" aria-labelledby="auth-label" aria-checked="true"
                    style="width:44px;height:24px"
                    onclick="document.body.dataset.clicked='auth'"></button>
            <button role="switch" aria-label="Текстовое сообщение" aria-checked="false"
                    onclick="document.body.dataset.clicked='sms'">SMS</button>
            """,
            baseURL: URL(string: "https://chatgpt.com/settings/security")!)
        let automation = ChatGPTAutomation(sessionManager: WebSessionManager())
        #expect(await automation.openSecuritySettings(in: session, seconds: 1))
        #expect(try await automation.authenticatorSwitch(click: true, in: session) == .clicked)
        #expect(try await session.evaluate("document.body.dataset.clicked") as? String == "auth")
        #expect(session.webView.url?.path == "/settings/security")
    }

    @Test func authenticatorSwitchReportsItsStateAndIgnoresOtherSwitches() async throws {
        let session = try await fixtureSession("""
        <html><body>
          <section>
            <span>Authenticator app</span>
            <button role="switch" aria-label="Authenticator app"
                    aria-checked="true"></button>
          </section>
          <button role="switch" aria-label="Text message"
                  aria-checked="false"></button>
        </body></html>
        """)
        let automation = ChatGPTAutomation(sessionManager: WebSessionManager())

        let result = try await automation.authenticatorSwitch(click: false, in: session)

        #expect(result == .on)
    }

    @Test func ambiguousAuthenticatorSwitchesFailClosed() async throws {
        let session = try await fixtureSession("""
        <html><body>
          <button role="switch" aria-label="Authenticator app"
                  aria-checked="true"></button>
          <button role="switch" aria-label="Authenticator app"
                  aria-checked="false"></button>
        </body></html>
        """)
        let automation = ChatGPTAutomation(sessionManager: WebSessionManager())

        let result = try await automation.authenticatorSwitch(click: true, in: session)

        #expect(result == .ambiguous)
    }

    @Test func removalConfirmationIsScopedToTheVerifiedDisableDialog() async throws {
        let session = try await fixtureSession(
            """
            <html><body>
              <button id="outside">Удалить</button>
              <div role="dialog">
                <h2>Удалить приложение для аутентификации</h2>
                <button id="remove">Удалить</button>
              </div>
              <script>
                for (const id of ['outside', 'remove']) {
                  document.querySelector(`#${id}`).addEventListener('click', () => {
                    document.body.dataset.clicked = id;
                  });
                }
              </script>
            </body></html>
            """,
            baseURL: URL(
                string: "https://chatgpt.com/?action=disable&factor_id=test#settings/Security")!)
        let automation = ChatGPTAutomation(sessionManager: WebSessionManager())

        let result = try await automation.clickUniqueControl(
            labels: ["Remove", "Delete", "Удалить"],
            click: true,
            in: session)

        #expect(result == .clicked)
        let clicked = try await session.evaluate("document.body.dataset.clicked || null")
        #expect(clicked as? String == "remove")
    }

    @Test(arguments: ["Удалить способ аутентификации?", "Remove authentication method?"])
    func genericRemovalDialogRequiresAnExplicitTOTPAction(heading: String) async throws {
        let session = try await fixtureSession(
            """
            <button id="outside">Удалить</button>
            <div role="dialog">
              <h2>\(heading)</h2>
              <button>Отмена</button>
              <button id="remove" onclick="document.body.dataset.clicked='remove'">Удалить</button>
            </div>
            """,
            baseURL: URL(string: "https://chatgpt.com/settings/security?action=disable&factor=totp&factor_id=fixture")!)
        let automation = ChatGPTAutomation(sessionManager: WebSessionManager())
        #expect(try await automation.clickUniqueControl(
            labels: ["Remove", "Delete", "Удалить"], click: true, in: session) == .clicked)
        #expect(try await session.evaluate("document.body.dataset.clicked || null") as? String == "remove")
    }

    @Test(arguments: [
        "action=disable&factor=sms&factor_id=fixture",
        "action=disable&factor=webauthn&factor_id=fixture",
        "action=disable&factor_id=fixture",
        "action=enable&factor=totp&factor_id=fixture",
        "action=disable&factor=totp",
        "action=disable&factor=totp&factor_id=",
        "action=disable&factor=totp&factor=sms&factor_id=fixture",
        "action=disable&action=enable&factor=totp&factor_id=fixture",
        "action=disable&factor=totp&factor_id=first&factor_id=second",
    ])
    func genericRemovalDialogNeverConfirmsOtherOrAmbiguousFactors(query: String) async throws {
        let session = try await fixtureSession(
            """
            <div role="dialog"><h2>Удалить способ аутентификации?</h2>
              <button onclick="document.body.dataset.clicked='wrong'">Удалить</button>
            </div>
            """,
            baseURL: URL(string: "https://chatgpt.com/settings/security?\(query)")!)
        let automation = ChatGPTAutomation(sessionManager: WebSessionManager())
        #expect(try await automation.clickUniqueControl(
            labels: ["Remove", "Delete", "Удалить"], click: true, in: session) != .clicked)
        #expect(try await session.evaluate("document.body.dataset.clicked || null") is NSNull)
    }

    @Test(arguments: [
        "?action=disable&factor=sms&factor_id=other",
        "/billing?action=disable&factor=totp&factor_id=fixture",
    ])
    func genericRemovalDialogRechecksFactorWhenThePageChangesDuringPolling(destination: String) async throws {
        let session = try await fixtureSession(
            """
            <main>Loading</main>
            """,
            baseURL: URL(string: "https://chatgpt.com/settings/security?action=disable&factor=totp&factor_id=fixture")!)
        _ = try await session.evaluate("""
            (() => { setTimeout(() => {
              history.replaceState(null, '', '\(destination)');
              document.body.dataset.changed = 'yes';
              document.body.insertAdjacentHTML('beforeend', `<div role="dialog">
                <h2>Удалить способ аутентификации?</h2>
                <button onclick="document.body.dataset.clicked='wrong'">Удалить</button></div>`);
            }, 200); })()
            """)
        let automation = ChatGPTAutomation(sessionManager: WebSessionManager())
        #expect(try await automation.clickUniqueControl(
            labels: ["Remove", "Delete", "Удалить"], click: true, in: session) != .clicked)
        #expect(try await session.evaluate("document.body.dataset.changed") as? String == "yes")
        #expect(try await session.evaluate("document.body.dataset.clicked || null") is NSNull)
    }

    @Test func removalConfirmationWaitsForTheVerifiedDialogToRender() async throws {
        let session = try await fixtureSession(
            """
            <html><body>
              <script>
                setTimeout(() => {
                  const dialog = document.createElement('div');
                  dialog.setAttribute('role', 'dialog');
                  dialog.innerHTML = `
                    <h2>Удалить приложение для аутентификации</h2>
                    <button id="remove">Удалить</button>`;
                  document.body.append(dialog);
                  document.querySelector('#remove').addEventListener('click', () => {
                    document.body.dataset.clicked = 'remove';
                  });
                }, 200);
              </script>
            </body></html>
            """,
            baseURL: URL(
                string: "https://chatgpt.com/?action=disable&factor_id=test#settings/Security")!)
        let automation = ChatGPTAutomation(sessionManager: WebSessionManager())

        let result = try await automation.clickUniqueControl(
            labels: ["Remove", "Delete", "Удалить"],
            click: true,
            in: session)

        #expect(result == .clicked)
        let clicked = try await session.evaluate("document.body.dataset.clicked || null")
        #expect(clicked as? String == "remove")
    }

    @Test func setupOTPSubmissionIsScopedToTheAuthenticatorDialog() async throws {
        let session = try await fixtureSession("""
        <html><body>
          <form id="outside">
            <input autocomplete="one-time-code">
            <button type="submit">Проверить</button>
          </form>
          <div role="dialog">
            <h2>Подключите приложение для аутентификации</h2>
            <form id="setup">
              <input autocomplete="one-time-code">
              <button type="submit">Проверить</button>
            </form>
          </div>
          <script>
            for (const form of document.forms) {
              form.addEventListener('submit', event => {
                event.preventDefault();
                document.body.dataset.submitted = event.target.id;
              });
            }
          </script>
        </body></html>
        """)
        let automation = ChatGPTAutomation(sessionManager: WebSessionManager())

        let result = try await automation.fillAndSubmit(
            selectors: ["input[autocomplete='one-time-code']"],
            value: "123456",
            context: .security,
            in: session)

        #expect(result == .submitted)
        let submitted = try await session.evaluate("document.body.dataset.submitted || null")
        #expect(submitted as? String == "setup")
    }

    @Test func hiddenSetupDialogDoesNotCaptureTheVisibleAuthenticatorForm() async throws {
        let session = try await fixtureSession("""
        <html><body>
          <div role="dialog" style="display:none">
            <h2>Подключите приложение для аутентификации</h2>
            <form id="hidden">
              <input autocomplete="one-time-code">
              <button type="submit">Проверить</button>
            </form>
          </div>
          <section>
            <span>Authenticator app</span>
            <form id="visible">
              <input autocomplete="one-time-code">
              <button type="submit">Продолжить</button>
            </form>
          </section>
          <script>
            for (const form of document.forms) {
              form.addEventListener('submit', event => {
                event.preventDefault();
                document.body.dataset.submitted = event.target.id;
              });
            }
          </script>
        </body></html>
        """)
        let automation = ChatGPTAutomation(sessionManager: WebSessionManager())

        let result = try await automation.fillAndSubmit(
            selectors: ["input[autocomplete='one-time-code']"],
            value: "123456",
            context: .security,
            in: session)

        #expect(result == .submitted)
        let submitted = try await session.evaluate("document.body.dataset.submitted || null")
        #expect(submitted as? String == "visible")
    }

    @Test func securityOTPSubmissionIgnoresMatchingFieldOutsideAuthenticatorForm() async throws {
        let session = try await fixtureSession("""
        <html><body>
          <form id="unrelated">
            <input autocomplete="one-time-code">
          </form>
          <section>
            <span>Authenticator app</span>
            <form id="authenticator">
              <input autocomplete="one-time-code">
            </form>
          </section>
          <script>
            for (const form of document.forms) {
              form.addEventListener('submit', event => {
                event.preventDefault();
                document.body.dataset.submitted = event.target.id;
              });
            }
          </script>
        </body></html>
        """)
        let automation = ChatGPTAutomation(sessionManager: WebSessionManager())

        let result = try await automation.fillAndSubmit(
            selectors: ["input[autocomplete='one-time-code']"],
            value: "123456",
            context: .security,
            in: session)

        #expect(result == .submitted)
        let submitted = try await session.evaluate("document.body.dataset.submitted || null")
        #expect(submitted as? String == "authenticator")
    }

    @Test func formSubmissionClicksItsUniqueVisibleSubmitButton() async throws {
        let session = try await fixtureSession("""
        <html><body>
          <section>
            <span>Authenticator app</span>
            <form>
              <input autocomplete="one-time-code">
              <button id="continue" type="submit">Continue</button>
            </form>
          </section>
          <script>
            document.querySelector('#continue').addEventListener('click', event => {
              event.preventDefault();
              document.body.dataset.clicked = 'continue';
            });
          </script>
        </body></html>
        """)
        let automation = ChatGPTAutomation(sessionManager: WebSessionManager())

        let result = try await automation.fillAndSubmit(
            selectors: ["input[autocomplete='one-time-code']"],
            value: "123456",
            context: .security,
            in: session)

        #expect(result == .submitted)
        let clicked = try await session.evaluate("document.body.dataset.clicked || null")
        #expect(clicked as? String == "continue")
    }

    @Test(arguments: ["Continue", "Продолжить"], [false, true])
    func passwordLoginChoosesContinueOverOneTimeCode(label: String, separateOTPForm: Bool) async throws {
        let alternate = label == "Continue" ? "Log in with a one-time code" : "Вход с одноразовым кодом"
        let otpForm = separateOTPForm ? "form='otp-form'" : ""
        let otherForm = separateOTPForm ? "<form id='otp-form'></form>" : ""
        let session = try await fixtureSession(
            """
            <h1>Введите ваш пароль</h1><p>owner@example.com</p>
            <button>Continue</button>
            <form>
              <input type="password" autocomplete="current-password">
              <button type="button">Показать пароль</button>
              <button id="otp" type="submit" \(otpForm)>\(alternate)</button>
              <button id="primary">\(label)</button>
            </form>\(otherForm)
            <script>
              document.querySelector('form').addEventListener('submit', event => {
                event.preventDefault();
                document.body.dataset.submitted = event.submitter.id;
              });
            </script>
            """,
            baseURL: URL(string: "https://auth.openai.com/log-in/password")!)
        let automation = ChatGPTAutomation(sessionManager: WebSessionManager())

        let result = try await automation.fillAndSubmit(
            selectors: ["input[type='password']"], value: "fixture-password",
            context: .authentication, in: session,
            expectedPageURL: session.webView.url, expectedEmail: "owner@example.com")

        #expect(result == .submitted)
        #expect(try await session.evaluate("document.body.dataset.submitted || null") as? String == "primary")
        #expect(try await session.evaluate("document.querySelector('input').value") as? String == "fixture-password")
    }

    @Test(arguments: ["bare", "checkbox", "pressed"])
    func passwordLoginRejectsUnclassifiedBarePasswordVisibilityToggle(variant: String) async throws {
        let toggleAttributes = variant == "checkbox" ? "role='checkbox' aria-checked='false'" :
            variant == "pressed" ? "aria-pressed='false'" : ""
        let session = try await fixtureSession(
            """
            <h1>Введите ваш пароль</h1><p>owner@example.com</p>
            <form>
              <input type="password" autocomplete="current-password">
              <button id="toggle" aria-label="Показать пароль" \(toggleAttributes)
                      style="width:44px;height:24px"></button>
              <button id="otp" type="submit">Вход с одноразовым кодом</button>
              <button id="primary" type="submit">Продолжить</button>
            </form>
            <script>
              document.querySelector('#toggle').addEventListener('click', event => {
                event.preventDefault(); document.body.dataset.toggleClicked = 'yes';
              });
              document.querySelector('form').addEventListener('submit', event => {
                event.preventDefault(); document.body.dataset.submitted = event.submitter.id;
              });
            </script>
            """,
            baseURL: URL(string: "https://auth.openai.com/log-in/password")!)
        let automation = ChatGPTAutomation(sessionManager: WebSessionManager())

        let result = try await automation.fillAndSubmit(
            selectors: ["input[type='password']"], value: "fixture-password",
            context: .authentication, in: session,
            expectedPageURL: session.webView.url, expectedEmail: "owner@example.com")

        #expect(result == .ambiguous)
        #expect(try await session.evaluate("document.body.dataset.submitted || null") is NSNull)
        #expect(try await session.evaluate("document.body.dataset.toggleClicked || null") is NSNull)
        #expect(try await session.evaluate("document.querySelector('input').value") as? String == "")
    }

    @Test(arguments: [
        "duplicatePrimary", "wrongRecipient", "multipleRecipients", "unknownAlternative",
        "wrongFormOrigin", "wrongSubmitOrigin", "wrongFormOwner", "wrongPath", "wrongHost",
        "nonPasswordSelectors",
    ])
    func passwordLoginAlternativeDoesNotWeakenSafety(variant: String) async throws {
        let email = variant == "wrongRecipient" ? "other@example.com" :
            variant == "multipleRecipients" ? "owner@example.com other@example.com" : "owner@example.com"
        let alternate = variant == "unknownAlternative" ? "Other action" : "Вход с одноразовым кодом"
        let duplicate = variant == "duplicatePrimary" ? "<button>Continue</button>" : ""
        let action = variant == "wrongFormOrigin" ? "action='https://example.com/password'" : ""
        let submitAction = variant == "wrongSubmitOrigin" ? "formaction='https://example.com/password'" : ""
        let formOwner = variant == "wrongFormOwner" ? "form='other'" : ""
        let otherForm = variant == "wrongFormOwner" ? "<form id='other'></form>" : ""
        let page = variant == "wrongPath" ? "https://auth.openai.com/log-in" :
            variant == "wrongHost" ? "https://chatgpt.com/log-in/password" : "https://auth.openai.com/log-in/password"
        let session = try await fixtureSession(
            """
            <p>\(email)</p>
            <form \(action)>
              <input type="password">
              <button \(submitAction) \(formOwner)>Продолжить</button>
              <button>\(alternate)</button>\(duplicate)
            </form>\(otherForm)
            <script>
              for (const button of document.querySelectorAll('button')) {
                button.addEventListener('click', event => {
                  event.preventDefault(); document.body.dataset.clicked = 'yes';
                });
              }
            </script>
            """,
            baseURL: URL(string: page)!)
        let automation = ChatGPTAutomation(sessionManager: WebSessionManager())

        let result = try await automation.fillAndSubmit(
            selectors: variant == "nonPasswordSelectors" ? ["input"] : ["input[type='password']"],
            value: "fixture-password", context: .authentication, in: session,
            expectedPageURL: session.webView.url, expectedEmail: "owner@example.com")

        #expect(result == .ambiguous)
        #expect(try await session.evaluate("document.body.dataset.clicked || null") is NSNull)
        #expect(try await session.evaluate("document.querySelector('input').value") as? String == "")
    }

    @Test func authenticationOTPRecognizesCurrentOpenAICodeField() async throws {
        let session = try await fixtureSession(
            """
            <html><body>
              <form id="mfa">
                <label>Одноразовый код
                  <input name="code" inputmode="numeric">
                </label>
                <button type="submit">Продолжить</button>
              </form>
              <script>
                document.querySelector('#mfa').addEventListener('submit', event => {
                  event.preventDefault();
                  document.body.dataset.submitted = event.target.id;
                });
              </script>
            </body></html>
            """,
            baseURL: URL(string: "https://auth.openai.com/mfa-challenge/test")!)
        let automation = ChatGPTAutomation(sessionManager: WebSessionManager())

        let result = try await automation.submitAuthenticationOTP(
            value: "123456",
            in: session)

        #expect(result == .submitted)
        let submitted = try await session.evaluate("document.body.dataset.submitted || null")
        #expect(submitted as? String == "mfa")
    }

    @Test func authenticationFormFindsPasswordInsideClosedShadowDOM() async throws {
        let session = try await fixtureSession(
            """
            <html><body>
              <div id="host"></div>
              <script>
                const root = document.querySelector('#host').attachShadow({ mode: 'closed' });
                root.innerHTML = `
                  <form id="login">
                    <input type="password">
                    <button type="submit">Продолжить</button>
                  </form>`;
                root.querySelector('form').addEventListener('submit', event => {
                  event.preventDefault();
                  document.body.dataset.submitted = event.target.id;
                });
              </script>
            </body></html>
            """,
            baseURL: URL(string: "https://auth.openai.com/log-in/password")!)
        let automation = ChatGPTAutomation(sessionManager: WebSessionManager())

        let result = try await automation.fillAndSubmit(
            selectors: ["input[type='password']"],
            value: "secret",
            context: .authentication,
            in: session)

        #expect(result == .submitted)
        let submitted = try await session.evaluate("document.body.dataset.submitted || null")
        #expect(submitted as? String == "login")
    }

    @Test func mfaChallengeAllowsItsSingleVisibleFormFieldWithoutKnownAttributes() async throws {
        let session = try await fixtureSession(
            """
            <html><body>
              <form id="mfa">
                <label>Одноразовый код<input type="text"></label>
                <button type="submit">Продолжить</button>
              </form>
              <script>
                document.querySelector('#mfa').addEventListener('submit', event => {
                  event.preventDefault();
                  document.body.dataset.submitted = event.target.id;
                });
              </script>
            </body></html>
            """,
            baseURL: URL(string: "https://auth.openai.com/mfa-challenge/test")!)
        let automation = ChatGPTAutomation(sessionManager: WebSessionManager())

        let result = try await automation.submitAuthenticationOTP(
            value: "123456",
            in: session)

        #expect(result == .submitted)
        let submitted = try await session.evaluate("document.body.dataset.submitted || null")
        #expect(submitted as? String == "mfa")
    }

    @Test func mfaChallengeSubmitsFieldWhenReactDoesNotUseAFormElement() async throws {
        let session = try await fixtureSession(
            """
            <html><body>
              <main>
                <label>Одноразовый код<input type="text"></label>
                <button id="continue">Продолжить</button>
              </main>
              <script>
                document.querySelector('#continue').addEventListener('click', () => {
                  document.body.dataset.clicked = 'continue';
                });
              </script>
            </body></html>
            """,
            baseURL: URL(string: "https://auth.openai.com/mfa-challenge/test")!)
        let automation = ChatGPTAutomation(sessionManager: WebSessionManager())

        let result = try await automation.submitAuthenticationOTP(
            value: "123456",
            in: session)

        #expect(result == .submitted)
        let clicked = try await session.evaluate("document.body.dataset.clicked || null")
        #expect(clicked as? String == "continue")
    }

    @Test func mfaChallengeUsesNativeFormSubmissionWhenThePageHasNoVisibleContinueButton() async throws {
        let session = try await fixtureSession(
            """
            <html><body>
              <form id="mfa">
                <label>Одноразовый код<input type="text"></label>
              </form>
              <script>
                const form = document.querySelector('#mfa');
                form.addEventListener('submit', event => {
                  event.preventDefault();
                  document.body.dataset.submitted = event.target.id;
                });
              </script>
            </body></html>
            """,
            baseURL: URL(string: "https://auth.openai.com/mfa-challenge/test")!)
        let automation = ChatGPTAutomation(sessionManager: WebSessionManager())

        let result = try await automation.submitAuthenticationOTP(
            value: "123456",
            in: session)

        #expect(result == .submitted)
        let submitted = try await session.evaluate("document.body.dataset.submitted || null")
        #expect(submitted as? String == "mfa")
    }

    @Test func mfaChallengeFindsFieldInsideOpenShadowDOM() async throws {
        let session = try await fixtureSession(
            """
            <html><body>
              <div id="host"></div>
              <script>
                const root = document.querySelector('#host').attachShadow({ mode: 'open' });
                root.innerHTML = `
                  <label>Одноразовый код<input type="text"></label>
                  <button id="continue">Продолжить</button>`;
                root.querySelector('#continue').addEventListener('click', () => {
                  document.body.dataset.clicked = 'continue';
                });
              </script>
            </body></html>
            """,
            baseURL: URL(string: "https://auth.openai.com/mfa-challenge/test")!)
        let automation = ChatGPTAutomation(sessionManager: WebSessionManager())

        let result = try await automation.submitAuthenticationOTP(
            value: "123456",
            in: session)

        #expect(result == .submitted)
        let clicked = try await session.evaluate("document.body.dataset.clicked || null")
        #expect(clicked as? String == "continue")
    }

    @Test func mfaChallengeFindsFieldInsideClosedShadowDOM() async throws {
        let session = try await fixtureSession(
            """
            <html><body>
              <div id="host"></div>
              <script>
                const root = document.querySelector('#host').attachShadow({ mode: 'closed' });
                root.innerHTML = `
                  <label>Одноразовый код<input type="text"></label>
                  <button id="continue">Продолжить</button>`;
                root.querySelector('#continue').addEventListener('click', () => {
                  document.body.dataset.clicked = 'continue';
                });
              </script>
            </body></html>
            """,
            baseURL: URL(string: "https://auth.openai.com/mfa-challenge/test")!)
        let automation = ChatGPTAutomation(sessionManager: WebSessionManager())

        let result = try await automation.submitAuthenticationOTP(
            value: "123456",
            in: session)

        #expect(result == .submitted)
        let clicked = try await session.evaluate("document.body.dataset.clicked || null")
        #expect(clicked as? String == "continue")
    }

    @Test func mfaChallengeSubmitsInsideTrustedChildFrameHiddenFromParentDOM() async throws {
        let session = try await fixtureSession(
            """
            <html><body>
              <iframe id="challenge" style="width:400px;height:200px"
                srcdoc="&lt;label&gt;Одноразовый код&lt;input type='text'&gt;&lt;/label&gt;&lt;button id='continue'&gt;Продолжить&lt;/button&gt;&lt;script&gt;document.querySelector('#continue').addEventListener('click', () =&gt; parent.postMessage('mfa-child-submitted', '*'));&lt;/script&gt;">
              </iframe>
              <script>
                window.addEventListener('message', event => {
                  if (event.data === 'mfa-child-submitted') {
                    document.body.dataset.clicked = 'child';
                  }
                });
                Object.defineProperty(document.querySelector('#challenge'), 'contentDocument', {
                  get: () => null
                });
              </script>
            </body></html>
            """,
            baseURL: URL(string: "https://auth.openai.com/mfa-challenge/test")!)
        let automation = ChatGPTAutomation(sessionManager: WebSessionManager())

        let result = try await automation.submitAuthenticationOTP(
            value: "123456",
            in: session)

        #expect(result == .submitted)
        try await Task.sleep(for: .milliseconds(100))
        let clicked = try await session.evaluate("document.body.dataset.clicked || null")
        #expect(clicked as? String == "child")
    }

    @Test func multipleDistinctAuthenticatorQRSecretsAreRejected() async throws {
        let session = try await fixtureSession("""
        <html><body>
          <a href="otpauth://totp/OpenAI:one?secret=JBSWY3DPEHPK3PXP">one</a>
          <a href="otpauth://totp/OpenAI:two?secret=KRUGS4ZANFZSAYJA">two</a>
        </body></html>
        """)

        let extracted: String?
        do {
            extracted = try await QRCodeSecretExtractor.extract(from: session.webView)
        } catch {
            extracted = nil
        }

        #expect(extracted == nil)
    }

    @Test func recoveryProbeNeverFillsCredentialsOnAnAuthenticationPage() async throws {
        let automation = ChatGPTAutomation(sessionManager: WebSessionManager())
        let account = AccountRecord(credential: .init(
            email: "owner@example.com",
            password: "private-password",
            totpSecret: "JBSWY3DPEHPK3PXP"))
        let session = automation.twoFARotationSession(for: account)
        session.webView.navigationDelegate = nil
        session.webView.loadHTMLString(
            """
            <form id="password"><input type="password"><button>Continue</button></form>
            <form id="otp"><input name="code"><button>Continue</button></form>
            """,
            baseURL: URL(string: "https://auth.openai.com/log-in/password")!)
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while session.webView.isLoading, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }

        var recovering = account
        recovering.rotationStage = .removingOldMethod
        let result = await automation.probeRecoverySession(account: recovering, in: session)

        guard case .manual = result else {
            Issue.record("An authentication page must require manual recovery")
            return
        }
        #expect(try await session.evaluate("document.querySelector('input[type=password]').value") as? String == "")
        #expect(try await session.evaluate("document.querySelector('input[name=code]').value") as? String == "")
    }

    @Test func recoveryProbeRejectsAStagedAccountWithoutItsOriginalSession() async {
        let automation = ChatGPTAutomation(sessionManager: WebSessionManager())
        var recovering = AccountRecord(credential: .init(
            email: "owner@example.com",
            password: "private-password",
            totpSecret: "JBSWY3DPEHPK3PXP"))
        recovering.rotationStage = .oldMethodDisabled
        let session = automation.twoFARotationSession(for: recovering)

        let result = await automation.probeRecoverySession(account: recovering, in: session)

        guard case .manual = result else {
            Issue.record("A newly created session cannot prove staged recovery")
            return
        }
        #expect(session.webView.url == nil)
    }

    @Test func pendingSetupWithoutOriginalSessionDoesNotNavigateOrSubmit() async {
        let automation = ChatGPTAutomation(sessionManager: WebSessionManager())
        var recovering = AccountRecord(credential: .init(
            email: "owner@example.com",
            password: "private-password",
            totpSecret: "JBSWY3DPEHPK3PXP"))
        recovering.pendingTOTPSecret = "KRUGS4ZANFZSAYJA"
        recovering.rotationStage = .pendingSecretCaptured
        var checkpoints: [RotationCheckpointEvent] = []

        let outcome = await automation.rotate2FA(account: recovering) {
            checkpoints.append($0)
        }

        guard case .manualActionRequired(let stage, _) = outcome else {
            Issue.record("A missing original session must stop pending setup")
            return
        }
        #expect(stage == .pendingSecretCaptured)
        #expect(checkpoints.isEmpty)
        #expect(automation.browserSession(for: recovering)?.webView.url == nil)
    }

    @Test func trustedPageCanReloadButBlankSessionCannot() async throws {
        let blank = BrowserSession(dataStore: .nonPersistent())
        #expect(blank.reloadTrustedPage() == nil)

        let trusted = try await fixtureSession(
            "<main id='marker'>Security</main>",
            baseURL: URL(string: "https://chatgpt.com/#settings/Security")!)
        #expect(trusted.reloadTrustedPage() != nil)
    }


    @Test func manualFactorRecoverySubmitsPasswordButNeverOldTOTP() async throws {
        let session = try await fixtureSession(
            """
            <form id="password">
              <input type="password">
              <button type="submit">Continue</button>
            </form>
            <form id="mfa" hidden>
              <input name="code" autocomplete="one-time-code">
              <button type="submit">Continue</button>
            </form>
            <script>
              document.querySelector('#password').addEventListener('submit', event => {
                event.preventDefault();
                document.body.dataset.passwordSubmitted = 'yes';
                document.querySelector('#password').hidden = true;
                document.querySelector('#mfa').hidden = false;
              });
            </script>
            """,
            baseURL: URL(string: "https://auth.openai.com/log-in/password")!)
        session.setVisible(true)
        let account = AccountRecord(credential: .init(
            email: "owner@example.com",
            password: "pw",
            totpSecret: "JBSWY3DPEHPK3PXP"))
        let automation = ChatGPTAutomation(sessionManager: WebSessionManager())

        let result = await automation.signIn(
            account: account,
            secret: account.totpSecret,
            in: session,
            automaticallySubmitOTP: false,
            loginTimeoutSeconds: 6)

        guard case .manual = result else {
            Issue.record("Manual-factor recovery must stop at the MFA field")
            return
        }
        #expect(try await session.evaluate(
            "document.querySelector('[name=code]').value") as? String == "")
        #expect(try await session.evaluate(
            "document.body.dataset.passwordSubmitted") as? String == "yes")
    }

    @Test func blankAuthenticationPageReturnsAtTheConfiguredDeadline() async throws {
        let session = try await fixtureSession(
            "<main>Loading</main>",
            baseURL: URL(string: "https://auth.openai.com/api/accounts/authorize")!)
        session.setVisible(true)
        let account = AccountRecord(credential: .init(
            email: "owner@example.com",
            password: "pw",
            totpSecret: "JBSWY3DPEHPK3PXP"))
        let automation = ChatGPTAutomation(sessionManager: WebSessionManager())

        let result = await automation.signIn(
            account: account,
            secret: account.totpSecret,
            in: session,
            loginTimeoutSeconds: 0)

        guard case .manual = result else {
            Issue.record("Blank login must return manual state at its deadline")
            return
        }
    }

    @Test func missingAuthenticatorControlReturnsAtTheConfiguredDeadline() async throws {
        let session = try await fixtureSession("<main>Security is still loading</main>")
        let automation = ChatGPTAutomation(sessionManager: WebSessionManager())

        #expect(!(await automation.openSecuritySettings(in: session, seconds: 0)))
    }

    @Test func candidateIdentityMustMatchTheSelectedAccount() {
        #expect(ChatGPTAutomation.recoveryCandidateMatches(
            signedInEmail: "Owner@Example.com",
            accountEmail: "owner@example.com"))
        #expect(!ChatGPTAutomation.recoveryCandidateMatches(
            signedInEmail: "other@example.com",
            accountEmail: "owner@example.com"))
    }


    @Test(arguments: [RotationStage.removingOldMethod, .oldMethodDisabled, .pendingSecretCaptured])
    func candidateLoginNeverSubmitsAnAutomaticFactor(stage: RotationStage) async throws {
        let candidate = try await fixtureSession(
            "<form><input name='code' autocomplete='one-time-code'><button>Continue</button></form>",
            baseURL: URL(string: "https://auth.openai.com/mfa-challenge/test")!)
        let original = BrowserSession(dataStore: .nonPersistent())
        let automation = ChatGPTAutomation(sessionManager: WebSessionManager(
            accountSessionFactory: { _ in original }, verificationSessionFactory: { candidate }))
        var account = AccountRecord(credential: .init(
            email: "owner@example.com", password: "pw", totpSecret: "JBSWY3DPEHPK3PXP"))
        automation.prepareBrowserSession(for: account)
        account.rotationStage = stage
        account.pendingTOTPSecret = stage == .pendingSecretCaptured ? "KRUGS4ZANFZSAYJA" : nil
        _ = await automation.startFreshLogin(for: account, context: .rotation(stage: stage))
        let outcome = await automation.rotate2FA(account: account) { _ in
            Issue.record("Unverified candidate must not change a checkpoint")
        }
        guard case .manualActionRequired = outcome else { Issue.record("Expected manual factor"); return }
        #expect(try await candidate.evaluate("document.querySelector('input').value") as? String == "")
        #expect(automation.hasCandidateSession(for: account.id))
        automation.returnToOriginalSession(for: account)
        #expect(automation.browserSession(for: account) === original)
    }

    @Test(arguments: ["Owner@Example.com", "other@example.com"], [false, true])
    func candidateHandoverRequiresAuthenticatedMatchingIdentity(email: String, cancelled: Bool) async throws {
        let candidate = try await fixtureSession("""
            <section><span>Authenticator app</span>
            <button role="switch" aria-label="Authenticator app" aria-checked="true"
                    style="width:44px;height:24px"></button></section>
            <script>window.fetch = async () => ({ ok: true, json: async () => ({ user: { email: "\(email)" } }) });</script>
            """)
        let original = BrowserSession(dataStore: .nonPersistent())
        let automation = ChatGPTAutomation(sessionManager: WebSessionManager(
            accountSessionFactory: { _ in original }, verificationSessionFactory: { candidate }))
        var account = AccountRecord(credential: .init(
            email: "owner@example.com", password: "pw", totpSecret: "JBSWY3DPEHPK3PXP"))
        automation.prepareBrowserSession(for: account)
        account.rotationStage = .oldMethodDisabled
        _ = await automation.startFreshLogin(for: account, context: .rotation(stage: .oldMethodDisabled))
        if cancelled { automation.cancelActiveOperation() }
        _ = await automation.rotate2FA(account: account) { _ in
            Issue.record("Inconsistent enabled state must not change the checkpoint")
        }
        if email == "Owner@Example.com" && !cancelled {
            #expect(!automation.hasCandidateSession(for: account.id))
            #expect(automation.twoFARotationSession(for: account) === candidate)
        } else {
            #expect(automation.hasCandidateSession(for: account.id))
            #expect(automation.twoFARotationSession(for: account) === original)
        }
        #expect(account.rotationStage == .oldMethodDisabled)
        #expect(account.totpSecret == "JBSWY3DPEHPK3PXP")
    }

}
