import AppKit
import Foundation
import Testing
@testable import GPTAccountManager

@MainActor
@Suite(.serialized)
struct RegistrationFormTests {
    private func fixture(_ html: String, url: String = "https://auth.openai.com/create-account") async throws -> BrowserSession {
        _ = NSApplication.shared
        let session = BrowserSession(dataStore: .nonPersistent())
        session.webView.frame = NSRect(x: 0, y: 0, width: 390, height: 844)
        session.webView.navigationDelegate = nil
        session.webView.loadHTMLString(html, baseURL: URL(string: url))
        for _ in 0..<60 where session.webView.isLoading { try await Task.sleep(for: .milliseconds(50)) }
        return session
    }

    private func emailForm(primary: String = "<button>Continue</button>") -> String {
        """
        <form onsubmit="event.preventDefault();document.body.dataset.submits=String(Number(document.body.dataset.submits||0)+1)">
          <button type="button" onclick="document.body.dataset.switched='google'">Continue with Google</button>
          <button type="button" onclick="document.body.dataset.switched='apple'">Continue with Apple</button>
          <button type="button" onclick="document.body.dataset.switched='phone'">Continue with phone</button>
          <label>Email address <input type="email"></label>\(primary)
        </form>
        """
    }

    @Test func emailUsesOnlyPrimaryContinueOnce() async throws {
        let session = try await fixture(emailForm(), url: "https://chatgpt.com/auth/login")
        #expect(try await RegistrationForm.inspect(in: session).kind == .email)
        #expect(try await RegistrationForm.submitEmail("new@example.com", in: session))
        #expect(try await session.evaluate("document.body.dataset.submits") as? String == "1")
        #expect(try await session.evaluate("document.body.dataset.switched === undefined") as? Bool == true)
        for primary in ["", "<button>Continue</button><button>Next</button>"] {
            let missing = try await fixture(emailForm(primary: primary))
            #expect(try await !RegistrationForm.submitEmail("new@example.com", in: missing))
            #expect(try await missing.evaluate("document.querySelector('input').value") as? String == "")
            #expect(try await missing.evaluate("document.body.dataset.switched === undefined") as? Bool == true)
        }
    }

    @Test func rememberedLoginChoosesExactAccountCardNotRemovalControl() async throws {
        let session = try await fixture("""
        <h2>С возвращением!</h2>
        <button onclick="document.body.dataset.selected='correct'">Fixture Person\nnew@example.com</button>
        <button onclick="document.body.dataset.selected='wrong'">Other Person\nother@example.com</button>
        <button aria-label="Удалить учетную запись" onclick="document.body.dataset.deleted='yes'">new@example.com</button>
        """, url: "https://chatgpt.com/")
        #expect(try await RegistrationForm.selectRememberedAccount("new@example.com", in: session))
        #expect(try await session.evaluate("document.body.dataset.selected") as? String == "correct")
        #expect(try await session.evaluate("document.body.dataset.deleted === undefined") as? Bool == true)
        #expect(try await !RegistrationForm.selectRememberedAccount("missing@example.com", in: session))
    }

    private func codeForm(destination: String, extra: String = "") -> String {
        """
        <main><h1>Check your email</h1><p>We sent a code to \(destination)</p>
        <form onsubmit="event.preventDefault();document.body.dataset.submits='1'">
          <label>Verification code <input name="code" autocomplete="one-time-code"></label>
          <button>Continue</button>\(extra)
        </form></main>
        """
    }

    @Test func emailCodeRequiresExactVisibleDestinationAndEmailRoute() async throws {
        for destination in ["wrong@example.com", "", "<span hidden>new@example.com</span>", "new@example.com other@example.com"] {
            let session = try await fixture(codeForm(destination: destination), url: "https://auth.openai.com/email-verification")
            #expect(try await !RegistrationForm.submitEmailCode("123456", expectedEmail: "new@example.com", in: session))
            #expect(try await session.evaluate("document.querySelector('input').value") as? String == "")
        }
        let session = try await fixture(codeForm(destination: "new@example.com"), url: "https://auth.openai.com/email-verification")
        #expect(try await RegistrationForm.inspect(in: session).displayedEmail == "new@example.com")
        #expect(try await RegistrationForm.submitEmailCode("123456", expectedEmail: "new@example.com", in: session))
        #expect(try await session.evaluate("document.body.dataset.submits") as? String == "1")
        for url in ["https://auth.openai.com/mfa-challenge/fixture", "https://auth.openai.com/add-phone"] {
            let phone = try await fixture(codeForm(destination: "new@example.com"), url: url)
            #expect(try await !RegistrationForm.submitEmailCode("123456", expectedEmail: "new@example.com", in: phone))
        }
    }

    @Test func passwordIsSetOnlyOnCreationRoute() async throws {
        let html = "<form onsubmit=\"event.preventDefault();document.body.dataset.sent='yes'\"><input type='password'><button>Continue</button></form>"
        let create = try await fixture(html, url: "https://auth.openai.com/create-account/password")
        #expect(try await RegistrationForm.inspect(in: create).isCreatingPassword)
        #expect(try await RegistrationForm.submitPassword("generated-test-password", in: create))
        let login = try await fixture(html, url: "https://auth.openai.com/log-in/password")
        #expect(try await !RegistrationForm.inspect(in: login).isCreatingPassword)
        #expect(try await !RegistrationForm.submitPassword("generated-test-password", in: login))
        #expect(try await login.evaluate("document.querySelector('input').value") as? String == "")
        for target in ["https://auth.openai.com/log-in/password", "https://example.com/create-account/password", "/create-account/password"] {
            let session = try await fixture("<a href='\(target)' onclick=\"event.preventDefault();document.body.dataset.clicked='yes'\">Continue with password</a>", url: "https://auth.openai.com/email-verification")
            #expect(try await RegistrationForm.selectPasswordSignup(in: session) == (target == "/create-account/password"))
        }
    }

    @Test func observedRussianEntryAndSiblingCodeDestinationAreSupported() async throws {
        let entry = try await fixture("<button onclick=\"document.body.dataset.clicked='yes'\">Зарегистрироваться бесплатно</button>", url: "https://chatgpt.com/")
        #expect(try await RegistrationForm.clickSignUp(in: entry))
        let html = codeForm(destination: "new@example.com").replacingOccurrences(of: "main", with: "section")
        let code = try await fixture(html, url: "https://auth.openai.com/email-verification")
        #expect(try await RegistrationForm.submitEmailCode("123456", expectedEmail: "new@example.com", in: code))
        let outside = try await fixture("<p>new@example.com</p><section><form><input name='code'><button>Continue</button></form></section>", url: "https://auth.openai.com/email-verification")
        #expect(try await !RegistrationForm.submitEmailCode("123456", expectedEmail: "new@example.com", in: outside))
    }

    @Test(arguments: ["Отправить код", "Submit code"])
    func emailVerificationSubmitCodeLabelExcludesResendAndKeepsPasswordChoice(label: String) async throws {
        let html = codeForm(destination: "new@example.com", extra: """
        <button type="button" onclick="document.body.dataset.resent='yes'">Отправить электронное письмо повторно</button>
        <a href="/create-account/password" onclick="event.preventDefault();document.body.dataset.passwordChosen='yes'">Продолжить с паролем</a>
        """).replacingOccurrences(of: ">Continue<", with: ">\(label)<")
        let session = try await fixture(html, url: "https://auth.openai.com/email-verification")
        let state = try await RegistrationForm.inspect(in: session)
        #expect(state.kind == .emailCode && state.displayedEmail == "new@example.com")
        #expect(try await RegistrationForm.selectPasswordSignup(in: session))
        #expect(try await session.evaluate("document.body.dataset.passwordChosen") as? String == "yes")
        #expect(try await RegistrationForm.submitEmailCode("123456", expectedEmail: "new@example.com", in: session))
        #expect(try await session.evaluate("document.body.dataset.submits") as? String == "1")
        #expect(try await session.evaluate("document.body.dataset.resent === undefined") as? Bool == true)
    }

    @Test func cleanLoginNeverUsesTOTPForAnEmailChallenge() async throws {
        let session = try await fixture(codeForm(destination: "new@example.com"), url: "https://auth.openai.com/email-verification")
        let account = AccountRecord(credential: .init(email: "new@example.com", password: "fixture-password", totpSecret: "JBSWY3DPEHPK3PXP"))
        let browser = ChatGPTAutomation(sessionManager: WebSessionManager())
        let result = await browser.signIn(account: account, secret: account.totpSecret, in: session,
                                          initialProof: .init(passwordSubmitted: true, pendingOTPSubmitted: false),
                                          requireExplicitProof: true, loginTimeoutSeconds: 2)
        guard case .manual(_, let proof) = result else { Issue.record("Email challenge must pause"); return }
        #expect(!proof.pendingOTPSubmitted)
        #expect(try await session.evaluate("document.querySelector('input').value") as? String == "")
        let choice = try await fixture("<a href='/log-in/password' onclick=\"event.preventDefault();document.body.dataset.chosen='yes'\">Continue with password</a>", url: "https://auth.openai.com/email-verification")
        #expect(try await RegistrationForm.selectPasswordLogin(in: choice))
        #expect(try await choice.evaluate("document.body.dataset.chosen") as? String == "yes")
    }

    @Test func cleanLoginEmailHandlerDoesNotCountAsAuthenticatorProof() async throws {
        let session = try await fixture(codeForm(destination: "new@example.com"), url: "https://auth.openai.com/email-verification")
        let account = AccountRecord(credential: .init(email: "new@example.com", password: "fixture-password", totpSecret: "JBSWY3DPEHPK3PXP"))
        let browser = ChatGPTAutomation(sessionManager: WebSessionManager())
        var calls = 0
        let result = await browser.signIn(account: account, secret: account.totpSecret, in: session,
                                          initialProof: .init(passwordSubmitted: true, pendingOTPSubmitted: false),
                                          requireExplicitProof: true, loginTimeoutSeconds: 1,
                                          emailCodeHandler: { page in
            calls += 1
            guard calls == 1 else { return false }
            return try await RegistrationForm.submitEmailCode("123456", expectedEmail: account.email, in: page)
        })
        guard case .manual(_, let proof) = result else { Issue.record("Unproven login must pause"); return }
        #expect(calls >= 1)
        #expect(!proof.pendingOTPSubmitted)
        #expect(try await session.evaluate("document.querySelector('input').value") as? String == "123456")
    }

    @Test func freshVerificationCannotInheritAnotherSessionsMFAChallenge() async throws {
        let original = try await fixture("<form><input name='code' autocomplete='one-time-code'><button>Continue</button></form>", url: "https://auth.openai.com/mfa-challenge/fixture")
        let browser = ChatGPTAutomation(sessionManager: WebSessionManager())
        let account = AccountRecord(credential: .init(email: "new@example.com", password: "fixture-password", totpSecret: "JBSWY3DPEHPK3PXP"))
        let passwordProof = CleanLoginProof(passwordSubmitted: true, pendingOTPSubmitted: false)
        let paused = await browser.signIn(account: account, secret: account.totpSecret, in: original,
                                         initialProof: passwordProof, requireExplicitProof: true,
                                         automaticallySubmitOTP: false, loginTimeoutSeconds: 1)
        guard case .manual = paused else { Issue.record("MFA fixture must pause"); return }
        let authenticatedHTML = "<script>window.fetch=async()=>({ok:true,json:async()=>({user:{email:'new@example.com'}})});</script>"
        let replacement = try await fixture(authenticatedHTML, url: "https://chatgpt.com/")
        let newResult = await browser.signIn(account: account, secret: account.totpSecret, in: replacement,
                                            initialProof: passwordProof, requireExplicitProof: true, loginTimeoutSeconds: 1)
        guard case .restart = newResult else { Issue.record("Fresh session inherited stale challenge proof"); return }

        original.webView.loadHTMLString(authenticatedHTML, baseURL: URL(string: "https://chatgpt.com/"))
        for _ in 0..<60 where original.webView.isLoading { try await Task.sleep(for: .milliseconds(50)) }
        let continued = await browser.signIn(account: account, secret: account.totpSecret, in: original,
                                            initialProof: passwordProof, requireExplicitProof: true, loginTimeoutSeconds: 1)
        guard case .success(_, let proof) = continued else { Issue.record("Same-session manual continuation lost challenge proof"); return }
        #expect(proof.isSufficient)
    }

    @Test func profileRequiresNameAndAgeRatherThanBirthdayGuess() async throws {
        let profile = """
        <form onsubmit="event.preventDefault();document.body.dataset.sent='yes'">
          <label>Full name <input name="name"></label><label>Age <input name="age" type="number"></label>
          <button>Continue</button></form>
        """
        let session = try await fixture(profile, url: "https://auth.openai.com/about-you")
        #expect(try await RegistrationForm.inspect(in: session).kind == .profile)
        #expect(try await RegistrationForm.submitProfile(fullName: "Alex Green", age: 28, in: session))
        #expect(try await session.evaluate("document.querySelector('[name=age]').value") as? String == "28")
        for invalid in [profile.replacingOccurrences(of: "Age", with: "Birth year"), profile.replacingOccurrences(of: "</form>", with: "<input name='month'></form>")] {
            let bad = try await fixture(invalid, url: "https://auth.openai.com/about-you")
            #expect(try await !RegistrationForm.submitProfile(fullName: "Alex Green", age: 28, in: bad))
            #expect(try await bad.evaluate("document.body.dataset.sent === undefined") as? Bool == true)
        }
    }

    @Test(arguments: ["Завершить регистрацию", "Complete registration", "Finish registration"])
    func profileRecognizesRegistrationCompletionButton(label: String) async throws {
        let session = try await fixture("""
        <form onsubmit="event.preventDefault();document.body.dataset.sent='yes'">
          <label>Полное имя <input name="name"></label><label>Возраст <input name="age" type="number"></label>
          <button>\(label)</button></form>
        """, url: "https://auth.openai.com/about-you")
        #expect(try await RegistrationForm.inspect(in: session).kind == .profile)
        #expect(try await RegistrationForm.submitProfile(fullName: "Alex Green", age: 28, in: session))
        #expect(try await session.evaluate("document.body.dataset.sent") as? String == "yes")
    }

    @Test func profileCommitsFieldChangesBeforeSubmitting() async throws {
        let session = try await fixture("""
        <form onsubmit="event.preventDefault();window.submittedName=window.committedName;window.submittedAge=window.committedAge">
          <input name="name" onblur="window.committedName=this.value">
          <input name="age" type="number" onblur="window.committedAge=this.value">
          <button>Continue</button>
        </form>
        """, url: "https://auth.openai.com/about-you")
        #expect(try await RegistrationForm.submitProfile(fullName: "Alex Green", age: 28, in: session))
        #expect(try await session.evaluate("window.submittedName") as? String == "Alex Green")
        #expect(try await session.evaluate("window.submittedAge") as? String == "28")
    }

    @Test(arguments: ["email", "profile"])
    func ignoredContinueClickDoesNotCountAsFormSubmission(kind: String) async throws {
        let fields = kind == "email" ? "<input type='email'>" : "<input name='name'><input name='age' type='number'>"
        let session = try await fixture("""
        <script>window.ready=false;window.submissions=0;</script>
        <form onsubmit="event.preventDefault();window.submissions++">
          \(fields)<button onclick="if(!window.ready)event.preventDefault()">Continue</button>
        </form>
        """, url: kind == "email" ? "https://auth.openai.com/create-account" : "https://auth.openai.com/about-you")
        func submit() async throws -> Bool {
            if kind == "email" { return try await RegistrationForm.submitEmail("new@example.com", in: session) }
            return try await RegistrationForm.submitProfile(fullName: "Alex Green", age: 28, in: session)
        }
        #expect(try await !submit())
        #expect(try await session.evaluate("window.submissions") as? Int == 0)
        _ = try await session.evaluate("window.ready=true")
        #expect(try await submit())
        #expect(try await session.evaluate("window.submissions") as? Int == 1)
    }

    @Test(arguments: [
        "Мы не можем создать вашу учетную запись из-за наших условий использования",
        "We cannot create your account due to our terms of use."
    ])
    func explicitRegistrationRefusalNeverSubmitsAgain(message: String) async throws {
        let session = try await fixture("""
        <form onsubmit="event.preventDefault();document.body.dataset.submitted='1'">
          <input name="name"><input name="age" type="number"><button>Continue</button>
          <p role="alert">\(message)</p>
        </form>
        """, url: "https://auth.openai.com/about-you")
        #expect(try await RegistrationForm.inspect(in: session).text == "registrationRejected")
        #expect(try await !RegistrationForm.submitProfile(fullName: "Alex Green", age: 28, in: session))
        #expect(try await session.evaluate("document.body.dataset.submitted === undefined") as? Bool == true)
    }

    @Test(arguments: ["ready", "changed-name", "changed-age", "disabled", "cross-origin", "cancel", "save-failure"])
    func explicitProfileRetryKeepsValuesAndRequiresDurableCheckpoint(behavior: String) async throws {
        let session = try await fixture("""
        <form onsubmit="event.preventDefault();document.body.dataset.submitted='1'">
          <input name="name" value="\(behavior == "changed-name" ? "Other Person" : "Alex Green")">
          <input name="age" type="number" value="\(behavior == "changed-age" ? "30" : "28")">
          <button \(behavior == "disabled" ? "disabled" : "")
            \(behavior == "cross-origin" ? "formaction='https://other.example/'" : "")>Continue</button>
          <p>We cannot create your account due to our terms of use.</p>
        </form>
        """, url: "https://auth.openai.com/about-you")
        var checkpointed = false
        enum FixtureError: Error { case save }
        do {
            let submitted = try await RegistrationForm.retryRejectedProfile(fullName: "Alex Green", age: 28, in: session) {
                checkpointed = true
                if behavior == "save-failure" { throw FixtureError.save }
                if behavior == "cancel" { session.cancelLoading() }
            }
            #expect(submitted == (behavior == "ready"))
        } catch {
            #expect((behavior == "save-failure" && error is FixtureError) || (behavior == "cancel" && error is CancellationError))
        }
        #expect(checkpointed == ["ready", "cancel", "save-failure"].contains(behavior))
        #expect(try await session.evaluate("document.body.dataset.submitted === '1'") as? Bool == (behavior == "ready"))
        #expect(try await session.evaluate("document.querySelector('[name=name]').value") as? String == (behavior == "changed-name" ? "Other Person" : "Alex Green"))
        #expect(try await session.evaluate("document.querySelector('[name=age]').value") as? String == (behavior == "changed-age" ? "30" : "28"))
    }

    @Test func challengeAndUntrustedOriginStayUntouched() async throws {
        let challenge = try await fixture("<h1>Verify you are human</h1>" + emailForm())
        #expect(try await RegistrationForm.inspect(in: challenge).kind == .challenge)
        #expect(try await !RegistrationForm.submitEmail("new@example.com", in: challenge))
        let outside = try await fixture(emailForm(), url: "https://example.com/create-account")
        do { _ = try await RegistrationForm.submitEmail("new@example.com", in: outside); Issue.record("Untrusted submission") }
        catch BrowserSessionError.untrustedOrigin {}
    }

    @Test func authenticatedStateRequiresSessionIdentityRatherThanComposer() async throws {
        for authenticated in [false, true] {
            let session = try await fixture("""
            <main>What can I help with?<textarea placeholder="Message ChatGPT"></textarea></main>
            <script>window.fetch=async()=>({ok:true,json:async()=>\(authenticated ? "({user:{email:'new@example.com'}})" : "({})")});</script>
            """, url: "https://chatgpt.com/")
            let state = try await RegistrationForm.inspect(in: session)
            #expect((state.kind == .authenticated) == authenticated)
            #expect(state.displayedEmail == (authenticated ? "new@example.com" : nil))
        }
    }

    @Test func routeOrRecipientChangeWhileWaitingPreventsSubmission() async throws {
        let html = codeForm(destination: "new@example.com")
            .replacingOccurrences(of: "name=\"code\"", with: "name=\"code\" oninput=\"document.querySelector('p').textContent='Sent to wrong@example.com';document.querySelector('button').disabled=false\"")
            .replacingOccurrences(of: "<button>", with: "<button disabled>")
        let session = try await fixture(html, url: "https://auth.openai.com/email-verification")
        #expect(try await !RegistrationForm.submitEmailCode("123456", expectedEmail: "new@example.com", in: session))
        #expect(try await session.evaluate("document.body.dataset.submits === undefined") as? Bool == true)
    }

    @Test func enrollmentNeverSubmitsBeforeSecretPersistence() async throws {
        let session = try await fixture("""
        <button role="switch" aria-label="Authenticator app" aria-checked="false">Authenticator app</button>
        <div role="dialog"><h2>Connect your authenticator app</h2><code>JBSWY3DPEHPK3PXP</code>
          <form onsubmit="event.preventDefault();document.body.dataset.sent='yes'">
            <input autocomplete="one-time-code"><button>Continue</button>
          </form>
        </div>
        """, url: "https://chatgpt.com/settings/security")
        let browser = ChatGPTAutomation(sessionManager: WebSessionManager())
        var checkpoint = false
        let result = await browser.enrollNewAuthenticator(in: session, pendingSecret: nil) { secret in
            checkpoint = true
            #expect(secret == "JBSWY3DPEHPK3PXP")
            throw FixtureError.persistence
        }
        #expect(checkpoint)
        guard case .failure = result else { Issue.record("Missing persistence must fail"); return }
        #expect(try await session.evaluate("document.querySelector('input').value") as? String == "")
        #expect(try await session.evaluate("document.body.dataset.sent === undefined") as? Bool == true)
    }

    @Test func alreadyEnabledFactorRequiresSavedPendingSecret() async throws {
        let session = try await fixture("<button role='switch' aria-label='Authenticator app' aria-checked='true'>Authenticator app</button>", url: "https://chatgpt.com/settings/security")
        let browser = ChatGPTAutomation(sessionManager: WebSessionManager())
        let missing = await browser.enrollNewAuthenticator(in: session, pendingSecret: nil) { _ in Issue.record("Unexpected checkpoint") }
        guard case .manual = missing else { Issue.record("Unrecorded factor must be manual"); return }
        let known = await browser.enrollNewAuthenticator(in: session, pendingSecret: "JBSWY3DPEHPK3PXP") { _ in Issue.record("Unexpected checkpoint") }
        #expect(known == .enabled(secret: "JBSWY3DPEHPK3PXP"))
    }

    @Test func automaticCleanLoginSubmitsEachUnchangedStageOnlyOnce() async throws {
        let account = AccountRecord(credential: .init(email: "new@example.com", password: "fixture-password", totpSecret: "JBSWY3DPEHPK3PXP"))
        for (route, field) in [("/log-in", "type='email'"), ("/log-in/password", "type='password'"),
                               ("/mfa-challenge/fixture", "name='code' autocomplete='one-time-code'")] {
            let session = try await fixture("""
            <form onsubmit="event.preventDefault();document.body.dataset.submits=String(Number(document.body.dataset.submits||0)+1);setTimeout(()=>document.querySelector('p').textContent='Still loading',100)">
              <input \(field)><button>Continue</button><p>Loading</p>
            </form>
            """, url: "https://auth.openai.com" + route)
            let browser = ChatGPTAutomation(sessionManager: WebSessionManager())
            let result = await browser.signIn(account: account, secret: account.totpSecret, in: session,
                                              initialProof: .init(passwordSubmitted: route.contains("mfa-challenge"), pendingOTPSubmitted: false),
                                              requireExplicitProof: true, immediateAuthenticationWaitSeconds: 0,
                                              loginTimeoutSeconds: 2, automaticallyWaitForTransitions: true)
            guard case .manual = result else { Issue.record("Unchanged login stage must time out"); return }
            #expect(try await session.evaluate("document.body.dataset.submits") as? String == "1")
        }
    }

    @Test func automaticCleanLoginResumesAfterHumanChallengeAndDelayedOTP() async throws {
        let account = AccountRecord(credential: .init(email: "new@example.com", password: "fixture-password", totpSecret: "JBSWY3DPEHPK3PXP"))
        let session = try await fixture("""
        <h1>Verify you are human</h1>
        <form onsubmit="event.preventDefault();document.body.dataset.submits=String(Number(document.body.dataset.submits||0)+1)">
          <input name='code' autocomplete='one-time-code'><button>Continue</button>
        </form>
        """, url: "https://auth.openai.com/mfa-challenge/fixture")
        let browser = ChatGPTAutomation(sessionManager: WebSessionManager())
        let completion = Task { @MainActor in
            try await Task.sleep(for: .milliseconds(300))
            #expect(try await session.evaluate("document.body.dataset.submits === undefined") as? Bool == true)
            _ = try await session.evaluate("document.querySelector('h1').remove()")
            for _ in 0..<80 {
                if try await session.evaluate("document.body.dataset.submits") as? String == "1" { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            try await Task.sleep(for: .milliseconds(1200))
            #expect(try await session.evaluate("document.body.dataset.submits") as? String == "1")
            session.webView.loadHTMLString("<script>window.fetch=async()=>({ok:true,json:async()=>({user:{email:'new@example.com'}})});</script>",
                                           baseURL: URL(string: "https://chatgpt.com/"))
        }
        let result = await browser.signIn(account: account, secret: account.totpSecret, in: session,
                                          initialProof: .init(passwordSubmitted: true, pendingOTPSubmitted: false),
                                          requireExplicitProof: true, immediateAuthenticationWaitSeconds: 0,
                                          loginTimeoutSeconds: 12, automaticallyWaitForTransitions: true,
                                          humanChallengeTimeoutSeconds: 2)
        try await completion.value
        guard case .success(_, let proof) = result else { Issue.record("Delayed automatic login must finish"); return }
        #expect(proof.isSufficient)
    }

    @Test func automaticCleanLoginRenewsIdleDeadlineAfterSlowEmailCode() async throws {
        let session = try await fixture(codeForm(destination: "new@example.com"), url: "https://auth.openai.com/email-verification")
        let account = AccountRecord(credential: .init(email: "new@example.com", password: "fixture-password", totpSecret: "JBSWY3DPEHPK3PXP"))
        let browser = ChatGPTAutomation(sessionManager: WebSessionManager())
        var calls = 0
        let result = await browser.signIn(account: account, secret: account.totpSecret, in: session,
                                          requireExplicitProof: true, loginTimeoutSeconds: 1,
                                          automaticallyWaitForTransitions: true, emailCodeHandler: { page in
            calls += 1
            try await Task.sleep(for: .milliseconds(1300))
            page.webView.loadHTMLString("<form onsubmit=\"event.preventDefault();document.body.dataset.sent='yes'\"><input type='password'><button>Continue</button></form>",
                                       baseURL: URL(string: "https://auth.openai.com/log-in/password"))
            return true
        })
        guard case .manual(_, let proof) = result else { Issue.record("Password fixture must remain unauthenticated"); return }
        #expect(proof.passwordSubmitted)
        #expect(calls == 1)
        #expect(try await session.evaluate("document.body.dataset.sent") as? String == "yes")
    }

    @Test func automaticEnrollmentKeepsPendingKeyWithoutRestartingSetup() async throws {
        let session = try await fixture("""
        <button role='switch' aria-label='Authenticator app' aria-checked='false'
          onclick="document.body.dataset.restarted='yes'">Authenticator app</button>
        <script>setTimeout(()=>document.querySelector('button').setAttribute('aria-checked','true'),500)</script>
        """, url: "https://chatgpt.com/settings/security")
        let browser = ChatGPTAutomation(sessionManager: WebSessionManager())
        let result = await browser.enrollNewAuthenticator(in: session, pendingSecret: "JBSWY3DPEHPK3PXP",
                                                          automaticallyWaitForTransitions: true, transitionTimeoutSeconds: 3) { _ in
            Issue.record("Saved pending key must remain unchanged")
        }
        #expect(result == .enabled(secret: "JBSWY3DPEHPK3PXP"))
        #expect(try await session.evaluate("document.body.dataset.restarted === undefined") as? Bool == true)
    }

    @Test(arguments: ["ru", "en"], ["SMS", "text messages"])
    func automaticEnrollmentSkipsOptionalSMSBackupAndVerifiesEnabledSwitch(language: String, method: String) async throws {
        let heading = language == "ru" ? "Приложение для аутентификации добавлено" : "Authenticator app added"
        let skip = language == "ru" ? "Не сейчас" : "Not now"
        let session = try await fixture("""
        <script>window.skips=0;</script>
        <section><h1>\(heading)</h1><p>Now, set up \(method) as a backup MFA method.</p>
          <button type="button" onclick="document.body.dataset.backup='yes'">Add backup method</button>
          <button type="button" onclick="window.skips++;this.closest('section').remove();document.querySelector('[role=switch]').hidden=false">\(skip)</button>
        </section>
        <button hidden role="switch" aria-label="Authenticator app" aria-checked="true">Authenticator app</button>
        """, url: "https://chatgpt.com/settings/security")
        let browser = ChatGPTAutomation(sessionManager: WebSessionManager())
        let result = await browser.enrollNewAuthenticator(in: session, pendingSecret: "JBSWY3DPEHPK3PXP",
                                                          automaticallyWaitForTransitions: true, transitionTimeoutSeconds: 3) { _ in
            Issue.record("Saved key must not change")
        }
        #expect(result == .enabled(secret: "JBSWY3DPEHPK3PXP"))
        #expect(try await session.evaluate("window.skips") as? Int == 1)
        #expect(try await session.evaluate("document.body.dataset.backup === undefined") as? Bool == true)
    }

    @Test func optionalSMSBackupIsNotProofThatAuthenticatorEnabled() async throws {
        let session = try await fixture("""
        <script>window.skips=0;</script>
        <section><h1>Приложение для аутентификации добавлено</h1><p>Теперь настройте SMS как резервный способ.</p>
          <button type="button" onclick="window.skips++">Не сейчас</button>
        </section>
        """, url: "https://chatgpt.com/settings/security")
        let browser = ChatGPTAutomation(sessionManager: WebSessionManager())
        let result = await browser.enrollNewAuthenticator(in: session, pendingSecret: "JBSWY3DPEHPK3PXP",
                                                          automaticallyWaitForTransitions: true, transitionTimeoutSeconds: 2) { _ in
            Issue.record("Saved key must not change")
        }
        if case .enabled = result { Issue.record("Backup prompt alone must not certify enabled 2FA") }
        #expect(try await session.evaluate("window.skips") as? Int == 1)
    }

    @Test func optionalSMSBackupRequiresKnownVisibleContextAndSafeTarget() async throws {
        let prompt = """
        <section><h1>Приложение для аутентификации добавлено</h1><p>Настройте SMS как резервный способ.</p>
          <button type="button" onclick="document.body.dataset.skipped='yes'">Не сейчас</button>
        </section>
        """
        let browser = ChatGPTAutomation(sessionManager: WebSessionManager())
        let invalid = [
            prompt.replacingOccurrences(of: "Приложение для аутентификации добавлено", with: "Отключить аутентификацию"),
            prompt.replacingOccurrences(of: "<h1>", with: "<h1 hidden>"),
            prompt.replacingOccurrences(of: "Настройте SMS как резервный способ.", with: "Настройки профиля"),
            prompt.replacingOccurrences(of: "</section>", with: "<button>Не сейчас</button></section>"),
            prompt.replacingOccurrences(of: "type=\"button\"", with: "type=\"button\" formaction=\"https://other.example/\""),
            "<form action='https://other.example/'>" + prompt + "</form>",
        ]
        for html in invalid {
            let session = try await fixture(html, url: "https://chatgpt.com/settings/security")
            #expect(try await browser.dismissOptionalAuthenticatorBackup(in: session) != .clicked)
            #expect(try await session.evaluate("document.body.dataset.skipped === undefined") as? Bool == true)
        }
        let outside = try await fixture(prompt, url: "https://auth.openai.com/mfa-challenge/fixture")
        #expect(try await browser.dismissOptionalAuthenticatorBackup(in: outside) == .notFound)
        let form = try await fixture("<form onsubmit='event.preventDefault()'>" + prompt
            .replacingOccurrences(of: "type=\"button\"", with: "type=\"submit\"") + "</form>",
                                    url: "https://chatgpt.com/settings/security")
        #expect(try await browser.dismissOptionalAuthenticatorBackup(in: form) == .clicked)
    }

    @Test func optionalBackupPromptCanUseWholeBodyButNeverUnrelatedSkipButton() async throws {
        let prompt = """
        <h1>Authenticator app added</h1>
        <p>Now, set up text messages as a backup MFA method.</p>
        <button onclick="document.body.dataset.skips=String(Number(document.body.dataset.skips||0)+1)">Not now</button>
        """
        let browser = ChatGPTAutomation(sessionManager: WebSessionManager())
        let direct = try await fixture(prompt, url: "https://chatgpt.com/settings/security")
        #expect(try await browser.dismissOptionalAuthenticatorBackup(in: direct) == .clicked)
        #expect(try await direct.evaluate("document.body.dataset.skips") as? String == "1")
        let unrelated = try await fixture("<section><h1>Authenticator app added</h1><p>Set up SMS as a backup method.</p></section><section><h2>Different action</h2><button onclick=\"document.body.dataset.clicked='yes'\">Not now</button></section>", url: "https://chatgpt.com/settings/security")
        #expect(try await browser.dismissOptionalAuthenticatorBackup(in: unrelated) != .clicked)
        #expect(try await unrelated.evaluate("document.body.dataset.clicked === undefined") as? Bool == true)
    }

    @Test func automaticEnrollmentRejectsReplacementSecretBeforeSubmission() async throws {
        let session = try await fixture("""
        <div role='dialog'><h2>Connect your authenticator app</h2><code>JBSWY3DPEHPK3PXP</code>
          <form onsubmit="event.preventDefault();document.body.dataset.sent='yes'">
            <input autocomplete='one-time-code'><button>Continue</button>
          </form></div>
        """, url: "https://chatgpt.com/settings/security")
        let browser = ChatGPTAutomation(sessionManager: WebSessionManager())
        let result = await browser.enrollNewAuthenticator(in: session, pendingSecret: "KRSXG5DSNFXGOIDB",
                                                          automaticallyWaitForTransitions: true) { _ in
            Issue.record("Different key must not overwrite saved key")
        }
        guard case .failure = result else { Issue.record("Replacement secret must fail"); return }
        #expect(try await session.evaluate("document.querySelector('input').value") as? String == "")
        #expect(try await session.evaluate("document.body.dataset.sent === undefined") as? Bool == true)
    }

    @Test func automaticEnrollmentWaitsForDelayedConfirmationWithoutResubmitting() async throws {
        let session = try await fixture("""
        <button role='switch' aria-label='Authenticator app' aria-checked='false'>Authenticator app</button>
        <div role='dialog'><h2>Connect your authenticator app</h2><code>JBSWY3DPEHPK3PXP</code>
          <form onsubmit="event.preventDefault();document.body.dataset.submits=String(Number(document.body.dataset.submits||0)+1);setTimeout(()=>{document.querySelector('[role=dialog]').remove();document.querySelector('[role=switch]').setAttribute('aria-checked','true')},1500)">
            <input autocomplete='one-time-code'><button>Continue</button>
          </form></div>
        """, url: "https://chatgpt.com/settings/security")
        let browser = ChatGPTAutomation(sessionManager: WebSessionManager())
        var checkpoints = 0
        let result = await browser.enrollNewAuthenticator(in: session, pendingSecret: nil,
                                                          automaticallyWaitForTransitions: true, transitionTimeoutSeconds: 5) { _ in
            checkpoints += 1
        }
        #expect(result == .enabled(secret: "JBSWY3DPEHPK3PXP"))
        #expect(checkpoints == 1)
        #expect(try await session.evaluate("document.body.dataset.submits") as? String == "1")
    }

    @Test func automaticHumanWaitStopsWhenBrowserIsCancelled() async throws {
        let session = try await fixture("<h1>Verify you are human</h1>", url: "https://chatgpt.com/settings/security")
        let browser = ChatGPTAutomation(sessionManager: WebSessionManager())
        let cancellation = Task { @MainActor in
            try await Task.sleep(for: .milliseconds(300))
            session.cancelLoading()
        }
        let result = await browser.enrollNewAuthenticator(in: session, pendingSecret: nil,
                                                          automaticallyWaitForTransitions: true) { _ in
            Issue.record("Challenge must remain untouched")
        }
        try await cancellation.value
        guard case .failure = result else { Issue.record("Cancelled human wait must stop"); return }
    }

    @Test func automaticCleanLoginReturnsFromPasswordChoiceToEmailCodeOnce() async throws {
        let session = try await fixture("<a href='/log-in/password' onclick=\"event.preventDefault();document.body.dataset.chosen='yes'\">Continue with password</a>",
                                        url: "https://auth.openai.com/email-verification")
        let account = AccountRecord(credential: .init(email: "new@example.com", password: "fixture-password", totpSecret: "JBSWY3DPEHPK3PXP"))
        let browser = ChatGPTAutomation(sessionManager: WebSessionManager())
        let navigation = Task { @MainActor in
            for _ in 0..<50 {
                if try await session.evaluate("document.body.dataset.chosen") as? String == "yes" { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            session.webView.loadHTMLString("<form onsubmit=\"event.preventDefault();document.body.dataset.passwordSent='yes'\"><input type='password'><button>Continue</button></form>",
                                           baseURL: URL(string: "https://auth.openai.com/log-in/password"))
            for _ in 0..<50 {
                if try await session.evaluate("document.body.dataset.passwordSent") as? String == "yes" { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            session.webView.loadHTMLString(codeForm(destination: account.email), baseURL: URL(string: "https://auth.openai.com/email-verification"))
        }
        var calls = 0
        let result = await browser.signIn(account: account, secret: account.totpSecret, in: session,
                                          requireExplicitProof: true, loginTimeoutSeconds: 3,
                                          automaticallyWaitForTransitions: true, emailCodeHandler: { page in
            calls += 1
            return try await RegistrationForm.submitEmailCode("123456", expectedEmail: account.email, in: page)
        })
        try await navigation.value
        guard case .manual(_, let proof) = result else { Issue.record("Email fixture must remain unauthenticated"); return }
        #expect(proof.passwordSubmitted)
        #expect(calls == 1)
        #expect(try await session.evaluate("document.body.dataset.submits") as? String == "1")
    }

    @Test func automaticCleanLoginWaitsForEmailFormHydration() async throws {
        let form = codeForm(destination: "new@example.com")
        let encodedForm = String(decoding: try JSONEncoder().encode(form), as: UTF8.self)
        let session = try await fixture("<main>Loading</main><script>setTimeout(()=>document.body.innerHTML=\(encodedForm),900)</script>",
                                        url: "https://auth.openai.com/email-verification")
        let account = AccountRecord(credential: .init(email: "new@example.com", password: "fixture-password", totpSecret: "JBSWY3DPEHPK3PXP"))
        let browser = ChatGPTAutomation(sessionManager: WebSessionManager())
        var calls = 0
        let result = await browser.signIn(account: account, secret: account.totpSecret, in: session,
                                          initialProof: .init(passwordSubmitted: true, pendingOTPSubmitted: false),
                                          requireExplicitProof: true, loginTimeoutSeconds: 2,
                                          automaticallyWaitForTransitions: true, emailCodeHandler: { page in
            calls += 1
            return try await RegistrationForm.submitEmailCode("123456", expectedEmail: account.email, in: page)
        })
        guard case .manual = result else { Issue.record("Email fixture must remain unauthenticated"); return }
        #expect(calls == 1)
        #expect(try await session.evaluate("document.body.dataset.submits") as? String == "1")
    }

    @Test func automaticCleanLoginWaitsForDelayedMFAField() async throws {
        let form = "<form onsubmit=\"event.preventDefault();document.body.dataset.submits=String(Number(document.body.dataset.submits||0)+1)\"><input name='code' autocomplete='one-time-code'><button>Continue</button></form>"
        let encodedForm = String(decoding: try JSONEncoder().encode(form), as: UTF8.self)
        let session = try await fixture("<main>Loading</main><script>setTimeout(()=>document.body.innerHTML=\(encodedForm),3000)</script>",
                                        url: "https://auth.openai.com/mfa-challenge/fixture")
        let account = AccountRecord(credential: .init(email: "new@example.com", password: "fixture-password", totpSecret: "JBSWY3DPEHPK3PXP"))
        let browser = ChatGPTAutomation(sessionManager: WebSessionManager())
        let result = await browser.signIn(account: account, secret: account.totpSecret, in: session,
                                          initialProof: .init(passwordSubmitted: true, pendingOTPSubmitted: false),
                                          requireExplicitProof: true, loginTimeoutSeconds: 6,
                                          automaticallyWaitForTransitions: true)
        guard case .manual(_, let proof) = result else { Issue.record("MFA fixture must remain unauthenticated"); return }
        #expect(proof.pendingOTPSubmitted)
        #expect(try await session.evaluate("document.body.dataset.submits") as? String == "1")
    }

    @Test func automaticEnrollmentWaitsForQRCodeBeyondFirstCaptureTimeout() async throws {
        let session = try await fixture("""
        <button role='switch' aria-label='Authenticator app' aria-checked='false'
          onclick="document.body.dataset.restarted='yes'">Authenticator app</button>
        <div role='dialog'><h2>Connect your authenticator app</h2><code></code>
          <form onsubmit="event.preventDefault();document.body.dataset.submits=String(Number(document.body.dataset.submits||0)+1);document.querySelector('[role=dialog]').remove();document.querySelector('[role=switch]').setAttribute('aria-checked','true')">
            <input autocomplete='one-time-code'><button>Continue</button>
          </form></div>
        <script>setTimeout(()=>document.querySelector('code').textContent='JBSWY3DPEHPK3PXP',11500)</script>
        """, url: "https://chatgpt.com/settings/security")
        let browser = ChatGPTAutomation(sessionManager: WebSessionManager())
        var checkpoints = 0
        let result = await browser.enrollNewAuthenticator(in: session, pendingSecret: nil,
                                                          automaticallyWaitForTransitions: true, transitionTimeoutSeconds: 20) { _ in
            checkpoints += 1
        }
        #expect(result == .enabled(secret: "JBSWY3DPEHPK3PXP"))
        #expect(checkpoints == 1)
        #expect(try await session.evaluate("document.body.dataset.submits") as? String == "1")
        #expect(try await session.evaluate("document.body.dataset.restarted === undefined") as? Bool == true)
    }

    private enum FixtureError: Error { case persistence }
}
