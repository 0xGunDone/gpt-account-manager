import Foundation

enum PasswordFormResult: String {
    case notFound, ambiguous, ready, submitted
}

@MainActor
enum PasswordChangeForm {
    static func rejectsPassword(_ text: String) -> Bool {
        let value = text.lowercased()
        return ["incorrect email address or password", "incorrect password", "wrong password",
                "неверный пароль", "неправильный пароль", "неверный адрес электронной почты или пароль"]
            .contains(where: value.contains)
    }
    static func open(in session: BrowserSession) async throws -> Bool {
        guard TrustedChatGPTOrigin.allowsSecurityAutomation(session.webView.url) else {
            throw BrowserSessionError.untrustedOrigin
        }
        return try await session.evaluate("""
        (() => {
          const candidates = [...document.querySelectorAll('button, a, [role="button"]')]
            .filter(e => e.getBoundingClientRect().width > 0 && !e.disabled)
            .filter(e => /^(password|пароль)(\\s|$)/i.test(
              (e.getAttribute('aria-label') || e.innerText || '').trim()));
          if (candidates.length !== 1) return false;
          candidates[0].click();
          return true;
        })()
        """) as? Bool == true
    }

    static func apply(
        in session: BrowserSession,
        currentPassword: String,
        newPassword: String,
        submit: Bool
    ) async throws -> PasswordFormResult {
        guard TrustedChatGPTOrigin.allowsAuthentication(session.webView.url) else {
            throw BrowserSessionError.untrustedOrigin
        }
        let passwords = String(decoding: try JSONEncoder().encode([currentPassword, newPassword]), as: UTF8.self)
        let generation = session.cancellationGeneration
        let raw = try await session.evaluate("""
        (() => {
          const visible = e => {
            const r = e.getBoundingClientRect();
            return r.width > 0 && r.height > 0 &&
              getComputedStyle(e).visibility !== 'hidden';
          };
          const fields = [...document.querySelectorAll('input[type="password"]')].filter(e => visible(e) && !e.disabled);
          if (!fields.length) return 'notFound';
          const label = e => [e.name, e.id, e.placeholder, e.getAttribute('aria-label'),
            ...[...(e.labels || [])].map(l => l.innerText)].join(' ').toLowerCase();
          const current = fields.filter(e => e.autocomplete === 'current-password' ||
            /current|old.password|текущ|старый/.test(label(e)));
          let fresh = fields.filter(e => !current.includes(e) &&
            (e.autocomplete === 'new-password' || /new.?password|confirm|новый|нового|подтверд|повтор/.test(label(e))));
          const heading = [...document.querySelectorAll('h1,h2,h3,[role="heading"]')]
            .filter(visible).map(e => e.innerText).join(' ').toLowerCase();
          const changeHeading = /(change|update|set|reset|new).*password|(?:измен|смен|новый|созда|обнов).*парол/.test(heading);
          if (!fresh.length && changeHeading && fields.length === 1 && !current.length) fresh = fields;
          if (!fresh.length) return 'notFound';
          if (fresh.length > 2 || current.length > 1 || fields.length !== fresh.length + current.length)
            return 'ambiguous';
          const root = fresh[0].form || fresh[0].closest('[role="dialog"]');
          if (!root || !fields.every(e => root.contains(e))) return 'ambiguous';
          const buttons = [...root.querySelectorAll('button, input[type="submit"]')].filter(visible)
            .filter(e => e.type === 'submit' || /^(save|update password|change password|continue|сохранить|изменить пароль|сменить пароль|продолжить)$/i.test((e.innerText || e.value || '').trim()));
          if (buttons.length !== 1) return 'ambiguous';
          if (!\(submit ? "true" : "false")) return 'ready';
          const values = \(passwords);
          const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set;
          for (const field of fields) {
            setter.call(field, current.includes(field) ? values[0] : values[1]);
            field.dispatchEvent(new Event('input', {bubbles:true}));
            field.dispatchEvent(new Event('change', {bubbles:true}));
          }
          window.__gptAccountPasswordForm = {button: buttons[0], fields};
          return 'filled';
        })()
        """) as? String
        if raw == "filled" {
            for _ in 0..<20 {
                try Task.checkCancellation()
                guard generation == session.cancellationGeneration else { throw CancellationError() }
                let result = try await session.evaluate("""
                (() => {
                  const pending = window.__gptAccountPasswordForm;
                  if (!pending || !pending.button.isConnected || pending.fields.some(e => !e.isConnected)) return 'ambiguous';
                  if (pending.button.disabled) return 'ready';
                  if (pending.fields.some(e => !e.checkValidity())) return 'ambiguous';
                  delete window.__gptAccountPasswordForm;
                  pending.button.click();
                  return 'submitted';
                })()
                """) as? String
                if result != "ready" { return result.flatMap(PasswordFormResult.init(rawValue:)) ?? .ambiguous }
                try await Task.sleep(for: .milliseconds(50))
            }
            return .ambiguous
        }
        return raw.flatMap(PasswordFormResult.init(rawValue:)) ?? .ambiguous
    }
}
