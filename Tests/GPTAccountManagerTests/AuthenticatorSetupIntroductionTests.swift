import AppKit
import Foundation
import Testing
import WebKit
@testable import GPTAccountManager

@MainActor
@Suite(.serialized)
struct AuthenticatorSetupIntroductionTests {
    private let introduction = """
    Вам понадобится приложение для аутентификации или менеджер паролей, который генерирует коды подтверждения.
    Используйте приложение, которое у вас уже есть, или скачайте одно из следующих:
    """

    private let qrInstructions = "Скопируйте ключ настройки и вставьте его в приложение для аутентификации или отсканируйте QR-код с помощью этого приложения"
    private let codeInstructions = "Чтобы завершить настройку, введите 6-значный код из приложения для аутентификации"

    private func codeStep(
        body: String? = nil, extra: String = "", buttonAttributes: String = "disabled",
        fieldAttributes: String = "oninput=\"setTimeout(()=>document.getElementById('code-continue').disabled=false,60)\""
    ) -> String {
        """
        <section role="dialog" id="code-dialog">
          <h2>Введите код</h2><p>\(body ?? codeInstructions)</p>
          <form id="code-form" onsubmit="event.preventDefault();document.body.dataset.codeSubmits=String(Number(document.body.dataset.codeSubmits||0)+1)">
            <label for="authenticator-code">Код</label>
            <input id="authenticator-code" type="text" inputmode="numeric" placeholder="000000"
                   pattern="[0-9]{6}" required \(fieldAttributes)>
            \(extra)
            <button type="submit" id="code-continue" \(buttonAttributes)>Продолжить</button>
          </form>
        </section>
        """
    }

    private func qrStep(keyAttributes: String = "aria-pressed='false'", extra: String = "", body: String? = nil,
                        onKeySelect: String = "", onContinue: String = "") -> String {
        """
        <section role="dialog">
          <h2>Добавьте свою учетную запись в приложение</h2>
          <p>\(body ?? qrInstructions)</p>
          <div aria-label="Способ настройки">
            <button type="button" id="key-tab" \(keyAttributes)
                    onclick="this.setAttribute('aria-pressed','true');document.getElementById('qr-tab').setAttribute('aria-pressed','false');document.body.dataset.keySelected=String(Number(document.body.dataset.keySelected||0)+1);\(onKeySelect)">Ключ</button>
            <button type="button" id="qr-tab" aria-pressed="true">QR-код</button>
          </div>
          \(extra)
          <button type="button" id="qr-continue" onclick="event.preventDefault();document.body.dataset.qrContinued=String(Number(document.body.dataset.qrContinued||0)+1);\(onContinue)">Продолжить</button>
        </section>
        """
    }

    private func intro(
        heading: String = "Настройка приложения для аутентификации",
        dialogAttributes: String = "",
        buttonAttributes: String = "",
        extra: String = "",
        body: String? = nil,
        onContinue: String = "document.body.dataset.continued=String(Number(document.body.dataset.continued||0)+1)"
    ) -> String {
        """
        <section role="dialog" \(dialogAttributes)>
          <button type="button" aria-label="Закрыть диалог"
                  onclick="document.body.dataset.closed='yes'">×</button>
          <h2>\(heading)</h2>
          <p>\(body ?? introduction)</p>
          <a href="https://external.example/apple" onclick="event.preventDefault();document.body.dataset.installed='yes'">“Пароли” от Apple</a>
          <a href="https://external.example/google" onclick="event.preventDefault();document.body.dataset.installed='yes'">Google Authenticator</a>
          <a href="https://external.example/microsoft" onclick="event.preventDefault();document.body.dataset.installed='yes'">Microsoft Authenticator</a>
          \(extra)
          <button id="intro-continue" type="button" \(buttonAttributes)
                  onclick="event.preventDefault();\(onContinue)">Продолжить</button>
        </section>
        """
    }

    private func fixture(_ html: String, address: String = "https://chatgpt.com/settings/security") async throws -> BrowserSession {
        _ = NSApplication.shared
        let session = BrowserSession(dataStore: .nonPersistent()) { configuration in
            WKWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 700), configuration: configuration)
        }
        session.webView.navigationDelegate = nil
        session.webView.loadHTMLString("<html><body>\(html)</body></html>", baseURL: URL(string: address))
        for _ in 0..<100 where session.webView.isLoading { try await Task.sleep(for: .milliseconds(30)) }
        try #require(!session.webView.isLoading)
        return session
    }

    private func untouched(_ session: BrowserSession) async throws -> Bool {
        try await session.evaluate("document.body.dataset.continued === undefined && document.body.dataset.installed === undefined && document.body.dataset.closed === undefined") as? Bool == true
    }

    @Test func observedIntroductionAdvancesOnlyItsContinueButton() async throws {
        let session = try await fixture(intro() + "<button onclick=\"document.body.dataset.outside='yes'\">Продолжить</button>")

        #expect(try await AuthenticatorSetupIntroduction.advance(in: session, click: false) == .found)
        #expect(try await untouched(session))
        #expect(try await AuthenticatorSetupIntroduction.advance(in: session) == .clicked)
        #expect(try await session.evaluate("document.body.dataset.continued") as? String == "1")
        #expect(try await session.evaluate("document.body.dataset.installed === undefined && document.body.dataset.closed === undefined && document.body.dataset.outside === undefined") as? Bool == true)
    }

    @Test(arguments: ["hidden", "aria-hidden='true'", "inert", "style='opacity:0'", "style='display:none'"])
    func hiddenIntroductionIsIgnored(attributes: String) async throws {
        let session = try await fixture(intro(dialogAttributes: attributes))
        #expect(try await AuthenticatorSetupIntroduction.advance(in: session) == .notFound)
        #expect(try await untouched(session))
    }

    @Test func duplicateIntroductionsAndContinueButtonsFailClosed() async throws {
        for html in [intro() + intro(), intro(extra: "<button>Продолжить</button>")] {
            let session = try await fixture(html)
            #expect(try await AuthenticatorSetupIntroduction.advance(in: session) == .ambiguous)
            #expect(try await untouched(session))
        }
    }

    @Test(arguments: ["disabled", "aria-disabled='true'", "hidden"])
    func introductionWaitsForContinueToBecomeReady(attributes: String) async throws {
        let session = try await fixture(intro(buttonAttributes: attributes))
        #expect(try await AuthenticatorSetupIntroduction.advance(in: session) == .found)
        #expect(try await untouched(session))
        _ = try await session.evaluate("(() => { const button=document.getElementById('intro-continue');button.disabled=false;button.hidden=false;button.removeAttribute('aria-disabled');return true; })()")
        #expect(try await AuthenticatorSetupIntroduction.advance(in: session) == .clicked)
    }

    @Test func missingContinueWaitsWithoutChoosingInstallOrCloseControls() async throws {
        let session = try await fixture(intro())
        _ = try await session.evaluate("(() => { document.getElementById('intro-continue').remove();return true; })()")
        #expect(try await AuthenticatorSetupIntroduction.advance(in: session) == .found)
        #expect(try await untouched(session))
    }

    @Test(arguments: ["<input name='otp'>", "<input type='password'>", "<input type='email'>", "<textarea></textarea>", "<select><option>Choose</option></select>", "<div contenteditable='true'>Code</div>"])
    func anInputScreenIsNotAnIntroduction(field: String) async throws {
        let session = try await fixture(intro(extra: field))
        #expect(try await AuthenticatorSetupIntroduction.advance(in: session) == .notFound)
        #expect(try await untouched(session))
    }

    @Test func externalFormOrContinueDestinationIsNeverActivated() async throws {
        let externalForm = "<form id='external' action='https://external.example/submit' onsubmit=\"event.preventDefault();document.body.dataset.external='yes'\"></form>"
        for attributes in ["href='https://external.example/continue'", "formaction='https://external.example/submit'", "form='external'"] {
            let session = try await fixture(externalForm + intro(buttonAttributes: attributes))
            #expect(try await AuthenticatorSetupIntroduction.advance(in: session) == .ambiguous)
            #expect(try await untouched(session))
            #expect(try await session.evaluate("document.body.dataset.external === undefined") as? Bool == true)
        }
    }

    @Test func unrelatedHeadingOrBodyNeverActivatesContinue() async throws {
        for html in [intro(heading: "Настройка пароля"), intro(body: "Подтвердите изменение способов входа.")] {
            let session = try await fixture(html)
            #expect(try await AuthenticatorSetupIntroduction.advance(in: session) == .notFound)
            #expect(try await untouched(session))
        }
    }

    @Test(arguments: ["https://chatgpt.com/", "https://auth.openai.com/email-verification", "https://external.example/settings/security", "https://chatgpt.com/settings/security-unrelated"])
    func introductionRequiresTheExactTrustedSecurityRoute(address: String) async throws {
        let session = try await fixture(intro(), address: address)
        #expect(try await AuthenticatorSetupIntroduction.advance(in: session) == .notFound)
        #expect(try await session.webView.evaluateJavaScript("document.body.dataset.continued === undefined") as? Bool == true)
    }

    @Test func cancellationPreventsContinue() async throws {
        let session = try await fixture(intro())
        let task = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await AuthenticatorSetupIntroduction.advance(in: session)
        }
        do {
            _ = try await task.value
            Issue.record("Cancelled introduction advanced")
        } catch is CancellationError {}
        #expect(try await untouched(session))
    }

    @Test(arguments: [false, true])
    func automaticEnrollmentContinuesOnceAndPersistsBeforeSubmittingCode(persistenceFails: Bool) async throws {
        enum FixtureError: Error { case persistence }
        let secret = "JBSWY3DPEHPK3PXP"
        let html = """
        <button role="switch" aria-label="Authenticator app" aria-checked="false"
                onclick="document.body.dataset.restarted='yes'">Authenticator app</button>
        \(intro(onContinue: "document.body.dataset.continued=String(Number(document.body.dataset.continued||0)+1);this.closest('[role=dialog]').remove();document.getElementById('setup').hidden=false"))
        <section role="dialog" id="setup" hidden>
          <h2>Connect your authenticator app</h2><code>\(secret)</code>
          <form onsubmit="event.preventDefault();document.body.dataset.submits=String(Number(document.body.dataset.submits||0)+1);this.closest('[role=dialog]').hidden=true;document.querySelector('[role=switch]').setAttribute('aria-checked','true')">
            <input autocomplete="one-time-code"><button type="submit">Continue</button>
          </form>
        </section>
        """
        let session = try await fixture(html)
        let automation = ChatGPTAutomation(sessionManager: WebSessionManager())
        var checkpoints = 0
        var savedSecret: String?

        let result = await automation.enrollNewAuthenticator(
            in: session, pendingSecret: nil, automaticallyWaitForTransitions: true,
            transitionTimeoutSeconds: 15, humanChallengeTimeoutSeconds: 0) { captured in
                checkpoints += 1
                if persistenceFails { throw FixtureError.persistence }
                savedSecret = captured
            }

        #expect(checkpoints == 1)
        #expect(try await session.evaluate("document.body.dataset.continued") as? String == "1")
        #expect(try await session.evaluate("document.body.dataset.restarted === undefined && document.body.dataset.installed === undefined && document.body.dataset.closed === undefined") as? Bool == true)
        if persistenceFails {
            guard case .failure = result else { Issue.record("Missing key persistence must stop enrollment"); return }
            #expect(savedSecret == nil)
            #expect(try await session.evaluate("document.querySelector('input').value === '' && document.body.dataset.submits === undefined") as? Bool == true)
        } else {
            #expect(savedSecret == secret)
            #expect(result == .enabled(secret: secret))
            #expect(try await session.evaluate("document.body.dataset.submits") as? String == "1")
        }
    }

    @Test func automaticEnrollmentNeverAdvancesIntroductionForASavedKey() async throws {
        let session = try await fixture(intro())
        let automation = ChatGPTAutomation(sessionManager: WebSessionManager())
        let result = await automation.enrollNewAuthenticator(
            in: session, pendingSecret: "JBSWY3DPEHPK3PXP", automaticallyWaitForTransitions: true,
            transitionTimeoutSeconds: 1, humanChallengeTimeoutSeconds: 0) { _ in
                Issue.record("Saved key must not be replaced")
            }
        guard case .manual = result else { Issue.record("Saved key requires manual recovery"); return }
        #expect(try await untouched(session))
    }

    @Test func automaticEnrollmentDoesNotReplayAnIntroductionThatRemainsVisible() async throws {
        let session = try await fixture(intro())
        let automation = ChatGPTAutomation(sessionManager: WebSessionManager())
        let result = await automation.enrollNewAuthenticator(
            in: session, pendingSecret: nil, automaticallyWaitForTransitions: true,
            transitionTimeoutSeconds: 1, humanChallengeTimeoutSeconds: 0) { _ in
                Issue.record("Introduction has no key to save")
            }
        guard case .manual = result else { Issue.record("Incomplete introduction must remain manual"); return }
        #expect(try await session.evaluate("document.body.dataset.continued") as? String == "1")
    }

    @Test(arguments: [false, true])
    func separateQRStepPersistsItsKeyBeforeContinuingWithoutAnOTPField(persistenceFails: Bool) async throws {
        enum FixtureError: Error { case persistence }
        let secret = "JBSWY3DPEHPK3PXP"
        let session = try await fixture("""
        <button role="switch" aria-label="Authenticator app" aria-checked="false"
                onclick="document.body.dataset.restarted='yes'">Authenticator app</button>
        \(intro(onContinue: "document.body.dataset.continued=String(Number(document.body.dataset.continued||0)+1);this.closest('[role=dialog]').remove();document.getElementById('qr-step').hidden=false"))
        <section role="dialog" id="qr-step" hidden>
          <h2>Добавьте свою учетную запись в приложение</h2>
          <p>\(qrInstructions)</p>
          <div aria-label="Способ настройки">
            <button type="button" aria-pressed="false"
                    onclick="this.setAttribute('aria-pressed','true');document.getElementById('plain-key').hidden=false">Ключ</button>
            <button type="button" aria-pressed="true">QR-код</button>
          </div>
          <code id="plain-key" hidden>\(secret)</code>
          <div data-uri="otpauth://totp/Fixture?secret=\(secret)"></div>
          <button type="button" onclick="document.body.dataset.qrContinued=String(Number(document.body.dataset.qrContinued||0)+1);this.closest('[role=dialog]').remove();document.body.insertAdjacentHTML('beforeend','<p>Unknown next fixture screen</p>')">Продолжить</button>
        </section>
        """)
        let automation = ChatGPTAutomation(sessionManager: WebSessionManager())
        var checkpoints = 0
        var savedSecret: String?

        let result = await automation.enrollNewAuthenticator(
            in: session, pendingSecret: nil, automaticallyWaitForTransitions: true,
            transitionTimeoutSeconds: 2, humanChallengeTimeoutSeconds: 0) { captured in
                checkpoints += 1
                if persistenceFails { throw FixtureError.persistence }
                savedSecret = captured
            }

        #expect(checkpoints == 1)
        #expect(try await session.evaluate("document.body.dataset.continued") as? String == "1")
        #expect(try await session.evaluate("document.body.dataset.restarted === undefined && document.querySelector('input') === null") as? Bool == true)
        if persistenceFails {
            guard case .failure = result else { Issue.record("Unsaved QR key must stop before Continue"); return }
            #expect(savedSecret == nil)
            #expect(try await session.evaluate("document.body.dataset.qrContinued === undefined") as? Bool == true)
        } else {
            guard case .manual = result else { Issue.record("Unknown next screen cannot certify enrollment"); return }
            #expect(savedSecret == secret)
            #expect(try await session.evaluate("document.body.dataset.qrContinued") as? String == "1")
        }
    }

    @Test func keyTabIsSelectedOnceWithoutCopyingOrAdvancing() async throws {
        let session = try await fixture(qrStep(extra: "<button onclick=\"document.body.dataset.copied='yes'\">Скопировать ключ настройки</button>"))
        #expect(try await AuthenticatorSetupIntroduction.selectKey(in: session, click: false) == .found)
        #expect(try await session.evaluate("document.body.dataset.keySelected === undefined") as? Bool == true)
        #expect(try await AuthenticatorSetupIntroduction.selectKey(in: session) == .clicked)
        #expect(try await AuthenticatorSetupIntroduction.selectKey(in: session) == .found)
        #expect(try await session.evaluate("document.body.dataset.keySelected") as? String == "1")
        #expect(try await session.evaluate("document.body.dataset.copied === undefined && document.body.dataset.qrContinued === undefined") as? Bool == true)
    }

    @Test(arguments: ["", "aria-pressed='mixed'", "aria-pressed='false' aria-selected='true'"])
    func unknownOrConflictingKeyToggleStateIsAmbiguous(attributes: String) async throws {
        let session = try await fixture(qrStep(keyAttributes: attributes))
        #expect(try await AuthenticatorSetupIntroduction.selectKey(in: session) == .ambiguous)
        #expect(try await session.evaluate("document.body.dataset.keySelected === undefined") as? Bool == true)
    }

    @Test(arguments: ["disabled aria-pressed='false'", "aria-disabled='true' aria-pressed='false'", "hidden aria-pressed='false'"])
    func keyTabWaitsUntilReady(attributes: String) async throws {
        let session = try await fixture(qrStep(keyAttributes: attributes))
        #expect(try await AuthenticatorSetupIntroduction.selectKey(in: session) == .found)
        #expect(try await session.evaluate("document.body.dataset.keySelected === undefined") as? Bool == true)
    }

    @Test func qrContinueUsesOnlyTheObservedInputFreeScreen() async throws {
        let session = try await fixture(qrStep())
        #expect(try await AuthenticatorSetupIntroduction.advanceQRCode(in: session, click: false) == .found)
        #expect(try await session.evaluate("document.body.dataset.qrContinued === undefined") as? Bool == true)
        #expect(try await AuthenticatorSetupIntroduction.advanceQRCode(in: session) == .clicked)
        #expect(try await session.evaluate("document.body.dataset.qrContinued") as? String == "1")
        #expect(try await session.evaluate("document.body.dataset.keySelected === undefined") as? Bool == true)
    }

    @Test func qrHelpersRejectWrongBodyInputsAndDuplicateControls() async throws {
        for html in [qrStep(body: "Неизвестная страница"), qrStep(extra: "<input autocomplete='one-time-code'>")] {
            let session = try await fixture(html)
            #expect(try await AuthenticatorSetupIntroduction.selectKey(in: session) == .notFound)
            #expect(try await AuthenticatorSetupIntroduction.advanceQRCode(in: session) == .notFound)
            #expect(try await session.evaluate("document.body.dataset.keySelected === undefined && document.body.dataset.qrContinued === undefined") as? Bool == true)
        }
        let key = try await fixture(qrStep(extra: "<button aria-pressed='false'>Ключ</button>"))
        #expect(try await AuthenticatorSetupIntroduction.selectKey(in: key) == .ambiguous)
        let button = try await fixture(qrStep(extra: "<button>Продолжить</button>"))
        #expect(try await AuthenticatorSetupIntroduction.advanceQRCode(in: button) == .ambiguous)
    }

    @Test func plainKeyComesOnlyFromTheObservedQRDialog() async throws {
        let secret = "JBSWY3DPEHPK3PXP"
        let session = try await fixture("<code>KRSXG5DSNFXGOIDB</code>" + qrStep(
            keyAttributes: "aria-pressed='true'", extra: "<code>\(secret)</code>"))
        let captured = try await QRCodeSecretExtractor.extract(from: session.webView)
        #expect(captured == secret)
        #expect(try await session.evaluate("document.body.dataset.keySelected === undefined && document.body.dataset.qrContinued === undefined") as? Bool == true)
    }

    @Test func totpCodeWaitsForHydrationAndSubmitsOnce() async throws {
        let session = try await fixture(codeStep(), address: "https://chatgpt.com/settings/security?action=enable&factor=totp")
        #expect(try await AuthenticatorSetupIntroduction.codeStep(in: session) == .found)
        #expect(try await session.evaluate("document.getElementById('authenticator-code').value === '' && document.body.dataset.codeSubmits === undefined") as? Bool == true)
        #expect(try await AuthenticatorSetupIntroduction.submitCode("123456", in: session) == .submitted)
        #expect(try await session.evaluate("document.getElementById('authenticator-code').value") as? String == "123456")
        #expect(try await session.evaluate("document.body.dataset.codeSubmits") as? String == "1")
    }

    @Test(arguments: ["factor=sms&action=enable", "factor=totp&action=disable", "action=enable", "action=enable&factor=totp&factor=sms", "action=enable&action=enable&factor=totp", "action=enable&factor=totp&Factor=sms"])
    func genericCodeHeadingNeverAdmitsAnotherOrAmbiguousFactor(query: String) async throws {
        let session = try await fixture(codeStep(), address: "https://chatgpt.com/settings/security?\(query)")
        #expect(try await AuthenticatorSetupIntroduction.codeStep(in: session) == .notFound)
        #expect(try await AuthenticatorSetupIntroduction.submitCode("123456", in: session) == .notFound)
        #expect(try await session.evaluate("document.getElementById('authenticator-code').value === '' && document.body.dataset.codeSubmits === undefined") as? Bool == true)
    }

    @Test func genericCodeHeadingNeedsKnownAuthenticatorContextAndOneField() async throws {
        for html in [codeStep(body: "Введите код из SMS"), codeStep(extra: "<input aria-label='Другой код'>"), codeStep(extra: "<button type='submit'>Продолжить</button>")] {
            let session = try await fixture(html, address: "https://chatgpt.com/settings/security?action=enable&factor=totp")
            #expect(try await AuthenticatorSetupIntroduction.submitCode("123456", in: session) != .submitted)
            #expect(try await session.evaluate("document.getElementById('authenticator-code').value === '' && document.body.dataset.codeSubmits === undefined") as? Bool == true)
        }
    }

    @Test(arguments: ["", "12345", "1234567", "12a456", " 123456", "１２３４５６"])
    func invalidCodeNeverTouchesTheForm(code: String) async throws {
        let session = try await fixture(codeStep(), address: "https://chatgpt.com/settings/security?action=enable&factor=totp")
        #expect(try await AuthenticatorSetupIntroduction.submitCode(code, in: session) == .notFound)
        #expect(try await session.evaluate("document.getElementById('authenticator-code').value === '' && document.body.dataset.codeSubmits === undefined") as? Bool == true)
    }

    @Test func changingFactorOrReplacingTheFormWhileWaitingNeverSubmits() async throws {
        for inputAction in [
            "setTimeout(()=>history.replaceState(null,'','?action=enable&factor=sms'),20)",
            "setTimeout(()=>{const old=document.getElementById('code-form');const replacement=old.cloneNode(true);old.replaceWith(replacement);replacement.querySelector('button').disabled=false},20)",
        ] {
            let session = try await fixture(codeStep(fieldAttributes: "oninput=\"\(inputAction)\""), address: "https://chatgpt.com/settings/security?action=enable&factor=totp")
            #expect(try await AuthenticatorSetupIntroduction.submitCode("123456", in: session) != .submitted)
            #expect(try await session.evaluate("document.body.dataset.codeSubmits === undefined") as? Bool == true)
        }
    }

    @Test func cancellationDuringContinueWaitPreventsDelayedSubmission() async throws {
        let session = try await fixture(codeStep(fieldAttributes: "oninput=\"setTimeout(()=>document.getElementById('code-continue').disabled=false,400)\""), address: "https://chatgpt.com/settings/security?action=enable&factor=totp")
        let operation = Task { try await AuthenticatorSetupIntroduction.submitCode("123456", in: session) }
        for _ in 0..<30 {
            if try await session.evaluate("document.getElementById('authenticator-code').value.length > 0") as? Bool == true { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        session.cancelLoading()
        do {
            _ = try await operation.value
            Issue.record("Cancelled code submission must stop")
        } catch is CancellationError {}
        try await Task.sleep(for: .milliseconds(450))
        #expect(try await session.evaluate("document.body.dataset.codeSubmits === undefined") as? Bool == true)
    }

    @Test func codeFormNeverUsesAnExternalSubmissionTarget() async throws {
        let html = codeStep(buttonAttributes: "formaction='https://external.example/submit'")
        let session = try await fixture(html, address: "https://chatgpt.com/settings/security?action=enable&factor=totp")
        #expect(try await AuthenticatorSetupIntroduction.submitCode("123456", in: session) == .ambiguous)
        #expect(try await session.evaluate("document.getElementById('authenticator-code').value === '' && document.body.dataset.codeSubmits === undefined") as? Bool == true)
    }

    @Test func disabledOrFormlessCodeScreenStillBlocksSetupCompletion() async throws {
        let disabled = try await fixture(codeStep(fieldAttributes: "disabled"), address: "https://chatgpt.com/settings/security?action=enable&factor=totp")
        #expect(try await AuthenticatorSetupIntroduction.codeStep(in: disabled) == .found)
        let withoutForm = codeStep().replacingOccurrences(of: "<form id=\"code-form\" onsubmit=\"event.preventDefault();document.body.dataset.codeSubmits=String(Number(document.body.dataset.codeSubmits||0)+1)\">", with: "").replacingOccurrences(of: "</form>", with: "")
        let session = try await fixture(withoutForm, address: "https://chatgpt.com/settings/security?action=enable&factor=totp")
        #expect(try await AuthenticatorSetupIntroduction.codeStep(in: session) == .found)
        #expect(try await AuthenticatorSetupIntroduction.submitCode("123456", in: session) == .noForm)
        #expect(try await session.evaluate("document.getElementById('authenticator-code').value === '' && document.body.dataset.codeSubmits === undefined") as? Bool == true)
    }

    @Test(arguments: [false, true])
    func modernWizardSavesTheSelectedKeyBeforeOneCodeSubmission(persistenceFails: Bool) async throws {
        enum FixtureError: Error { case persistence }
        let secret = "JBSWY3DPEHPK3PXP"
        let qr = qrStep(extra: "<code id='plain-key' hidden>\(secret)</code>",
                        onKeySelect: "document.getElementById('plain-key').hidden=false",
                        onContinue: "this.closest('[role=dialog]').remove();document.getElementById('code-stage').hidden=false;history.replaceState(null,'','?action=enable&factor=totp')")
        let code = codeStep().replacingOccurrences(
            of: "document.body.dataset.codeSubmits=String(Number(document.body.dataset.codeSubmits||0)+1)",
            with: "document.body.dataset.codeSubmits=String(Number(document.body.dataset.codeSubmits||0)+1);this.closest('[role=dialog]').remove();document.querySelector('[role=switch]').setAttribute('aria-checked','true')")
        let session = try await fixture("""
        <button role="switch" aria-label="Authenticator app" aria-checked="false"
                onclick="document.body.dataset.restarted='yes'">Authenticator app</button>
        \(intro(onContinue: "document.body.dataset.continued=String(Number(document.body.dataset.continued||0)+1);this.closest('[role=dialog]').remove();document.getElementById('qr-stage').hidden=false"))
        <div id="qr-stage" hidden>\(qr)</div>
        <div id="code-stage" hidden>\(code)</div>
        """)
        let automation = ChatGPTAutomation(sessionManager: WebSessionManager())
        var checkpoints = 0
        var savedSecret: String?

        let result = await automation.enrollNewAuthenticator(
            in: session, pendingSecret: nil, automaticallyWaitForTransitions: true,
            transitionTimeoutSeconds: 15, humanChallengeTimeoutSeconds: 0) { captured in
                checkpoints += 1
                if persistenceFails { throw FixtureError.persistence }
                savedSecret = captured
            }

        #expect(checkpoints == 1)
        #expect(try await session.evaluate("document.body.dataset.continued") as? String == "1")
        #expect(try await session.evaluate("document.body.dataset.keySelected") as? String == "1")
        #expect(try await session.evaluate("document.body.dataset.restarted === undefined") as? Bool == true)
        if persistenceFails {
            guard case .failure = result else { Issue.record("Unsaved key cannot advance wizard"); return }
            #expect(savedSecret == nil)
            #expect(try await session.evaluate("document.body.dataset.qrContinued === undefined && document.body.dataset.codeSubmits === undefined") as? Bool == true)
        } else {
            #expect(savedSecret == secret)
            #expect(result == .enabled(secret: secret))
            #expect(try await session.evaluate("document.body.dataset.qrContinued") as? String == "1")
            #expect(try await session.evaluate("document.body.dataset.codeSubmits") as? String == "1")
        }
    }

    @Test(arguments: [false, true])
    func textOnlyCaptureRequiresTheVisibleKeyAndIgnoresURIs(plainKeyVisible: Bool) async throws {
        let secret = "JBSWY3DPEHPK3PXP"
        let outsideURI = "<a href='otpauth://totp/Outside?secret=KRSXG5DSNFXGOIDB'>Outside fixture</a>"
        let content = "<code \(plainKeyVisible ? "" : "hidden")>\(secret)</code><div data-uri='otpauth://totp/Fixture?secret=\(secret)'></div>"
        let session = try await fixture(outsideURI + qrStep(keyAttributes: "aria-pressed='true'", extra: content))
        do {
            let captured = try await QRCodeSecretExtractor.extract(from: session.webView, textOnly: true)
            #expect(plainKeyVisible)
            #expect(captured == secret)
        } catch QRCodeSecretError.missingURI {
            #expect(!plainKeyVisible)
        }
        #expect(try await session.evaluate("document.body.dataset.keySelected === undefined && document.body.dataset.qrContinued === undefined") as? Bool == true)
    }

    @Test(arguments: [false, true])
    func codeOnlyResumeUsesOnlyTheDurablePendingKey(hasPendingKey: Bool) async throws {
        let secret = "JBSWY3DPEHPK3PXP"
        let code = codeStep().replacingOccurrences(
            of: "document.body.dataset.codeSubmits=String(Number(document.body.dataset.codeSubmits||0)+1)",
            with: "document.body.dataset.codeSubmits=String(Number(document.body.dataset.codeSubmits||0)+1);this.closest('[role=dialog]').remove();document.querySelector('[role=switch]').setAttribute('aria-checked','true')")
        let session = try await fixture("""
        <button role="switch" aria-label="Authenticator app" aria-checked="false"
                onclick="document.body.dataset.restarted='yes'">Authenticator app</button>
        \(code)
        """, address: "https://chatgpt.com/settings/security?action=enable&factor=totp")
        let automation = ChatGPTAutomation(sessionManager: WebSessionManager())

        let result = await automation.enrollNewAuthenticator(
            in: session, pendingSecret: hasPendingKey ? secret : nil,
            automaticallyWaitForTransitions: true, transitionTimeoutSeconds: 15,
            humanChallengeTimeoutSeconds: 0) { _ in
                Issue.record("Code-only resume cannot capture or replace a key")
            }

        #expect(try await session.evaluate("document.body.dataset.restarted === undefined") as? Bool == true)
        if hasPendingKey {
            #expect(result == .enabled(secret: secret))
            #expect(try await session.evaluate("document.body.dataset.codeSubmits") as? String == "1")
        } else {
            guard case .manual = result else { Issue.record("Missing key requires manual recovery"); return }
            #expect(try await session.evaluate("document.getElementById('authenticator-code').value === '' && document.body.dataset.codeSubmits === undefined") as? Bool == true)
        }
    }

    @Test(arguments: [false, true])
    func rotationResumeCodeOnlyKeepsSavedKeyWithoutStartingSetup(codeRemainsVisible: Bool) async throws {
        enum CheckpointReached: Error { case confirmed }
        let pendingSecret = "KRSXG5DSNFXGOIDB"
        let oldSecret = "JBSWY3DPEHPK3PXP"
        let code = codeRemainsVisible ? codeStep(buttonAttributes: "") : codeStep().replacingOccurrences(
            of: "document.body.dataset.codeSubmits=String(Number(document.body.dataset.codeSubmits||0)+1)",
            with: "document.body.dataset.codeSubmits=String(Number(document.body.dataset.codeSubmits||0)+1);this.closest('[role=dialog]').remove();document.querySelector('[role=switch]').setAttribute('aria-checked','true')")
        let background = "<button role='switch' aria-label='Authenticator app' aria-checked='false' onclick=\"document.body.dataset.restarted='yes'\">Authenticator app</button>"
        let session = try await fixture("""
        \(codeRemainsVisible ? background : "<section>\(background)</section>")
        \(code)
        <script>window.fetch=async()=>({ok:true,json:async()=>({user:{email:'owner@example.com'}})});</script>
        """, address: "https://chatgpt.com/settings/security?action=enable&factor=totp")
        let automation = ChatGPTAutomation(sessionManager: WebSessionManager(accountSessionFactory: { _ in session }))
        var account = AccountRecord(credential: .init(
            email: "owner@example.com", password: "fixture-password", totpSecret: oldSecret))
        automation.prepareBrowserSession(for: account)
        account.rotationStage = .pendingSecretCaptured
        account.pendingTOTPSecret = pendingSecret
        var checkpoints: [RotationCheckpointEvent] = []

        _ = await automation.rotate2FA(account: account) { checkpoint in
            checkpoints.append(checkpoint)
            if checkpoint == .setupConfirmed { throw CheckpointReached.confirmed }
        }

        #expect(checkpoints == (codeRemainsVisible ? [] : [.setupConfirmed]))
        let submits = try await session.evaluate("document.body.dataset.codeSubmits") as? String
        #expect(submits == "1")
        #expect(try await session.evaluate("document.body.dataset.restarted === undefined") as? Bool == true)
        #expect(account.pendingTOTPSecret == pendingSecret)
        #expect(account.totpSecret == oldSecret)
    }
}
