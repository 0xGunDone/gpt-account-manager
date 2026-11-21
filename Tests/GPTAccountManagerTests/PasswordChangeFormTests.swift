import AppKit
import Foundation
import Testing
@testable import GPTAccountManager

@MainActor
@Suite(.serialized)
struct PasswordChangeFormTests {
    private func fixture(_ html: String, url: String = "https://auth.openai.com/change-password") async throws -> BrowserSession {
        _ = NSApplication.shared
        let session = BrowserSession(dataStore: .nonPersistent())
        session.webView.navigationDelegate = nil
        session.webView.loadHTMLString(html, baseURL: URL(string: url))
        for _ in 0..<60 where session.webView.isLoading {
            try await Task.sleep(for: .milliseconds(50))
        }
        return session
    }

    @Test func passwordFormFillsCurrentNewAndConfirmationWithoutTouchingMFA() async throws {
        let session = try await fixture("""
        <h1>Change password</h1><form onsubmit="event.preventDefault();document.body.dataset.saved='yes'">
        <input type="password" autocomplete="current-password" id="old">
        <input type="password" autocomplete="new-password" id="new">
        <input type="password" name="confirmPassword" id="confirm">
        <input name="otp" value="untouched"><button type="submit">Save</button></form>
        <button role="switch" aria-checked="true" onclick="this.setAttribute('aria-checked','false')">Authenticator app</button>
        """)
        #expect(try await PasswordChangeForm.apply(in: session, currentPassword: "old-fixture", newPassword: "new-fixture", submit: false) == .ready)
        #expect(try await session.evaluate("document.querySelector('#new').value") as? String == "")
        #expect(try await PasswordChangeForm.apply(in: session, currentPassword: "old-fixture", newPassword: "new-fixture", submit: true) == .submitted)
        #expect(try await session.evaluate("JSON.stringify([...document.querySelectorAll('input')].map(e=>e.value))") as? String == "[\"old-fixture\",\"new-fixture\",\"new-fixture\",\"untouched\"]")
        #expect(try await session.evaluate("document.body.dataset.saved") as? String == "yes")
        #expect(try await session.evaluate("document.querySelector('[role=switch]').getAttribute('aria-checked')") as? String == "true")
    }

    @Test func loginAndAmbiguousFormsNeverReceiveNewPassword() async throws {
        for html in [
            "<h1>Log in</h1><form><input type='password' autocomplete='current-password'><button>Continue</button></form>",
            "<h1>Change password</h1><form><input type='password' autocomplete='new-password'><button>Save</button><button>Continue</button></form>",
            "<h1>Change password</h1><form><input type='password' autocomplete='new-password'><input type='password' name='unknown'><button>Save</button></form>",
        ] {
            let session = try await fixture(html)
            #expect(try await PasswordChangeForm.apply(in: session, currentPassword: "old", newPassword: "new", submit: true) != .submitted)
            #expect(try await session.evaluate("[...document.querySelectorAll('input')].every(e=>e.value==='')") as? Bool == true)
        }
    }

    @Test func externalPageNeverReceivesPasswords() async throws {
        let session = try await fixture("<h1>Change password</h1><form><input type='password' autocomplete='new-password'><button>Save</button></form>", url: "https://external.example/")
        do {
            _ = try await PasswordChangeForm.apply(in: session, currentPassword: "old", newPassword: "new", submit: true)
            Issue.record("External form accepted credential automation")
        } catch BrowserSessionError.untrustedOrigin {}
    }

    @Test func fillsBeforeWaitingForSaveButtonToEnable() async throws {
        let session = try await fixture("""
        <h1>Изменить пароль</h1><form onsubmit="event.preventDefault();document.body.dataset.saved='yes'">
        <input type="password" autocomplete="new-password"
               oninput="setTimeout(()=>document.querySelector('button').disabled=false,20)">
        <button type="submit" disabled>Сохранить</button></form>
        """)
        #expect(try await PasswordChangeForm.apply(in: session, currentPassword: "old", newPassword: "new-fixture", submit: false) == .ready)
        #expect(try await PasswordChangeForm.apply(in: session, currentPassword: "old", newPassword: "new-fixture", submit: true) == .submitted)
        #expect(try await session.evaluate("document.body.dataset.saved") as? String == "yes")
    }

    @Test func opensOnlyPasswordControlAndLeavesAuthenticatorSwitchAlone() async throws {
        let session = try await fixture("""
        <button onclick="document.body.dataset.opened='password'">Пароль Управляйте паролем для входа в аккаунт Изменить</button>
        <button role="switch" aria-checked="true" onclick="document.body.dataset.opened='mfa'">Приложение для аутентификации</button>
        """, url: "https://chatgpt.com/settings/security")
        #expect(try await PasswordChangeForm.open(in: session))
        #expect(try await session.evaluate("document.body.dataset.opened") as? String == "password")
        #expect(try await session.evaluate("document.querySelector('[role=switch]').getAttribute('aria-checked')") as? String == "true")
    }

    @Test func stopWhileSaveIsDisabledPreventsDelayedPasswordSubmission() async throws {
        let session = try await fixture("""
        <h1>Change password</h1><form onsubmit="event.preventDefault();document.body.dataset.saved='yes'">
        <input type="password" autocomplete="new-password"
               oninput="setTimeout(()=>document.querySelector('button').disabled=false,400)">
        <button type="submit" disabled>Save</button></form>
        """)
        let task = Task { try await PasswordChangeForm.apply(in: session, currentPassword: "old", newPassword: "new-fixture", submit: true) }
        for _ in 0..<30 {
            if try await session.evaluate("document.querySelector('input').value.length > 0") as? Bool == true { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        session.cancelLoading()
        do {
            _ = try await task.value
            Issue.record("Stopped password submission did not cancel")
        } catch is CancellationError {}
        try await Task.sleep(for: .milliseconds(500))
        #expect(try await session.evaluate("document.body.dataset.saved === undefined") as? Bool == true)
    }
}
