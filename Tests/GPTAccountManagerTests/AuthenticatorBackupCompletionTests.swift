import Foundation
import Testing
import WebKit
@testable import GPTAccountManager

@MainActor
@Suite struct AuthenticatorBackupCompletionTests {
    private let pendingSecret = "KRUGS4ZANFZSAYJA"

    private func fixture(_ html: String) async throws -> BrowserSession {
        let session = BrowserSession(dataStore: .nonPersistent())
        session.webView.navigationDelegate = nil
        session.webView.loadHTMLString(html, baseURL: URL(string: "https://chatgpt.com/#settings/Security")!)
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while session.webView.isLoading, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(TrustedChatGPTOrigin.allowsSecurityAutomation(session.webView.url))
        return session
    }

    private var backupPrompt: String {
        """
        <section id="backup"><h1>Authenticator app added</h1>
          <p>Now, set up text messages as a backup MFA method. This will ensure you can still log into your account if you lose access to your authenticator app.</p>
          <button type="button" onclick="document.body.dataset.backupChosen='yes'">Add backup method</button>
          <button id="skip" type="button" hidden onclick="window.skips++;this.closest('section').remove();setTimeout(()=>{const toggle=document.querySelector('[role=switch]');toggle.hidden=false;toggle.setAttribute('aria-checked','true')},400)">Not now</button>
        </section>
        """
    }

    @Test(arguments: [false, true])
    func rotationSkipsDelayedTextMessageBackupBeforeConfirmingSetup(resuming: Bool) async throws {
        let encodedPrompt = String(decoding: try JSONEncoder().encode(backupPrompt), as: UTF8.self)
        let session = try await fixture("""
        <button id="authenticator" role="switch" aria-label="Authenticator app" aria-checked="false"
          onclick="document.body.dataset.setupStarts=String(Number(document.body.dataset.setupStarts||0)+1);document.querySelector('#setup').hidden=false">Authenticator app</button>
        <div id="setup" role="dialog" hidden><h2>Connect your authenticator app</h2>
          <a href="otpauth://totp/OpenAI:fixture?secret=\(pendingSecret)">Setup key</a>
          <form onsubmit="event.preventDefault();document.body.dataset.submits=String(Number(document.body.dataset.submits||0)+1);document.querySelector('#setup').remove();showBackup()">
            <input autocomplete="one-time-code"><button>Continue</button>
          </form>
        </div>
        <script>
          window.skips=0;
          window.fetch=async()=>({ok:true,json:async()=>({user:{email:'owner@example.com'}})});
          function showBackup(){
            document.querySelector('#authenticator').hidden=true;
            document.body.insertAdjacentHTML('beforeend',\(encodedPrompt));
            setTimeout(()=>document.querySelector('#skip').hidden=false,1200);
          }
          \(resuming ? "document.querySelector('#setup').remove();showBackup();" : "")
        </script>
        """)
        let automation = ChatGPTAutomation(sessionManager: WebSessionManager(accountSessionFactory: { _ in session }))
        var account = AccountRecord(credential: .init(
            email: "owner@example.com", password: "fixture-password", totpSecret: "JBSWY3DPEHPK3PXP"))
        // Establish the original authenticated context before staging recovery.
        automation.prepareBrowserSession(for: account)
        if resuming {
            account.rotationStage = .pendingSecretCaptured
            account.pendingTOTPSecret = pendingSecret
        }
        var checkpoints: [RotationCheckpointEvent] = []

        _ = await automation.rotate2FA(account: account) { checkpoint in
            checkpoints.append(checkpoint)
            // Stop at the persisted checkpoint so clean-login verification cannot navigate online.
            if checkpoint == .setupConfirmed { throw CheckpointReached.confirmed }
        }

        #expect(checkpoints == (resuming
            ? [.setupConfirmed]
            : [.oldMethodDisabled, .secretCaptured(pendingSecret), .setupConfirmed]))
        #expect(try await session.evaluate("window.skips") as? Int == 1)
        #expect(try await session.evaluate("document.querySelector('#backup') === null") as? Bool == true)
        #expect(try await session.evaluate("document.querySelector('[role=switch]').getAttribute('aria-checked')") as? String == "true")
        #expect(try await session.evaluate("document.body.dataset.backupChosen === undefined") as? Bool == true)
        #expect(try await session.evaluate("Number(document.body.dataset.setupStarts||0)") as? Int == (resuming ? 0 : 1))
        #expect(try await session.evaluate("Number(document.body.dataset.submits||0)") as? Int == (resuming ? 0 : 1))
        #expect(account.pendingTOTPSecret == (resuming ? pendingSecret : nil))
        #expect(account.totpSecret == "JBSWY3DPEHPK3PXP")
    }

    @Test func backupDismissalAloneDoesNotProveAuthenticatorEnabled() async throws {
        let prompt = backupPrompt
            .replacingOccurrences(of: "type=\"button\" hidden", with: "type=\"button\"")
            .replacingOccurrences(of: ";setTimeout(()=>{const toggle=document.querySelector('[role=switch]');toggle.hidden=false;toggle.setAttribute('aria-checked','true')},400)", with: "")
        let session = try await fixture("<script>window.skips=0;</script>" + prompt)
        let automation = ChatGPTAutomation(sessionManager: WebSessionManager())

        let completed = await automation.waitForAuthenticatorSetupCompletion(in: session, seconds: 2)

        #expect(!completed)
        #expect(try await session.evaluate("window.skips") as? Int == 1)
        #expect(try await session.evaluate("document.querySelector('#backup') === null") as? Bool == true)
    }

    @Test func enabledSwitchDoesNotCompleteSetupWhileQRCodeDialogRemains() async throws {
        let session = try await fixture("""
        <button role="switch" aria-label="Authenticator app" aria-checked="true">Authenticator app</button>
        <div role="dialog"><h2>Connect your authenticator app</h2>
          <code>\(pendingSecret)</code><input autocomplete="one-time-code">
        </div>
        """)
        let automation = ChatGPTAutomation(sessionManager: WebSessionManager())

        #expect(!(await automation.waitForAuthenticatorSetupCompletion(in: session, seconds: 1)))
    }

    @Test func completionWaitsForBackupPromptThatAppearsAfterEnabledSwitch() async throws {
        let encodedPrompt = String(decoding: try JSONEncoder().encode(backupPrompt), as: UTF8.self)
        let session = try await fixture("""
        <button role="switch" aria-label="Authenticator app" aria-checked="true">Authenticator app</button>
        <script>
          window.skips=0;
          setTimeout(()=>{
            document.body.insertAdjacentHTML('beforeend',\(encodedPrompt));
            document.querySelector('#skip').hidden=false;
          },300);
        </script>
        """)
        let automation = ChatGPTAutomation(sessionManager: WebSessionManager())

        #expect(await automation.waitForAuthenticatorSetupCompletion(in: session, seconds: 3))
        #expect(try await session.evaluate("window.skips") as? Int == 1)
        #expect(try await session.evaluate("document.querySelector('#backup') === null") as? Bool == true)
    }

    @Test(arguments: [false, true])
    func enabledSwitchWaitsForHiddenSkipAndNeverRetriesIt(promptRemainsAfterClick: Bool) async throws {
        let session = try await fixture("""
        <button role="switch" aria-label="Authenticator app" aria-checked="true">Authenticator app</button>
        <section id="backup"><h1>Authenticator app added</h1>
          <p>Now, set up text messages as a backup MFA method. This will ensure you can still log into your account if you lose access to your authenticator app.</p>
          <button id="skip" type="button" hidden onclick="window.skips++;\(promptRemainsAfterClick ? "" : "this.closest('section').remove();")">Not now</button>
        </section>
        <script>
          window.skips=0;
          setTimeout(()=>document.querySelector('#skip').hidden=false,1200);
        </script>
        """)
        let automation = ChatGPTAutomation(sessionManager: WebSessionManager())

        let completed = await automation.waitForAuthenticatorSetupCompletion(in: session, seconds: 4)

        #expect(completed == !promptRemainsAfterClick)
        #expect(try await session.evaluate("window.skips") as? Int == 1)
        #expect(try await session.evaluate("document.querySelector('#backup') !== null") as? Bool == promptRemainsAfterClick)
        #expect(try await session.evaluate("document.querySelector('[role=switch]').getAttribute('aria-checked')") as? String == "true")
    }

    private enum CheckpointReached: Error { case confirmed }
}
