import AppKit
import Foundation
import Testing
import WebKit
@testable import GPTAccountManager

@MainActor
@Suite(.serialized)
struct RotationEnrollmentTests {
    enum Start: CaseIterable {
        case enabled, savedKey, failedCheckpoint
    }

    @Test(arguments: Start.allCases)
    func rotationFollowsDelayedWizardWithOneEnrollment(start: Start) async throws {
        enum CheckpointError: Error { case fixture }
        let oldSecret = "JBSWY3DPEHPK3PXP"
        let newSecret = "KRSXG5DSNFXGOIDB"
        let resuming = start == .savedKey
        let session = try await fixture(secret: newSecret, resuming: resuming)
        let automation = ChatGPTAutomation(sessionManager: WebSessionManager(accountSessionFactory: { _ in session }))
        var account = AccountRecord(credential: .init(
            email: "owner@example.com", password: "fixture-password", totpSecret: oldSecret))
        automation.prepareBrowserSession(for: account)
        if resuming {
            account.rotationStage = .pendingSecretCaptured
            account.pendingTOTPSecret = newSecret
        }
        var checkpoints: [RotationCheckpointEvent] = []

        _ = await automation.rotate2FA(account: account) { checkpoint in
            checkpoints.append(checkpoint)
            // Stop before clean login, or simulate an unavailable checkpoint store.
            if checkpoint == .setupConfirmed ||
                (start == .failedCheckpoint && checkpoint == .secretCaptured(newSecret)) {
                throw CheckpointError.fixture
            }
        }

        let actions = try await session.evaluate("actions.join(',')") as? String
        switch start {
        case .enabled:
            #expect(checkpoints == [.removalStarted, .removalStarted, .oldMethodDisabled,
                                    .secretCaptured(newSecret), .setupConfirmed])
            #expect(actions == "disable,remove,enable,intro,key,qr,code,skip-backup")
        case .savedKey:
            #expect(checkpoints == [.setupConfirmed])
            #expect(actions == "key,qr,code,skip-backup")
        case .failedCheckpoint:
            #expect(checkpoints == [.removalStarted, .removalStarted, .oldMethodDisabled,
                                    .secretCaptured(newSecret)])
            #expect(actions == "disable,remove,enable,intro,key")
        }
    }

    @Test func manualFactorRecoveryContinuesWhenBrowserSignsIn() async throws {
        let session = try await fixture(secret: "KRSXG5DSNFXGOIDB", resuming: false)
        let automation = ChatGPTAutomation(sessionManager: WebSessionManager())
        let account = AccountRecord(credential: .init(
            email: "owner@example.com", password: "fixture-password", totpSecret: "JBSWY3DPEHPK3PXP"))
        session.webView.loadHTMLString(
            #"<form><input name="code" autocomplete="one-time-code"><button>Continue</button></form>"#,
            baseURL: URL(string: "https://auth.openai.com/mfa-challenge/fixture"))
        let deadline = ContinuousClock.now + .seconds(5)
        while session.webView.isLoading && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(30))
        }
        let login = Task {
            await automation.signIn(account: account, secret: account.totpSecret, in: session,
                                    automaticallySubmitOTP: false, waitForManualFactor: true,
                                    loginTimeoutSeconds: 5, humanChallengeTimeoutSeconds: 8)
        }
        defer { login.cancel() }
        let promptDeadline = ContinuousClock.now + .seconds(4)
        while session.operationMessage == nil && ContinuousClock.now < promptDeadline {
            try await Task.sleep(for: .milliseconds(30))
        }
        try #require(session.operationMessage?.contains("продолжится автоматически") == true)
        #expect(try await session.evaluate("document.querySelector('[name=code]').value") as? String == "")
        session.webView.loadHTMLString(
            #"<script>window.fetch=async()=>({ok:true,json:async()=>({user:{email:'owner@example.com'}})});</script>"#,
            baseURL: URL(string: "https://chatgpt.com/"))
        guard case .success(let snapshot, _) = await login.value else {
            Issue.record("The same recovery attempt must observe the completed manual sign-in")
            return
        }
        #expect(snapshot.signedInEmail == account.email)
    }

    private func fixture(secret: String, resuming: Bool) async throws -> BrowserSession {
        _ = NSApplication.shared
        let session = BrowserSession(dataStore: .nonPersistent()) { configuration in
            WKWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 700), configuration: configuration)
        }
        session.webView.navigationDelegate = nil
        session.webView.loadHTMLString("""
        <button id="toggle" role="switch" aria-label="Authenticator app" aria-checked="\(resuming ? "false" : "true")"
                onclick="toggleAuthenticator()">Authenticator app</button>
        <section id="removal" role="dialog" hidden>
          <h2>Remove authenticator app</h2>
          <button onclick="actions.push('remove');hide('removal');el('toggle').setAttribute('aria-checked','false')">Remove</button>
        </section>
        <section id="intro" role="dialog" hidden>
          <h2>Настройка приложения для аутентификации</h2>
          <p>Вам понадобится приложение для аутентификации или менеджер паролей, который генерирует коды подтверждения.
             Используйте приложение, которое у вас уже есть, или скачайте одно из следующих:</p>
          <button onclick="actions.push('intro');hide('intro');setTimeout(()=>show('qr'),150)">Продолжить</button>
        </section>
        <section id="qr" role="dialog" \(resuming ? "" : "hidden")>
          <h2>Добавьте свою учетную запись в приложение</h2>
          <p>Скопируйте ключ настройки и вставьте его в приложение для аутентификации или отсканируйте QR-код с помощью этого приложения</p>
          <button aria-pressed="false" onclick="actions.push('key');this.setAttribute('aria-pressed','true');setTimeout(()=>show('key'),150)">Ключ</button>
          <code id="key" hidden>\(secret)</code>
          <button onclick="advanceFromKey()">Продолжить</button>
        </section>
        <section id="code" role="dialog" hidden>
          <h2>Введите код</h2>
          <p>Чтобы завершить настройку, введите 6-значный код из приложения для аутентификации</p>
          <form onsubmit="event.preventDefault();actions.push('code');hide('code');show('backup');setTimeout(()=>show('skip'),250)">
            <input id="otp" aria-label="Код" inputmode="numeric" pattern="[0-9]{6}" required
                   oninput="setTimeout(()=>el('submit').disabled=false,80)">
            <button id="submit" type="submit" disabled>Продолжить</button>
          </form>
        </section>
        <section id="backup" hidden>
          <h2>Authenticator app added</h2>
          <p>Set up text messages as a backup MFA method.</p>
          <button onclick="actions.push('add-backup')">Add backup method</button>
          <button id="skip" hidden onclick="actions.push('skip-backup');hide('backup');el('toggle').setAttribute('aria-checked','true')">Not now</button>
        </section>
        <script>
          const actions = [];
          const el = id => document.getElementById(id);
          const hide = id => el(id).hidden = true;
          const show = id => el(id).hidden = false;
          window.fetch = async () => ({ok:true,json:async()=>({user:{email:'owner@example.com'}})});
          function toggleAuthenticator() {
            if (el('toggle').getAttribute('aria-checked') === 'true') {
              actions.push('disable');
              show('removal');
            } else {
              actions.push('enable');
              if (el('qr').hidden) setTimeout(()=>show('intro'),150);
            }
          }
          function advanceFromKey() {
            actions.push('qr');
            hide('qr');
            // Longer than the generic post-click wait. The next step has a different action URL.
            setTimeout(()=>{
              history.replaceState(null,'','?action=enable&factor=totp');
              show('code');
            },1600);
          }
        </script>
        """, baseURL: URL(string: "https://chatgpt.com/settings/security"))
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while session.webView.isLoading && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(30))
        }
        try #require(!session.webView.isLoading)
        return session
    }
}
