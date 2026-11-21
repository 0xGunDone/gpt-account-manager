import Foundation

@MainActor
enum CodexConsentForm {
    enum Outcome: String, Equatable {
        case notFound, waiting, selected, submitted
    }

    static func advance(email: String, in session: BrowserSession) async throws -> Outcome {
        try Task.checkCancellation()
        guard let url = session.webView.url,
              TrustedChatGPTOrigin.allowsAuthentication(url),
              url.host?.lowercased() == "auth.openai.com",
              ["/codex/consent", "/sign-in-with-chatgpt/codex/consent"].contains(url.path)
        else { return .notFound }
        let expected = String(decoding: try JSONEncoder().encode(email.lowercased()), as: UTF8.self)
        let expectedURL = String(decoding: try JSONEncoder().encode(url.absoluteString), as: UTF8.self)
        let value = try await session.evaluate(#"""
        (() => {
          if (location.origin !== 'https://auth.openai.com' || location.href !== new URL(\#(expectedURL)).href) return 'notFound';
          const chatGPTConsent = location.pathname === '/sign-in-with-chatgpt/codex/consent';
          if (!chatGPTConsent && location.pathname !== '/codex/consent') return 'notFound';
          const shown = e => {
            if (!e || e.closest('[hidden],[aria-hidden="true"],[inert]')) return false;
            const r = e.getBoundingClientRect();
            if (r.width <= 0 || r.height <= 0 || getComputedStyle(e).visibility !== 'visible') return false;
            for (let p = e; p; p = p.parentElement) if (getComputedStyle(p).opacity === '0') return false;
            return true;
          };
          const text = e => (e.innerText || e.value || e.getAttribute('aria-label') || '').trim().replace(/\s+/g, ' ');
          const visibleText = e => {
            const walker = document.createTreeWalker(e, NodeFilter.SHOW_TEXT);
            const parts = [];
            while (walker.nextNode()) if (shown(walker.currentNode.parentElement)) parts.push(walker.currentNode.textContent);
            return parts.join(' ').trim().replace(/\s+/g, ' ');
          };
          const enabled = e => !e.disabled && e.getAttribute('aria-disabled') !== 'true';
          const emails = e => {
            const walker = document.createTreeWalker(e, NodeFilter.SHOW_TEXT);
            const visible = [];
            while (walker.nextNode()) if (shown(walker.currentNode.parentElement)) visible.push(walker.currentNode.textContent);
            return [...new Set(visible.join(' ').toLowerCase().match(/[a-z0-9.!#$%&'*+/=?^_`{|}~-]+@[a-z0-9.-]+\.[a-z]{2,}/g) || [])];
          };
          const sameOrigin = raw => {
            try { const u = new URL(raw, location.href); return u.origin === location.origin && !u.username && !u.password; }
            catch { return false; }
          };
          const safeDestination = e =>
            (!e.hasAttribute('href') || sameOrigin(e.getAttribute('href'))) &&
            (!e.form || sameOrigin(e.form.action)) &&
            (!e.hasAttribute('formaction') || sameOrigin(e.getAttribute('formaction')));
          const codexHeading = /^(Sign in to Codex|Войти в Codex|Вход в Codex)$/i;
          const chatGPTHeading = /^(Sign in to Codex (?:with|using) ChatGPT|Вход в Codex с помощью ChatGPT|Войти в Codex с помощью ChatGPT)$/i;
          if (chatGPTConsent && !chatGPTHeading.test(document.title.trim().replace(/\s+-\s+OpenAI$/i, ''))) return 'notFound';
          const headingSelector = chatGPTConsent ? 'h1,h2,[role="heading"],div' : 'h1,h2,[role="heading"]';
          const matchesHeading = e => (chatGPTConsent ? chatGPTHeading : codexHeading).test(text(e));
          const headings = [...document.querySelectorAll(headingSelector)].filter(shown).filter(matchesHeading)
            .filter(e => ![...e.querySelectorAll(headingSelector)].filter(shown).some(matchesHeading));
          const namedForms = chatGPTConsent ? [...document.querySelectorAll('form[aria-label]')]
            .filter(shown).filter(e => chatGPTHeading.test(e.getAttribute('aria-label').trim())) : [];
          if (headings.length > 1 || namedForms.length > 1 || (!headings.length && !namedForms.length)) return 'notFound';
          const isContinue = e => !e.matches('[role="radio"]') && /^(Continue|Продолжить|Allow|Разрешить)$/i.test(text(e));
          let scope = namedForms[0] || headings[0]?.closest('form,[role="dialog"],main');
          if (namedForms.length && headings.length && !scope.contains(headings[0])) return 'notFound';
          if (!scope && chatGPTConsent) {
            scope = headings[0].parentElement;
            while (scope && scope !== document.body && (!emails(scope).length ||
              ![...scope.querySelectorAll('button,input[type="submit"]')].filter(shown).some(isContinue))) scope = scope.parentElement;
            if (scope === document.body) return 'notFound';
          }
          if (!scope) return 'notFound';
          const found = emails(scope);
          if (found.length !== 1 || found[0] !== \#(expected)) return 'notFound';
          const inputs = [...scope.querySelectorAll('input:not([type="hidden"]),textarea,select,[contenteditable="true"]')].filter(shown);
          if (inputs.some(e => !chatGPTConsent || !e.matches('input[type="radio"]'))) return 'notFound';
          const controls = [...scope.querySelectorAll('button,input[type="submit"]')].filter(shown).filter(isContinue);
          if (controls.length !== 1 || !safeDestination(controls[0])) return 'notFound';
          const control = controls[0];
          const scopedForm = e => !e.form || e.form === scope || scope.contains(e.form);
          if ((!control.form && !chatGPTConsent) || !scopedForm(control)) return 'notFound';
          if (chatGPTConsent) {
            // Styled native radios can be transparent; their visible labels are the click targets.
            const visibleLabels = e => [...(e.labels || [])].filter(l => scope.contains(l) && shown(l));
            const styledRadio = e => e.matches('input[type="radio"]') &&
              !e.closest('[hidden],[aria-hidden="true"],[inert]') && getComputedStyle(e).visibility === 'visible' &&
              e.getBoundingClientRect().width > 0 && e.getBoundingClientRect().height > 0 && visibleLabels(e).length > 0;
            const workspaces = [...scope.querySelectorAll('input[type="radio"],[role="radio"]')]
              .filter(e => shown(e) || styledRadio(e));
            const label = e => {
              if (e.labels?.length) {
                const labels = [...e.labels];
                return labels.every(l => scope.contains(l) && shown(l)) ? labels.map(visibleText).join(' ') : '';
              }
              if (e.hasAttribute('aria-labelledby')) {
                const ids = e.getAttribute('aria-labelledby').trim().split(/\s+/);
                const labels = ids.map(id => document.getElementById(id));
                return ids.length <= 4 && labels.every(l => l && scope.contains(l) && shown(l)) ? labels.map(visibleText).join(' ') : '';
              }
              return e.getAttribute('aria-label') || text(e.closest('label') || e);
            };
            const personal = workspaces.filter(e => /^(Personal account|Личная уч[её]тная запись)$/i.test(label(e).trim()));
            if (personal.length !== 1) return 'notFound';
            const workspace = personal[0];
            const selected = e => e.matches('input[type="radio"]') ? e.checked : e.getAttribute('aria-checked') === 'true';
            if (!selected(workspace)) {
              if (!enabled(workspace) || !safeDestination(workspace) || !scopedForm(workspace) ||
                (workspace.matches('button') && workspace.type !== 'button')) return 'notFound';
              const target = shown(workspace) ? workspace : visibleLabels(workspace)[0];
              if (!target || !safeDestination(target)) return 'notFound';
              target.click();
              // Selection can enable Continue asynchronously; retry without marking this URL submitted.
              return 'selected';
            }
            if (workspaces.some(e => e !== workspace && selected(e))) return 'notFound';
          }
          if (!enabled(control)) return 'waiting';
          control.click();
          return 'submitted';
        })()
        """#) as? String
        return value.flatMap(Outcome.init(rawValue:)) ?? .notFound
    }
}
