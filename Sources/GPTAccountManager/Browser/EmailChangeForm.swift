import Foundation
import OSLog

@MainActor
enum EmailChangeForm {
    private static let logger = Logger(subsystem: "local.wemakecode.gptaccountmanager", category: "email-change-form")
    private static var lastDiagnostic: String?
    enum Kind: String, Codable {
        case emailEntry, emailCode, password, totp, emailChallenge, accountSettings, unknown
    }

    struct State: Equatable {
        let kind: Kind
        let displayedEmail: String?
    }

    static func inspect(in session: BrowserSession) async throws -> State {
        try requireTrustedOrigin(session)
        if let authentication = authenticationKind(session.webView.url) {
            return State(kind: authentication, displayedEmail: nil)
        }
        let raw = try await session.evaluate("""
        (() => {
          \(domHelpers)
          const form = findForm();
          return {kind: form.kind, displayedEmail: form.displayedEmail || null, diagnostic: form.diagnostic || null};
        })()
        """) as? [String: Any]
        let diagnostic = raw?["diagnostic"] as? String
        if diagnostic != lastDiagnostic {
            if let diagnostic { logger.notice("Unrecognized email form: \(diagnostic, privacy: .public)") }
            lastDiagnostic = diagnostic
        }
        return State(kind: (raw?["kind"] as? String).flatMap(Kind.init(rawValue:)) ?? .unknown,
                     displayedEmail: raw?["displayedEmail"] as? String)
    }

    static func open(in session: BrowserSession, currentEmail: String) async throws -> Bool {
        try requireTrustedOrigin(session)
        guard isAccountSettings(session.webView.url) else { return false }
        let email = try encoded(currentEmail.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        return try await session.evaluate("""
        (() => {
          \(domHelpers)
          const root = accountSettingsRoot();
          if (!accountSettings() || !root) return false;
          const buttons = emailControls(root);
          if (buttons.length !== 1 || controlEmail(buttons[0], root !== document) !== \(email) || !enabled(buttons[0])) return false;
          buttons[0].click();
          return true;
        })()
        """) as? Bool == true
    }

    static func dismissEmailBlockingNotice(in session: BrowserSession) async throws -> Bool {
        try Task.checkCancellation()
        try requireTrustedOrigin(session)
        guard isAccountSettings(session.webView.url) else { return false }
        return try await session.evaluate("""
        (() => {
          \(domHelpers)
          if (!accountSettings()) return false;
          const dialogSelector = '[role="dialog"], dialog';
          const headingSelector = 'h1,h2,h3,[role="heading"]';
          const title = 'продлите подписку на chatgpt plus';
          const titles = [...document.querySelectorAll('h2')].filter(visible)
            .filter(e => norm(e.innerText) === title);
          if (titles.length !== 1) return false;
          const root = titles[0].closest(dialogSelector);
          if (!root || !visible(root)) return false;
          const headings = [...root.querySelectorAll(headingSelector)].filter(visible);
          if (headings.length !== 1 || headings[0] !== titles[0] ||
              [...root.querySelectorAll(dialogSelector)].some(visible)) return false;
          if ([...root.querySelectorAll('input, textarea, [contenteditable="true"]')]
              .some(e => visible(e) && e.type !== 'hidden')) return false;
          const close = [...root.querySelectorAll('button')].filter(visible)
            .filter(e => e.closest(dialogSelector) === root &&
              norm(e.innerText) === 'закрыть' && name(e) === 'закрыть');
          if (close.length !== 1 || !enabled(close[0])) return false;
          close[0].click();
          return true;
        })()
        """) as? Bool == true
    }

    static func submitAuthenticatorCode(_ code: String, expectedPageURL: URL?, in session: BrowserSession) async throws -> ChatGPTAutomation.FormResult {
        try Task.checkCancellation()
        try requireTrustedOrigin(session)
        guard code.count == 6, code.allSatisfy({ $0 >= "0" && $0 <= "9" }),
              let expectedPageURL, session.webView.url == expectedPageURL,
              expectedPageURL.host?.lowercased() == "auth.openai.com",
              expectedPageURL.path.lowercased().hasPrefix("/mfa-challenge/") else { return .ambiguous }
        let generation = session.cancellationGeneration
        let expected = try encoded(expectedPageURL.absoluteString)
        let value = try encoded(code)
        let attempt = try encoded(UUID().uuidString)
        let findChallenge = """
        \(domHelpers)
        if (location.href !== \(expected)) return 'ambiguous';
        const fields = [...document.querySelectorAll('input')].filter(visible)
          .filter(e => !['hidden','checkbox','radio','submit','button'].includes(e.type));
        if (!fields.length) return 'notFound';
        if (fields.length !== 1) return 'ambiguous';
        const field = fields[0];
        if (!['text','tel','number'].includes(field.type) || !enabled(field) || field.readOnly ||
            !['код','одноразовый код','code','one-time code','verification code'].includes(fieldLabel(field))) return 'ambiguous';
        const headings = [...document.querySelectorAll('h1,h2,h3,[role="heading"]')].filter(visible)
          .filter(e => norm(e.innerText) === 'проверьте приложение для аутентификации');
        if (headings.length !== 1) return 'ambiguous';
        const form = field.form;
        if (!form) return 'noForm';
        if (new URL(form.action, location.href).origin !== location.origin) return 'ambiguous';
        const buttons = [...form.querySelectorAll('button,input[type="submit"]')].filter(visible)
          .filter(e => ['continue','продолжить'].includes(name(e)));
        if (buttons.length !== 1 || buttons[0].form !== form ||
            new URL(buttons[0].formAction || form.action, location.href).origin !== location.origin) return 'ambiguous';
        """
        let filled = try await session.evaluate("""
        (() => {
          \(findChallenge)
          for (const element of [document,form,field]) element.__gptAccountEmailAuthenticatorAttempt = \(attempt);
          Object.getOwnPropertyDescriptor(HTMLInputElement.prototype,'value').set.call(field,\(value));
          field.dispatchEvent(new Event('input',{bubbles:true}));
          field.dispatchEvent(new Event('change',{bubbles:true}));
          return 'filled';
        })()
        """) as? String
        guard filled == "filled" else {
            return filled.flatMap(ChatGPTAutomation.FormResult.init(rawValue:)) ?? .ambiguous
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline {
            // Input handlers may disable or replace Continue on the next render.
            try await Task.sleep(for: .milliseconds(50))
            try Task.checkCancellation()
            guard generation == session.cancellationGeneration else { throw CancellationError() }
            try requireTrustedOrigin(session)
            guard session.webView.url == expectedPageURL else { return .ambiguous }
            let result = try await session.evaluate("""
            (() => {
              \(findChallenge)
              if ([document,form,field].some(e => e.__gptAccountEmailAuthenticatorAttempt !== \(attempt)) ||
                  field.value !== \(value) || !field.checkValidity()) return 'ambiguous';
              if (!enabled(buttons[0])) return 'waiting';
              buttons[0].click();
              return 'submitted';
            })()
            """) as? String
            if result != "waiting" {
                // After filling, replacement or loss of a form must never enable fallback.
                return result == "submitted" ? .submitted : .ambiguous
            }
        }
        return .ambiguous
    }

    static func submitEmail(_ email: String, in session: BrowserSession) async throws -> Bool {
        let value = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.range(of: #"^[^\s@]+@[^\s@]+\.[^\s@]+$"#, options: .regularExpression) != nil else { return false }
        return try await submit(value, kind: .emailEntry, expectedEmail: nil, in: session)
    }

    static func submitCode(_ code: String, expectedEmail: String, in session: BrowserSession) async throws -> Bool {
        guard code.count == 6, code.allSatisfy({ $0 >= "0" && $0 <= "9" }) else { return false }
        let email = expectedEmail.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !email.isEmpty else { return false }
        return try await submit(code, kind: .emailCode, expectedEmail: email, in: session)
    }

    private static func submit(_ value: String, kind: Kind, expectedEmail: String?, in session: BrowserSession) async throws -> Bool {
        try requireTrustedOrigin(session)
        guard authenticationKind(session.webView.url) == nil, isAccountSettings(session.webView.url) else { return false }
        let generation = session.cancellationGeneration
        let expected = try encoded(expectedEmail)
        let input = try encoded(value)
        let attempt = try encoded(UUID().uuidString)
        let validation = """
        \(domHelpers)
        const form = findForm();
        if (form.kind !== '\(kind.rawValue)' || !form.field || !form.button ||
            (\(expected) !== null && form.displayedEmail !== \(expected))) return 'invalid';
        """
        try Task.checkCancellation()
        let filled = try await session.evaluate("""
        (() => {
          \(validation)
          for (const element of [form.root, form.field, form.button]) element.__gptAccountEmailChangeAttempt = \(attempt);
          Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set.call(form.field, \(input));
          form.field.dispatchEvent(new Event('input', {bubbles:true}));
          form.field.dispatchEvent(new Event('change', {bubbles:true}));
          return 'filled';
        })()
        """) as? String
        guard filled == "filled" else { return false }
        while true {
            try Task.checkCancellation()
            guard generation == session.cancellationGeneration else { throw CancellationError() }
            try requireTrustedOrigin(session)
            guard authenticationKind(session.webView.url) == nil, isAccountSettings(session.webView.url) else { return false }
            let result = try await session.evaluate("""
            (() => {
              \(validation)
              if ([form.root, form.field, form.button].some(element => element.__gptAccountEmailChangeAttempt !== \(attempt))) return 'invalid';
              if (form.field.value !== \(input) || !form.field.checkValidity()) return 'invalid';
              if (!enabled(form.button)) return 'waiting';
              form.button.click();
              return 'submitted';
            })()
            """) as? String
            if result != "waiting" { return result == "submitted" }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    private static func requireTrustedOrigin(_ session: BrowserSession) throws {
        guard TrustedChatGPTOrigin.allowsAuthentication(session.webView.url) else {
            throw BrowserSessionError.untrustedOrigin
        }
    }

    private static func isAccountSettings(_ url: URL?) -> Bool {
        guard url?.host?.lowercased() == "chatgpt.com" else { return false }
        return url?.path.lowercased() == "/settings/account" || url?.fragment?.lowercased() == "settings/account"
    }

    private static func authenticationKind(_ url: URL?) -> Kind? {
        guard url?.host?.lowercased() == "auth.openai.com" else { return nil }
        let path = url?.path.lowercased() ?? ""
        if path == "/log-in/password" { return .password }
        if path.contains("email-verification") || path.contains("verify-email") { return .emailChallenge }
        if path.hasPrefix("/mfa-challenge/") { return .totp }
        return .unknown
    }

    private static func encoded<T: Encodable>(_ value: T) throws -> String {
        String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
    }

    // Only the observed account-settings flow is automated. New routes or
    // different confirmation dialogs stay manual until their DOM is verified.
    private static let domHelpers = #"""
    const norm = text => (text || '').trim().replace(/\s+/g, ' ').toLowerCase();
    const visible = e => {
      const r = e.getBoundingClientRect();
      const style = getComputedStyle(e);
      for (let node = e; node; node = node.parentElement) if (getComputedStyle(node).opacity === '0') return false;
      return r.width > 0 && r.height > 0 && style.visibility !== 'hidden' && style.visibility !== 'collapse' &&
        !e.closest('[hidden], [aria-hidden="true"], [inert]');
    };
    const enabled = e => !e.disabled && e.getAttribute('aria-disabled') !== 'true';
    const name = e => norm(e.getAttribute('aria-label') || e.innerText || e.value);
    const accountSettings = () => location.protocol === 'https:' && location.hostname === 'chatgpt.com' &&
      (location.pathname.toLowerCase() === '/settings/account' || location.hash.toLowerCase() === '#settings/account');
    const accountSettingsRoot = () => {
      const dialogs = [...document.querySelectorAll('[role="dialog"], dialog')].filter(visible);
      if (!dialogs.length) return document;
      if (dialogs.length !== 1) return null;
      const root = dialogs[0];
      const headings = [...root.querySelectorAll('h1,h2,h3,[role="heading"]')].filter(visible).map(e => norm(e.innerText));
      if (!headings.some(h => ['settings', 'настройки'].includes(h)) ||
          !headings.some(h => ['account', 'учетная запись', 'учётная запись'].includes(h))) return null;
      const fields = [...root.querySelectorAll('input, textarea, [contenteditable="true"]')].filter(visible)
        .filter(e => !['hidden', 'checkbox', 'radio', 'submit', 'button'].includes(e.type));
      if (fields.some(e => e.tagName !== 'INPUT' || (e.type !== 'search' && e.getAttribute('role') !== 'searchbox') ||
          !['search settings', 'поиск в настройках'].includes(fieldLabel(e)))) return null;
      return root;
    };
    const controlEmail = (e, allowRow = false) => {
      const labels = [e.getAttribute('aria-label'), e.innerText].map(norm);
      const pattern = allowRow
        ? /^(?:(?:change email address|edit email address|изменить адрес электронной почты):\s*|(?:email|электронная почта)\s+)([^\s]+@[^\s]+)$/
        : /^(?:change email address|edit email address|изменить адрес электронной почты):\s*([^\s]+@[^\s]+)$/;
      const addresses = [...new Set([...labels, labels.join(' ')].map(label => label.match(pattern)?.[1]).filter(Boolean))];
      return addresses.length === 1 ? addresses[0] : null;
    };
    const emailControls = root => [...root.querySelectorAll('button, [role="button"]')]
      .filter(visible).filter(e => controlEmail(e, root !== document) !== null);
    const entryHeadings = ['edit email address', 'change email address', 'редактировать адрес электронной почты', 'изменить адрес электронной почты'];
    const codeHeadings = ['подтвердить электронную почту', 'добавить адрес электронной почты', 'verify email', 'verify your email', 'confirm email', 'confirm your email'];
    const entryButtons = ['send verification email', 'send verification code', 'send email verification code', 'отправить код подтверждения по электронной почте', 'отправить письмо с подтверждением'];
    const codeButtons = ['verify', 'verify email', 'verify email address', 'confirm', 'confirm email', 'confirm email address', 'continue',
      'подтвердить', 'подтвердить адрес электронной почты', 'подтвердить email', 'продолжить', 'проверить'];
    const codeLabels = ['code', 'verification code', 'email verification code', '6-digit code', 'код', 'код подтверждения', 'код из письма'];
    const fieldLabel = e => norm(e.getAttribute('aria-label') || [...(e.labels || [])].filter(visible).map(l => l.innerText).join(' ') || e.placeholder);
    const findForm = () => {
      const reject = reason => ({kind:'unknown', diagnostic:reason});
      const unknown = reject('unsupported-layout');
      if (!accountSettings()) {
        const origin = location.protocol === 'https:' && location.hostname === 'chatgpt.com' ? 'chatgpt' : 'other';
        const path = location.pathname.toLowerCase();
        const route = path === '/settings/account/' ? 'account-trailing-slash' :
          (path === '/settings/account' ? 'account' : (path === '/' || path === '' ? 'home' : 'other'));
        const hash = location.hash.toLowerCase() === '#settings/account' ? 'account' : 'other';
        return reject('route:' + origin + ':' + route + ':' + hash);
      }
      const titleNodes = [...document.querySelectorAll('h1,h2,h3,[role="heading"],div,span,p')]
        .filter(visible).filter(e => [...entryHeadings, ...codeHeadings].includes(norm(e.innerText)));
      // The current modal uses plain text for its title. Keep the innermost
      // matching node so a wrapping div and its title span count only once.
      const headings = titleNodes.filter(e => !titleNodes.some(other => other !== e && e.contains(other)));
      if (!headings.length) {
        const root = accountSettingsRoot();
        if (!root) return reject('settings-root');
        const controls = emailControls(root);
        const roots = [document];
        const seen = new Set(roots);
        for (let i = 0; i < roots.length && i < 20; i++) {
          for (const element of roots[i].querySelectorAll('*')) {
            const shadow = element.shadowRoot || window.__gptAccountManagerShadowRoot?.(element);
            if (shadow && !seen.has(shadow)) { seen.add(shadow); roots.push(shadow); }
          }
        }
        const labels = [...entryHeadings, ...codeHeadings];
        const matches = scopes => scopes.flatMap(scope => [...scope.querySelectorAll('h1,h2,h3,h4,h5,h6,[role="heading"],div,span,p')])
          .filter(e => labels.includes(norm(e.innerText)));
        const top = matches([document]);
        const shadow = matches(roots.slice(1));
        const count = predicate => top.filter(predicate).length;
        const opacityZero = element => {
          for (let node = element; node; node = node.parentElement) if (getComputedStyle(node).opacity === '0') return true;
          return false;
        };
        const hasRect = element => { const r = element.getBoundingClientRect(); return r.width > 0 && r.height > 0; };
        const flags = ';rect:' + count(hasRect) + ';opacity-zero:' + count(opacityZero) +
          ';visibility-hidden:' + count(e => ['hidden','collapse'].includes(getComputedStyle(e).visibility)) +
          ';hidden:' + count(e => e.closest('[hidden]') !== null) +
          ';aria-hidden:' + count(e => e.closest('[aria-hidden="true"]') !== null) +
          ';inert:' + count(e => e.closest('[inert]') !== null) +
          ';own-dialog:' + count(e => e.closest('[role="dialog"],dialog') !== null) +
          ';native-modal:' + count(e => e.closest('dialog')?.matches(':modal') === true) +
          ';own-dialog-visible:' + count(e => {const dialog = e.closest('[role="dialog"],dialog'); return dialog && visible(dialog);}) +
          ';own-dialog-unhidden:' + count(e => {const dialog = e.closest('[role="dialog"],dialog'); return dialog && dialog.getAttribute('aria-hidden') === 'false';}) +
          ';visible-frames:' + [...document.querySelectorAll('iframe')].filter(visible).length;
        const diagnostic = 'settings:controls:' + controls.length + ';top-titles:' + top.length +
          ';top-visible:' + top.filter(visible).length + ';shadow-roots:' + (roots.length - 1) +
          ';shadow-titles:' + shadow.length + ';shadow-visible:' + shadow.filter(visible).length + flags;
        return {kind:'accountSettings', displayedEmail: controls.length === 1 ? controlEmail(controls[0], root !== document) : null, diagnostic};
      }
      if (headings.length !== 1) return reject('heading-count:' + headings.length);
      const plainTitle = !headings[0].closest('h1,h2,h3,[role="heading"]');
      let root = headings[0].closest('[role="dialog"], dialog, form');
      const semanticRoot = root;
      if (!root) {
        root = headings[0].parentElement;
        while (root && root !== document.body && ![...root.querySelectorAll('input')].some(visible)) root = root.parentElement;
      }
      if (!root || root === document.body || root === document.documentElement) return reject('root-missing');
      const fields = [...root.querySelectorAll('input')].filter(visible).filter(e => e.type !== 'hidden' && !['checkbox', 'radio', 'submit', 'button'].includes(e.type));
      if (fields.length !== 1) return reject('field-count:' + fields.length);
      if (!enabled(fields[0]) || fields[0].readOnly) return reject('field-unavailable');
      const field = fields[0];
      const buttons = [...root.querySelectorAll('button, input[type="submit"], [role="button"]')].filter(visible);
      if (field.type === 'email') {
        if (!entryHeadings.includes(norm(headings[0].innerText))) return reject('entry-title');
        if (plainTitle) {
          const close = buttons.filter(e => name(e) === 'закрыть модальное окно редактирования электронной почты');
          if (close.length !== 1) return reject('entry-close-count:' + close.length);
          if (!semanticRoot) {
            let closeRoot = close[0].parentElement;
            while (closeRoot && closeRoot !== document.body && ![...closeRoot.querySelectorAll('input')].some(visible)) closeRoot = closeRoot.parentElement;
            if (closeRoot !== root || field.closest('[role="dialog"], dialog, form')) return reject('entry-close-root');
          }
        }
        const submit = buttons.filter(e => entryButtons.includes(name(e)));
        return submit.length === 1 ? {kind:'emailEntry', root, field, button:submit[0]} : reject('entry-submit-count:' + submit.length);
      }
      if (norm(headings[0].innerText) === 'добавить адрес электронной почты') {
        const close = buttons.filter(e => name(e) === 'закрыть модальное окно добавления адреса электронной почты');
        if (close.length !== 1) return reject('code-close-count:' + close.length);
        if (!semanticRoot) {
          let closeRoot = close[0].parentElement;
          while (closeRoot && closeRoot !== document.body && ![...closeRoot.querySelectorAll('input')].some(visible)) closeRoot = closeRoot.parentElement;
          if (closeRoot !== root || field.closest('[role="dialog"], dialog, form')) return reject('code-close-root');
        }
      } else if (plainTitle && !semanticRoot) return reject('code-title-root');
      if (!['text', 'tel', 'number'].includes(field.type) || !codeLabels.includes(fieldLabel(field))) return reject('field-type-or-label');
      // Read visible text nodes so CSS-hidden addresses cannot authorize a code.
      const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
      const text = [];
      while (walker.nextNode()) if (visible(walker.currentNode.parentElement)) text.push(walker.currentNode.textContent);
      if (plainTitle || codeHeadings.includes(norm(headings[0].innerText))) {
        const context = norm(text.join(' '));
        const changingAddress = ['чтобы изменить адрес электронной почты', 'завершить ее обновление',
          'завершить её обновление', 'завершить обновление вашей учетной записи', 'завершить обновление вашей учётной записи',
          'to complete the update', 'to finish updating your email', 'change your email address']
          .some(phrase => context.includes(phrase));
        if (!changingAddress) return reject('code-context');
      }
      const addresses = [...new Set((text.join(' ').match(/[a-z0-9.!#$%&'*+/=?^_`{|}~-]+@[a-z0-9-]+(?:\.[a-z0-9-]+)+/gi) || []).map(norm))];
      const submit = buttons.filter(e => codeButtons.includes(name(e)));
      if (addresses.length !== 1 || submit.length !== 1) return reject('code-address-count:' + addresses.length + ';submit-count:' + submit.length);
      return {kind:'emailCode', displayedEmail:addresses[0], root, field, button:submit[0]};
    };
    """#
}
