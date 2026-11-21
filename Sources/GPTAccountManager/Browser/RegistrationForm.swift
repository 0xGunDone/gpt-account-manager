import Foundation

enum RegistrationMFAResult: Equatable {
    case enabled(secret: String)
    case manual(String)
    case failure(String)
}

@MainActor
enum RegistrationForm {
    enum Kind: String { case entry, email, password, emailCode, profile, authenticated, challenge, registrationRejected, unknown }

    static let rejectionMessage = "OpenAI отказал в создании аккаунта по условиям использования. Регистрация остановлена; данные и сессия сохранены."

    enum ProfileRetryError: Error { case exhausted }

    struct State: Equatable {
        let kind: Kind
        let text: String
        let displayedEmail: String?
        let isCreatingPassword: Bool
        let pageURL: URL?
        let profileRequiresBirthDate: Bool

        init(kind: Kind, text: String, displayedEmail: String?, isCreatingPassword: Bool, pageURL: URL?, profileRequiresBirthDate: Bool = false) {
            self.kind = kind
            self.text = text
            self.displayedEmail = displayedEmail
            self.isCreatingPassword = isCreatingPassword
            self.pageURL = pageURL
            self.profileRequiresBirthDate = profileRequiresBirthDate
        }
    }

    static func inspect(in session: BrowserSession) async throws -> State {
        try requireTrustedOrigin(session)
        let raw = try await session.evaluate("""
        (async () => {
          \(domHelpers)
          const pageURL = location.href;
          const form = findForm();
          if (trusted() && location.hostname === 'chatgpt.com' && !challenge()) {
            try {
              const response = await fetch('/api/auth/session', {credentials:'include'});
              const value = response.ok ? await response.json() : null;
              if (value?.user?.email) return {kind:'authenticated', displayedEmail:value.user.email, pageURL};
            } catch {}
          }
          return {kind:form.kind, displayedEmail:form.displayedEmail || null, pageURL, profileRequiresBirthDate:!!form.birthday,
            isCreatingPassword:form.kind === 'password' && location.pathname === '/create-account/password'};
        })()
        """) as? [String: Any]
        let kind = (raw?["kind"] as? String).flatMap(Kind.init(rawValue:)) ?? .unknown
        return State(kind: kind, text: kind.rawValue, displayedEmail: raw?["displayedEmail"] as? String,
                     isCreatingPassword: raw?["isCreatingPassword"] as? Bool ?? false,
                     pageURL: (raw?["pageURL"] as? String).flatMap(URL.init(string:)),
                     profileRequiresBirthDate: raw?["profileRequiresBirthDate"] as? Bool ?? false)
    }

    static func clickSignUp(in session: BrowserSession) async throws -> Bool {
        try await clickControl(passwordPath: nil, in: session)
    }

    static func selectPasswordSignup(in session: BrowserSession) async throws -> Bool {
        try await clickControl(passwordPath: "/create-account/password", in: session)
    }

    static func selectPasswordLogin(in session: BrowserSession) async throws -> Bool {
        try await clickControl(passwordPath: "/log-in/password", in: session)
    }

    static func selectRememberedAccount(_ email: String, in session: BrowserSession) async throws -> Bool {
        try requireTrustedOrigin(session)
        guard session.webView.url?.host == "chatgpt.com",
              ["/", "/auth/login"].contains(session.webView.url?.path ?? "") else { return false }
        let encoded = String(decoding: try JSONEncoder().encode(email.lowercased()), as: UTF8.self)
        return try await session.evaluate("""
        (() => {
          \(domHelpers)
          if (location.origin !== 'https://chatgpt.com' || !['/','/auth/login'].includes(location.pathname) || challenge()) return false;
          const headings = [...document.querySelectorAll('h1,h2,h3,[role="heading"]')].filter(visible);
          if (!headings.some(e => /^(welcome back!?|с возвращением!?)$/i.test(text(e).trim()))) return false;
          const expected = \(encoded);
          const candidates = [...document.querySelectorAll('button,[role="button"]')].filter(visible).filter(enabled).filter(e => {
            const label = text(e);
            if (/remove|delete|удалить/i.test(e.getAttribute('aria-label') || label)) return false;
            const addresses = [...new Set((label.match(/[a-z0-9.!#$%&'*+\\x2f=?^_`{|}~-]+@[a-z0-9-]+(?:\\.[a-z0-9-]+)+/gi) || []).map(e=>e.toLowerCase()))];
            return addresses.length === 1 && addresses[0] === expected;
          });
          if (candidates.length === 1) { candidates[0].click(); return true; }
          if (candidates.length > 1) return false;
          const other = [...document.querySelectorAll('button,[role="button"]')].filter(visible).filter(enabled)
            .filter(e => ['use another account','log in to another account','войти в другую учетную запись','войти в другую учётную запись'].includes(text(e).trim().toLowerCase()));
          if (other.length !== 1) return false;
          other[0].click(); return true;
        })()
        """) as? Bool == true
    }

    private static func clickControl(passwordPath: String?, in session: BrowserSession) async throws -> Bool {
        try requireTrustedOrigin(session)
        try Task.checkCancellation()
        let pathJSON = String(decoding: try JSONEncoder().encode(passwordPath), as: UTF8.self)
        return try await session.evaluate("""
        (() => {
          \(domHelpers)
          if (!trusted() || challenge()) return false;
          const passwordPath = \(pathJSON);
          const password = passwordPath !== null;
          const loginPassword = passwordPath === '/log-in/password';
          const loginMethod = auth() && ['/log-in','/log-in-or-create-account'].includes(location.pathname);
          if (password ? !(emailCodeRoute() || loginPassword && loginMethod) : !entryRoute()) return false;
          const labels = loginPassword ? [...passwordLabels, 'continue with a password', 'log in with password', 'log in with a password',
            'войти с паролем', 'вход с паролем', 'войти с помощью пароля'] : password ? passwordLabels : signupLabels;
          const controls = [...document.querySelectorAll('button,a,[role="button"]')]
            .filter(visible).filter(enabled).filter(e => labels.includes(name(e)))
            .filter(e => {
              if (loginPassword && (e.form || e.hasAttribute('formaction'))) {
                const action = new URL(e.getAttribute('formaction') || e.form?.action || location.href, location.href);
                if (action.origin !== location.origin || action.username || action.password) return false;
              }
              if (!e.hasAttribute('href')) return true;
              const url = new URL(e.getAttribute('href'), location.href);
              return password
                ? url.origin === 'https://auth.openai.com' && url.pathname === passwordPath
                : ['https://chatgpt.com','https://auth.openai.com'].includes(url.origin);
            });
          if (controls.length !== 1) return false;
          controls[0].click();
          return true;
        })()
        """) as? Bool == true
    }

    static func submitEmail(_ email: String, in session: BrowserSession) async throws -> Bool {
        let email = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard email.range(of: #"^[^\s@]+@[^\s@]+\.[^\s@]+$"#, options: .regularExpression) != nil else { return false }
        return try await submit([email], kind: .email, in: session)
    }

    static func submitPassword(_ password: String, in session: BrowserSession) async throws -> Bool {
        guard !password.isEmpty else { return false }
        return try await submit([password], kind: .password, in: session)
    }

    static func submitEmailCode(_ code: String, expectedEmail: String, observedScreenOnly: Bool = false,
                                observedScreenToken: String? = nil, in session: BrowserSession) async throws -> Bool {
        guard code.count == 6, code.allSatisfy({ $0 >= "0" && $0 <= "9" }) else { return false }
        return try await submit([code], kind: .emailCode, expectedEmail: expectedEmail.lowercased(),
                                requireObservedEmailScreen: observedScreenOnly,
                                observedEmailScreenToken: observedScreenToken, in: session)
    }

    static func emailCodeScreenMatches(in session: BrowserSession, expectedEmail: String,
                                      pageURL: URL, token: String, capture: Bool = false,
                                      identityKey: String = "__gptAccountManagerMailWait") async throws -> Bool {
        try requireTrustedOrigin(session)
        try Task.checkCancellation()
        let arguments = String(decoding: try JSONEncoder().encode([pageURL.absoluteString, expectedEmail.lowercased(), token, identityKey]), as: UTF8.self)
        return try await session.evaluate("""
        (() => {
          \(domHelpers)
          const [expectedURL, expectedEmail, token, identityKey] = \(arguments);
          if (location.href !== expectedURL) return false;
          const form = findForm();
          if (form.kind !== 'emailCode' || form.displayedEmail !== expectedEmail) return false;
          const external = identityKey === '__gptAccountManagerExternalMailWait';
          if (external && (!sameOriginEmailCodeForm(form) || (\(capture ? "true" : "false") && form.fields.some(field => field.value)))) return false;
          const elements = [form.button, ...form.fields];
          if (\(capture ? "true" : "false")) {
            const identity = {token, pageURL:location.href, elements:elements.map(element => new WeakRef(element))};
            document[identityKey] = identity;
            if (external) {
              const controller = new AbortController();
              const options = {capture:true, signal:controller.signal};
              const invalidate = () => {
                if (document[identityKey] === identity) delete document[identityKey];
                controller.abort();
              };
              document.addEventListener('click', event => {
                if (event.target instanceof Element && event.target.closest('button,a,[role="button"], input[type="submit"]')) invalidate();
              }, options);
              document.addEventListener('input', event => {
                if (event.isTrusted && form.fields.includes(event.target)) invalidate();
              }, options);
            }
          }
          const identity = document[identityKey];
          return identity?.token === token && identity.pageURL === location.href && identity.elements.length === elements.length &&
            identity.elements.every((reference, index) => reference.deref() === elements[index]);
        })()
        """) as? Bool == true
    }

    static func externalEmailCodeScreenMatches(in session: BrowserSession, expectedEmail: String,
                                               pageURL: URL, token: String, capture: Bool = false) async throws -> Bool {
        try await emailCodeScreenMatches(in: session, expectedEmail: expectedEmail, pageURL: pageURL, token: token,
                                         capture: capture, identityKey: "__gptAccountManagerExternalMailWait")
    }

    static func submitProfile(fullName: String, age: Int, birthDate: String? = nil, in session: BrowserSession) async throws -> Bool {
        guard !fullName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, (18...100).contains(age) else { return false }
        return try await submit([fullName, String(age)], kind: .profile, birthDate: birthDate, in: session)
    }

    static func fillProfile(fullName: String, age: Int, birthDate: String? = nil, in session: BrowserSession) async throws -> Bool {
        guard !fullName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, (18...100).contains(age) else { return false }
        return try await submit([fullName, String(age)], kind: .profile, birthDate: birthDate, shouldSubmit: false, in: session)
    }

    static func retryRejectedProfile(
        fullName: String, age: Int, in session: BrowserSession,
        beforeSubmission: @MainActor () throws -> Void
    ) async throws -> Bool {
        try Task.checkCancellation()
        try requireTrustedOrigin(session)
        guard session.webView.url?.host == "auth.openai.com", session.webView.url?.path == "/about-you",
              !fullName.isEmpty, (18...100).contains(age) else { return false }
        let generation = session.cancellationGeneration
        let page = String(decoding: try JSONEncoder().encode(session.webView.url!.absoluteString), as: UTF8.self)
        let values = String(decoding: try JSONEncoder().encode([fullName, String(age)]), as: UTF8.self)
        let validation = """
        \(domHelpers)
        if (location.href !== new URL(\(page)).href || findForm().kind !== 'registrationRejected') return false;
        const form = findForm(true), expected = \(values);
        if (form.kind !== 'profile' || !enabled(form.button) ||
            form.fields.some((field,index) => field.value !== expected[index] || !field.checkValidity())) return false;
        const owner = form.fields[0].form;
        if (!owner || form.button.form !== owner || form.button.type !== 'submit' ||
            form.fields.some(field => field.form !== owner)) return false;
        const action = new URL(form.button.getAttribute('formaction') || owner.action, location.href);
        if (action.origin !== location.origin || action.username || action.password) return false;
        """
        guard try await session.evaluate("(() => { \(validation) return true; })()") as? Bool == true else { return false }
        try Task.checkCancellation()
        guard generation == session.cancellationGeneration else { throw CancellationError() }
        // Persist before clicking; an uncertain response must not cause another retry after restart.
        try beforeSubmission()
        try Task.checkCancellation()
        guard generation == session.cancellationGeneration else { throw CancellationError() }
        return try await session.evaluate("""
        (() => {
          \(validation)
          let submitted = false;
          const observe = event => { if (event.target === owner) submitted = true; };
          owner.addEventListener('submit', observe, true);
          try { form.button.click(); }
          finally { owner.removeEventListener('submit', observe, true); }
          return submitted;
        })()
        """) as? Bool == true
    }

    private static func submit(_ values: [String], kind: Kind, expectedEmail: String? = nil,
                               birthDate: String? = nil, shouldSubmit: Bool = true,
                               requireObservedEmailScreen: Bool = false, observedEmailScreenToken: String? = nil,
                               in session: BrowserSession) async throws -> Bool {
        try requireTrustedOrigin(session)
        if let birthDate {
            guard birthDate.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil else { return false }
            let formatter = DateFormatter()
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "yyyy-MM-dd"
            formatter.isLenient = false
            guard let date = formatter.date(from: birthDate), formatter.string(from: date) == birthDate, date <= Date() else { return false }
        }
        let generation = session.cancellationGeneration
        let pageURL = session.webView.url
        let pageJSON = String(decoding: try JSONEncoder().encode(pageURL?.absoluteString), as: UTF8.self)
        let valuesJSON = String(decoding: try JSONEncoder().encode(values), as: UTF8.self)
        let emailJSON = String(decoding: try JSONEncoder().encode(expectedEmail), as: UTF8.self)
        let birthdayJSON = String(decoding: try JSONEncoder().encode(birthDate), as: UTF8.self)
        let tokenJSON = String(decoding: try JSONEncoder().encode(observedEmailScreenToken), as: UTF8.self)
        let validation = """
        \(domHelpers)
        if (location.href !== new URL(\(pageJSON)).href) return 'invalid';
        const form = findForm();
        const values = \(valuesJSON);
        if (form.kind !== '\(kind.rawValue)' || !form.fields || !form.button ||
            ('\(kind.rawValue)' === 'password' && location.pathname !== '/create-account/password') ||
            (\(emailJSON) !== null && form.displayedEmail !== \(emailJSON))) return 'invalid';
        const token = \(tokenJSON);
        if (\(requireObservedEmailScreen ? "true" : "false") || token !== null) {
          const identity = token === null ? document.__gptAccountManagerMailWait : document.__gptAccountManagerExternalMailWait;
          const elements = [form.button, ...form.fields];
          if (!identity || (token !== null && (identity.token !== token || identity.pageURL !== location.href || !sameOriginEmailCodeForm(form))) ||
              identity.elements.length !== elements.length ||
              identity.elements.some((reference, index) => reference.deref() !== elements[index])) return 'invalid';
        }
        const birthday = \(birthdayJSON);
        if (form.birthday && birthday === null) return 'invalid';
        const inputs = form.birthday ? [values[0],...(form.birthday.native ? [birthday] : birthday.split('-'))] :
          form.kind === 'emailCode' && form.fields.length === 6 ? values[0].split('') : values;
        if (inputs.length !== form.fields.length) return 'invalid';
        """
        try Task.checkCancellation()
        let filled = try await session.evaluate("""
        (async () => {
          \(validation)
          for (let index = 0; index < form.fields.length; index++) {
            const field = form.fields[index];
            if (location.href !== new URL(\(pageJSON)).href || findForm().fields?.[index] !== field) return 'invalid';
            let focused = false, focusedIn = false;
            const onFocus = () => { focused = true; };
            const onFocusIn = () => { focusedIn = true; };
            field.addEventListener('focus',onFocus);
            field.addEventListener('focusin',onFocusIn);
            field.focus();
            field.removeEventListener('focus',onFocus);
            field.removeEventListener('focusin',onFocusIn);
            if (!focused) field.dispatchEvent(new FocusEvent('focus'));
            if (!focusedIn) field.dispatchEvent(new FocusEvent('focusin',{bubbles:true}));
            if (field.isContentEditable) {
              // DateField segments own their React state. Text changes alone leave
              // their submitted hidden date unchanged; use the segment key handler.
              for (const key of ['Backspace',...String(Number(inputs[index]))]) {
                if (location.href !== new URL(\(pageJSON)).href || findForm().fields?.[index] !== field) return 'invalid';
                field.dispatchEvent(new KeyboardEvent('keydown',{key,code:/^[0-9]$/.test(key)?'Digit'+key:key,bubbles:true,cancelable:true}));
                field.dispatchEvent(new KeyboardEvent('keyup',{key,bubbles:true}));
                await new Promise(resolve => setTimeout(resolve,0));
              }
              field.dispatchEvent(new InputEvent('input',{bubbles:true,inputType:'insertText',data:inputs[index]}));
            } else if (field.value !== inputs[index]) {
              let value = inputs[index];
              if (field.tagName === 'SELECT') {
                const options = [...field.options].filter(o => o.value !== '' && Number(o.value) === Number(value));
                if (options.length !== 1) return 'invalid';
                value = options[0].value;
              }
              Object.getOwnPropertyDescriptor(field.tagName === 'SELECT' ? HTMLSelectElement.prototype : HTMLInputElement.prototype,'value').set.call(field, value);
              field.dispatchEvent(new Event('input',{bubbles:true}));
              field.dispatchEvent(new Event('change',{bubbles:true}));
            }
            let blurred = false, focusedOut = false;
            const onBlur = () => { blurred = true; };
            const onFocusOut = () => { focusedOut = true; };
            field.addEventListener('blur', onBlur);
            field.addEventListener('focusout', onFocusOut);
            field.blur();
            field.removeEventListener('blur', onBlur);
            field.removeEventListener('focusout', onFocusOut);
            // Background WebViews may not acquire native focus, but controlled
            // fields still need their blur validation before Continue.
            if (!blurred) field.dispatchEvent(new FocusEvent('blur'));
            if (!focusedOut) field.dispatchEvent(new FocusEvent('focusout',{bubbles:true}));
          }
          return 'filled';
        })()
        """) as? String
        guard filled == "filled" else { return false }
        var usedNativeBirthdayInput = false
        for _ in 0..<20 {
            try Task.checkCancellation()
            guard generation == session.cancellationGeneration else { throw CancellationError() }
            try requireTrustedOrigin(session)
            let result = try await session.evaluate("""
            (() => {
              \(validation)
              const nativeBirthday = form.birthday && form.fields.slice(1).every(field => field.isContentEditable);
              if (form.fields.some((field,index) => field.isContentEditable
                  ? Number(field.getAttribute('aria-valuenow')) !== Number(inputs[index])
                  : (form.birthday && !form.birthday.native && index > 0 ? Number(field.value) !== Number(inputs[index]) : field.value !== inputs[index]) || !field.checkValidity())) return nativeBirthday ? 'nativeBirthday' : 'invalid';
              if (form.birthday?.hidden && form.birthday.hidden.value !== birthday) return nativeBirthday ? 'nativeBirthday' : 'waiting';
              if (!\(shouldSubmit ? "true" : "false")) return 'submitted';
              if (!enabled(form.button)) return 'waiting';
              // A cancelled click can leave a native submit button inert while
              // the page initializes. Only a submit event proves that attempt.
              const owner = form.button.form;
              const nativeSubmit = owner && form.button.type === 'submit';
              let submitted = false;
              const observe = event => { if (event.target === owner) submitted = true; };
              if (nativeSubmit) owner.addEventListener('submit', observe, true);
              try { form.button.click(); }
              finally { if (nativeSubmit) owner.removeEventListener('submit', observe, true); }
              return !nativeSubmit || submitted ? 'submitted' : 'invalid';
            })()
            """) as? String
            if result == "nativeBirthday" {
                try Task.checkCancellation()
                guard generation == session.cancellationGeneration else { throw CancellationError() }
                guard !usedNativeBirthdayInput, let birthDate, let pageURL, session.webView.url == pageURL else { return false }
                usedNativeBirthdayInput = true
                guard await session.fillBirthdayUsingKeyboard(birthDate, expectedURL: pageURL, expectedName: values[0]) else { return false }
                continue
            }
            if result != "waiting" { return result == "submitted" }
            try await Task.sleep(for: .milliseconds(50))
        }
        return false
    }

    private static func requireTrustedOrigin(_ session: BrowserSession) throws {
        guard TrustedChatGPTOrigin.allowsAuthentication(session.webView.url) else {
            throw BrowserSessionError.untrustedOrigin
        }
    }

    private static let domHelpers = #"""
    const norm = value => String(value || '').trim().replace(/\s+/g,' ').toLowerCase();
    const visible = e => {
      if (!e || !e.getClientRects().length) return false;
      for (let node = e; node; node = node.parentElement) {
        const s = getComputedStyle(node);
        if (node.hidden || node.getAttribute('aria-hidden') === 'true' || node.hasAttribute('inert') ||
            s.display === 'none' || s.visibility === 'hidden' || s.visibility === 'collapse' || s.opacity === '0') return false;
      }
      return true;
    };
    const enabled = e => !e.disabled && e.getAttribute('aria-disabled') !== 'true';
    const name = e => norm(e.getAttribute('aria-label') || e.innerText || e.value);
    const text = root => {
      const walker = document.createTreeWalker(root,NodeFilter.SHOW_TEXT);
      const parts = [];
      while (walker.nextNode()) if (visible(walker.currentNode.parentElement)) parts.push(walker.currentNode.textContent);
      return parts.join(' ');
    };
    const challenge = () => /verify (you are|that you are) human|captcha|провер.{0,15}что вы человек|подтвердите.{0,15}человек/i.test(text(document.body)) ||
      [...document.querySelectorAll('iframe')].some(e => visible(e) && /captcha|challenges.cloudflare/.test(e.src));
    const trusted = () => ['https://chatgpt.com','https://auth.openai.com'].includes(location.origin);
    const auth = () => location.origin === 'https://auth.openai.com';
    const entryRoute = () => auth() ? ['/','/log-in','/create-account'].includes(location.pathname)
      : location.hostname === 'chatgpt.com' && ['/','/auth/login','/auth/signup'].includes(location.pathname);
    const emailCodeRoute = () => auth() && /^\/(email-verification|verify-email)(\/|$)/.test(location.pathname);
    const sameOriginEmailCodeForm = form => {
      const owner = form.fields[0].form;
      if (!owner || form.button.form !== owner || form.fields.some(field => field.form !== owner)) return false;
      const action = new URL(form.button.getAttribute('formaction') || owner.action, location.href);
      return action.origin === location.origin && !action.username && !action.password;
    };
    const signupLabels = ['sign up','sign up for free','create account','зарегистрироваться','зарегистрироваться бесплатно','бесплатная регистрация','создать аккаунт'];
    const passwordLabels = ['continue with password','продолжить с паролем','продолжить с помощью пароля'];
    const primaryLabels = ['continue','next','submit','verify','confirm','create account','продолжить','далее','подтвердить','проверить','создать аккаунт'];
    const label = e => norm([e.name,e.id,e.placeholder,e.getAttribute('aria-label'),...[...(e.labels || [])].filter(visible).map(l=>l.innerText)].join(' '));
    const editable = e => visible(e) && enabled(e) && !e.readOnly && !['hidden','checkbox','radio','submit','button'].includes(e.type);
    const accessible = e => norm([e.getAttribute('aria-label'),
      ...(e.getAttribute('aria-labelledby') || '').split(/\s+/).map(id => document.getElementById(id)?.textContent),
      e.tagName === 'FIELDSET' ? e.querySelector('legend')?.textContent : ''].join(' '));
    const birthdayLabel = value => /birth.?day|birth.?date|date.?of.?birth|bday|дата рождения|день рождения/.test(value);
    const birthdayProfile = (fields, names) => {
      if (names.length !== 1) return null;
      const owner = names[0].form;
      if (!owner) return null;
      const controls = [...document.querySelectorAll('input,select,textarea,[contenteditable="true"],[role="spinbutton"]')].filter(editable);
      const groups = [...owner.querySelectorAll('[role="group"],fieldset')].filter(visible).filter(e => birthdayLabel(accessible(e)));
      const dates = fields.filter(e => e.type === 'date' && (birthdayLabel(label(e)) || (groups.length === 1 && groups[0].contains(e))));
      if (dates.length === 1 && controls.length === 2 && dates[0].form === owner)
        return {fields:[names[0],dates[0]],birthday:{native:true}};
      if (groups.length !== 1) return null;
      const group = groups[0];
      const parts = {};
      for (const part of ['day','month','year']) {
        const localized = {day:'день',month:'месяц',year:'год'}[part];
        const matches = controls.filter(e => group.contains(e) &&
          (e.getAttribute('data-type') === part || e.autocomplete === 'bday-' + part ||
           new RegExp('(?:^|[\\s_-])(?:'+part+'|'+localized+')(?:$|[\\s_-])').test(label(e))));
        if (matches.length !== 1) return null;
        parts[part] = matches[0];
      }
      const selected = [names[0],parts.year,parts.month,parts.day];
      if (new Set(selected).size !== 4 || controls.length !== 4 || controls.some(e => !selected.includes(e)) ||
          selected.some(e => e.closest('form') !== owner || (e.form && e.form !== owner)) ||
          selected.slice(1).some(e => !['INPUT','SELECT'].includes(e.tagName) &&
            !(e.getAttribute('role') === 'spinbutton' && e.isContentEditable))) return null;
      const hidden = [...owner.querySelectorAll('input[type="hidden"]')].filter(e => birthdayLabel(label(e)));
      if (hidden.length > 1 || hidden.some(e => e.form !== owner || !enabled(e))) return null;
      return {fields:selected,birthday:{native:false,hidden:hidden[0] || null}};
    };
    const findForm = (retryRejectedProfile = false) => {
      const unknown = {kind:'unknown'};
      if (!trusted()) return unknown;
      if (challenge()) return {kind:'challenge'};
      if (!(retryRejectedProfile && auth() && location.pathname === '/about-you') &&
          auth() && (location.pathname === '/about-you' || location.pathname.startsWith('/create-account')) &&
          /(?:we (?:cannot|can['’]t|are unable to) create your account.{0,100}terms of (?:use|service)|мы не можем создать вашу уч[её]тную запись.{0,100}услови.{0,30}использован)/i.test(text(document.body)))
        return {kind:'registrationRejected'};
      const fields = [...document.querySelectorAll('input')].filter(editable);
      let kind = 'unknown', selected = [], birthday = null;
      if (auth() && location.pathname === '/about-you') {
        const names = fields.filter(e => /\bname\b|имя|full.?name|фио/.test(label(e)) && !/user.?name/.test(label(e)));
        const ages = fields.filter(e => /\bage\b|возраст/.test(label(e)));
        const dateForm = birthdayProfile(fields,names);
        if (dateForm) { selected = dateForm.fields; birthday = dateForm.birthday; }
        else {
          if (fields.length !== 2 || fields.some(e => /birth|birthday|month|year|day|рожд|месяц|год|день/.test(label(e))) ||
              [...document.querySelectorAll('select,textarea,[contenteditable="true"],[role="spinbutton"]')].some(editable) ||
              names.length !== 1 || ages.length !== 1 || names[0] === ages[0]) return unknown;
          selected = [names[0],ages[0]];
        }
        kind = 'profile';
      } else if (emailCodeRoute()) {
        selected = fields.filter(e => e.autocomplete === 'one-time-code' || /code|otp|verification|код/.test(label(e)));
        if (!(selected.length === 1 || (selected.length === 6 && selected.every(e => e.maxLength === 1))) || selected.length !== fields.length) return unknown;
        kind = 'emailCode';
      } else if (auth() && ['/create-account/password','/log-in/password'].includes(location.pathname)) {
        selected = fields.filter(e => e.type === 'password');
        if (selected.length !== 1 || fields.some(e => e !== selected[0] && e.type !== 'email')) return unknown;
        kind = 'password';
      } else if (entryRoute()) {
        selected = fields.filter(e => e.type === 'email' || e.autocomplete === 'username' || e.name === 'username');
        if (!selected.length) return {kind:'entry'};
        if (selected.length !== 1 || fields.length !== 1) return unknown;
        kind = 'email';
      } else return unknown;
      const root = selected[0].form || selected[0].closest('[role="dialog"]');
      if (!root || !selected.every(e => root.contains(e))) return unknown;
      const buttons = [...root.querySelectorAll('button,input[type="submit"],[role="button"]')].filter(visible)
        .filter(e => primaryLabels.includes(name(e)) ||
          (kind === 'emailCode' && ['submit code','отправить код'].includes(name(e))) ||
          (kind === 'profile' && ['завершить регистрацию','complete registration','finish registration',
            'завершить создание учетной записи','завершить создание учётной записи',
            'finish creating account','finish creating your account'].includes(name(e))))
        .filter(e => !/phone|mobile|social|provider|oauth/.test([e.name,e.id,e.getAttribute('data-provider'),e.getAttribute('data-testid')].join(' ').toLowerCase()));
      if (buttons.length !== 1) return unknown;
      if (kind === 'profile') {
        if (selected.some(e => (e.form || e.closest('form')) !== root) || buttons[0].form !== root) return unknown;
        const action = new URL(buttons[0].getAttribute('formaction') || root.action,location.href);
        if (action.origin !== location.origin || action.username || action.password) return unknown;
      }
      let displayedEmail = null;
      if (kind === 'emailCode') {
        let scope = root, addresses = [];
        while (scope && scope !== document.body && scope !== document.documentElement) {
          if ([...scope.querySelectorAll('input')].filter(editable).some(e => !selected.includes(e))) break;
          addresses = [...new Set((text(scope).match(/[a-z0-9.!#$%&'*+/=?^_`{|}~-]+@[a-z0-9-]+(?:\.[a-z0-9-]+)+/gi) || []).map(norm))];
          if (addresses.length) break;
          scope = scope.parentElement;
        }
        if (addresses.length !== 1 || /sms|text message|phone number|смс|номер телефона/i.test(text(root))) return unknown;
        displayedEmail = addresses[0];
      }
      return {kind,fields:selected,button:buttons[0],displayedEmail,birthday};
    };
    """#
}
