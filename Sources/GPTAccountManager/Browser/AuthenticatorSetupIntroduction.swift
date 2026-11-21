import Foundation

@MainActor
enum AuthenticatorSetupIntroduction {
    private enum Step: String { case introduction, key, qrCode }

    static func codeStep(in session: BrowserSession) async throws -> ChatGPTAutomation.ControlResult {
        try Task.checkCancellation()
        guard let url = session.webView.url, TrustedChatGPTOrigin.allowsSecurityAutomation(url) else { return .notFound }
        let generation = session.cancellationGeneration
        let expectedURL = try json(url.absoluteString)
        let raw = try await session.evaluate("""
        (() => {
          const inspect = \(codeInspectionScript);
          return inspect(\(expectedURL)).result;
        })()
        """) as? String
        try Task.checkCancellation()
        guard generation == session.cancellationGeneration else { throw CancellationError() }
        return raw.flatMap(ChatGPTAutomation.ControlResult.init(rawValue:)) ?? .ambiguous
    }

    static func submitCode(_ code: String, in session: BrowserSession) async throws -> ChatGPTAutomation.FormResult {
        try Task.checkCancellation()
        guard code.utf8.count == 6, code.utf8.allSatisfy({ (48...57).contains($0) }),
              let url = session.webView.url, TrustedChatGPTOrigin.allowsSecurityAutomation(url) else { return .notFound }
        let generation = session.cancellationGeneration
        let expectedURL = try json(url.absoluteString)
        let token = try json(UUID().uuidString)
        let value = try json(code)
        let prepared = try await session.evaluate("""
        (() => {
          const inspect = \(codeInspectionScript);
          const state = inspect(\(expectedURL));
          if (state.result !== 'found') return state.result;
          if (!state.form) return 'noForm';
          if (state.field.disabled || state.field.readOnly) return 'notFound';
          const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value')?.set;
          if (!setter) return 'ambiguous';
          window.__gptAccountManagerAuthenticatorCode = {
            token: \(token), document, scope: state.scope, form: state.form, field: state.field
          };
          setter.call(state.field, \(value));
          state.field.dispatchEvent(new Event('input', {bubbles:true}));
          state.field.dispatchEvent(new Event('change', {bubbles:true}));
          return 'filled';
        })()
        """) as? String
        try Task.checkCancellation()
        guard generation == session.cancellationGeneration else { throw CancellationError() }
        guard prepared == "filled" else {
            return prepared.flatMap(ChatGPTAutomation.FormResult.init(rawValue:)) ?? .ambiguous
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            guard generation == session.cancellationGeneration else { throw CancellationError() }
            let raw = try await session.evaluate("""
            (() => {
              const inspect = \(codeInspectionScript);
              const current = inspect(\(expectedURL));
              if (current.result !== 'found') return current.result;
              const pending = window.__gptAccountManagerAuthenticatorCode;
              if (!pending || pending.token !== \(token) || pending.document !== document ||
                  pending.scope !== current.scope || pending.form !== current.form || pending.field !== current.field ||
                  !pending.scope.isConnected || !pending.field.isConnected ||
                  (pending.form && !pending.form.isConnected)) return 'ambiguous';
              if (current.field.value !== \(value)) return 'ambiguous';
              if (!current.button || current.field.disabled || current.field.readOnly ||
                  current.button.disabled || current.button.getAttribute('aria-disabled') === 'true' ||
                  !current.field.checkValidity() || (current.form && !current.form.checkValidity())) return 'waiting';
              delete window.__gptAccountManagerAuthenticatorCode;
              current.button.click();
              return 'submitted';
            })()
            """) as? String
            try Task.checkCancellation()
            guard generation == session.cancellationGeneration else { throw CancellationError() }
            if raw != "waiting" { return raw.flatMap(ChatGPTAutomation.FormResult.init(rawValue:)) ?? .ambiguous }
            try await Task.sleep(for: .milliseconds(50))
        }
        return .notFound
    }

    private static func json(_ value: String) throws -> String {
        String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
    }

    private static let codeInspectionScript = #"""
    expectedURL => {
      const absent = {result:'notFound'};
      if (location.origin !== 'https://chatgpt.com' || location.href !== expectedURL ||
          (location.pathname !== '/settings/security' &&
           !(location.pathname === '/' && location.hash.toLowerCase() === '#settings/security'))) return absent;
      const url = new URL(location.href);
      const unique = name => [...url.searchParams].filter(([key]) => key.toLowerCase() === name);
      const actions = unique('action'), factors = unique('factor');
      if (actions.length !== 1 || actions[0][1] !== 'enable' || factors.length !== 1 || factors[0][1] !== 'totp') return absent;
      const normalize = value => String(value || '').trim().replace(/\s+/g,' ').toLowerCase();
      const shown = element => {
        if (!element || !element.getClientRects().length) return false;
        for (let current = element; current; current = current.parentElement) {
          const style = getComputedStyle(current);
          if (current.hidden || current.hasAttribute('inert') || current.getAttribute('aria-hidden') === 'true' ||
              style.display === 'none' || style.visibility !== 'visible' || style.opacity === '0') return false;
        }
        return true;
      };
      const text = element => {
        const walker = document.createTreeWalker(element,NodeFilter.SHOW_TEXT), parts=[];
        while (walker.nextNode()) if (shown(walker.currentNode.parentElement)) parts.push(walker.currentNode.textContent);
        return normalize(parts.join(' '));
      };
      const headings = [...document.querySelectorAll('h2')].filter(shown).filter(element => text(element) === 'введите код');
      if (!headings.length) return absent;
      if (headings.length !== 1) return {result:'ambiguous'};
      const scope = headings[0].closest('[role="dialog"],dialog');
      if (!scope || !shown(scope)) return absent;
      if ([...document.querySelectorAll('[role="dialog"],dialog')].filter(shown).length !== 1) return {result:'ambiguous'};
      if (!text(scope).includes('чтобы завершить настройку, введите 6-значный код из приложения для аутентификации')) return absent;
      const fields = [...scope.querySelectorAll('input:not([type="hidden"]),textarea,select,[contenteditable]:not([contenteditable="false"])')].filter(shown);
      if (fields.length !== 1) return fields.length ? {result:'ambiguous'} : absent;
      const field = fields[0];
      if (!field.matches('input') || !['text','tel','number'].includes(field.type)) return absent;
      const label = normalize(field.getAttribute('aria-label') || [...(field.labels || [])].filter(shown).map(text).join(' '));
      if (label !== 'код' && field.getAttribute('placeholder') !== '000000') return absent;
      const form = field.form;
      if (form && !scope.contains(form)) return {result:'ambiguous'};
      const buttons = [...scope.querySelectorAll('button,[role="button"],input[type="submit"]')].filter(shown)
        .filter(element => normalize(element.getAttribute('aria-label') || element.innerText || element.value) === 'продолжить');
      if (buttons.length > 1) return {result:'ambiguous'};
      const button = buttons[0] || null;
      const sameOrigin = raw => {
        try { const target = new URL(raw,location.href); return target.origin === location.origin && !target.username && !target.password; }
        catch { return false; }
      };
      if ((form && !sameOrigin(form.action)) || (button && (
          (button.hasAttribute('href') && !sameOrigin(button.getAttribute('href'))) ||
          (button.hasAttribute('formaction') && !sameOrigin(button.getAttribute('formaction'))) ||
          (button.hasAttribute('form') && !button.form) || button.form !== form))) return {result:'ambiguous'};
      return {result:'found',scope,form,field,button};
    }
    """#

    static func selectKey(in session: BrowserSession, click: Bool = true) async throws -> ChatGPTAutomation.ControlResult {
        try await advance(in: session, step: .key, click: click)
    }

    static func advanceQRCode(in session: BrowserSession, click: Bool = true) async throws -> ChatGPTAutomation.ControlResult {
        try await advance(in: session, step: .qrCode, click: click)
    }

    static func advance(in session: BrowserSession, click: Bool = true) async throws -> ChatGPTAutomation.ControlResult {
        try await advance(in: session, step: .introduction, click: click)
    }

    private static func advance(in session: BrowserSession, step: Step, click: Bool) async throws -> ChatGPTAutomation.ControlResult {
        try Task.checkCancellation()
        guard let url = session.webView.url,
              TrustedChatGPTOrigin.allowsSecurityAutomation(url),
              url.path == "/settings/security" ||
                (url.path == "/" && url.fragment?.lowercased() == "settings/security")
        else { return .notFound }
        let generation = session.cancellationGeneration
        let expectedURL = String(decoding: try JSONEncoder().encode(url.absoluteString), as: UTF8.self)
        let raw = try await session.evaluate(#"""
        (() => {
          const expectedURL = \#(expectedURL);
          const step = '\#(step.rawValue)';
          if (location.origin !== 'https://chatgpt.com' || location.href !== expectedURL) return 'notFound';
          if (location.pathname !== '/settings/security' &&
              !(location.pathname === '/' && location.hash.toLowerCase() === '#settings/security')) return 'notFound';
          const normalize = value => String(value || '').trim().replace(/\s+/g, ' ').toLowerCase();
          const shown = element => {
            if (!element || !element.getClientRects().length) return false;
            for (let current = element; current; current = current.parentElement) {
              const style = getComputedStyle(current);
              if (current.hidden || current.hasAttribute('inert') || current.getAttribute('aria-hidden') === 'true' ||
                  style.display === 'none' || style.visibility !== 'visible' || style.opacity === '0') return false;
            }
            return true;
          };
          const visibleText = element => {
            const walker = document.createTreeWalker(element, NodeFilter.SHOW_TEXT), parts = [];
            while (walker.nextNode()) if (shown(walker.currentNode.parentElement)) parts.push(walker.currentNode.textContent);
            return normalize(parts.join(' '));
          };
          const headings = [...document.querySelectorAll('h2')].filter(shown)
            .filter(element => visibleText(element) === (step === 'introduction'
              ? 'настройка приложения для аутентификации' : 'добавьте свою учетную запись в приложение'));
          if (!headings.length) return 'notFound';
          if (headings.length !== 1) return 'ambiguous';
          const scope = headings[0].closest('[role="dialog"],dialog');
          if (!scope || !shown(scope)) return 'notFound';
          if ([...document.querySelectorAll('[role="dialog"],dialog')].filter(shown).length !== 1) return 'ambiguous';
          const context = step === 'introduction'
            ? 'вам понадобится приложение для аутентификации или менеджер паролей, который генерирует коды подтверждения. используйте приложение, которое у вас уже есть, или скачайте одно из следующих:'
            : 'скопируйте ключ настройки и вставьте его в приложение для аутентификации или отсканируйте qr-код с помощью этого приложения';
          if (!visibleText(scope).includes(context)) return 'notFound';
          if ([...scope.querySelectorAll('input:not([type="hidden"]),textarea,select,[contenteditable]:not([contenteditable="false"])')].some(shown)) return 'notFound';
          const controls = [...scope.querySelectorAll('button,[role="button"],[role="radio"],[role="tab"]')].filter(shown)
            .filter(element => normalize(element.getAttribute('aria-label') || element.innerText) === (step === 'key' ? 'ключ' : 'продолжить'));
          if (!controls.length) return 'found';
          if (controls.length !== 1) return 'ambiguous';
          const control = controls[0];
          const sameOrigin = raw => {
            try { const target = new URL(raw, location.href); return target.origin === location.origin && !target.username && !target.password; }
            catch { return false; }
          };
          if ((control.hasAttribute('href') && !sameOrigin(control.getAttribute('href'))) ||
              (control.hasAttribute('formaction') && !sameOrigin(control.getAttribute('formaction'))) ||
              (control.hasAttribute('form') && !control.form) ||
              (control.form && (!scope.contains(control.form) || !sameOrigin(control.form.action)))) return 'ambiguous';
          if (control.disabled || control.getAttribute('aria-disabled') === 'true') return 'found';
          if (step === 'key') {
            const states = ['aria-pressed','aria-selected','aria-checked']
              .filter(name => control.hasAttribute(name)).map(name => control.getAttribute(name));
            if (!states.length || states.some(value => value !== 'true' && value !== 'false') || new Set(states).size !== 1) return 'ambiguous';
            if (states[0] === 'true') return 'found';
          }
          if (!\#(click ? "true" : "false")) return 'found';
          if (location.href !== expectedURL || !control.isConnected || !shown(control)) return 'notFound';
          control.click();
          return 'clicked';
        })()
        """#) as? String
        try Task.checkCancellation()
        guard generation == session.cancellationGeneration else { throw CancellationError() }
        return raw.flatMap(ChatGPTAutomation.ControlResult.init(rawValue:)) ?? .ambiguous
    }
}
