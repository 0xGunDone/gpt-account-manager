import AppKit
import Foundation
import Testing
@testable import GPTAccountManager

@MainActor
@Suite(.serialized)
struct EmailChangeFormTests {
    private func fixture(_ html: String, url: String = "https://chatgpt.com/settings/account?mweb_fallback=1") async throws -> BrowserSession {
        _ = NSApplication.shared
        let session = BrowserSession(dataStore: .nonPersistent())
        session.webView.frame = NSRect(x: 0, y: 0, width: 900, height: 700)
        session.webView.navigationDelegate = nil
        session.webView.loadHTMLString(html, baseURL: URL(string: url))
        for _ in 0..<60 where session.webView.isLoading {
            try await Task.sleep(for: .milliseconds(50))
        }
        return session
    }

    private func emailForm(heading: String = "Edit email address", button: String = "Send verification email", extra: String = "", input: String = "", disabled: Bool = false) -> String {
        """
        <div role="dialog"><h2>\(heading)</h2>
        <form onsubmit="event.preventDefault();document.body.dataset.saved='yes'">
        <label>Email address<input type="email" \(input)></label>\(extra)
        <button type="button">Cancel</button><button type="submit" \(disabled ? "disabled" : "")>\(button)</button>
        </form></div>
        """
    }

    private func codeForm(address: String = "new@example.com", heading: String = "Edit email address", label: String = "Verification code", button: String = "Verify", extra: String = "", input: String = "", disabled: Bool = false) -> String {
        """
        <div role="dialog"><h2>\(heading)</h2><p>Code sent to \(address)</p>
        <form onsubmit="event.preventDefault();document.body.dataset.saved='yes'">
        <label>\(label)<input autocomplete="one-time-code" \(input)></label>\(extra)
        <button type="button">Cancel</button><button type="submit" \(disabled ? "disabled" : "")>\(button)</button>
        </form></div>
        """
    }

    private func observedEmailEntry(dialog: Bool = false, title: String = "<div><span>Изменить адрес электронной почты</span></div>", extra: String = "") -> String {
        """
        <section id="email-modal" \(dialog ? "role='dialog'" : "")>\(title)
        <button id="close-email" aria-label="Закрыть модальное окно редактирования электронной почты">×</button>
        <p>Введите свой новый адрес электронной почты. Мы отправим код подтверждения, чтобы подтвердить изменение.</p>
        <label for="new-email">Адрес электронной почты</label>
        <input id="new-email" type="email" oninput="document.querySelector('#send-email').disabled=false">
        <button>Отменить</button>
        <button id="send-email" disabled onclick="document.body.dataset.saved='yes'">Отправить письмо с подтверждением</button>
        \(extra)</section>
        """
    }

    private func accountSettingsDialog(email: String = "old@example.com", settings: String = "Настройки", account: String = "Учетная запись", label: String = "Электронная почта", search: String = "Поиск в настройках", extra: String = "") -> String {
        """
        <div role="dialog"><h2>\(settings)</h2>
        <input type="search" aria-label="\(search)">
        <button role="tab" aria-selected="true" aria-controls="account">\(account)</button>
        <section id="account" role="tabpanel"><h3>\(account)</h3>
        <button onclick="document.body.dataset.opened='email'"><span>\(label)</span> <span>\(email)</span></button>
        <label><input type="checkbox">Получать электронные письма с отзывами</label>
        \(extra)</section></div>
        """
    }

    private func renewalNotice(extra: String = "") -> String {
        """
        <div role="dialog" id="renewal"><h2>Продлите подписку на ChatGPT Plus</h2>
          <p>Не удалось обработать платёж. Добавьте способ оплаты.</p>
          <button onclick="document.body.dataset.payment='add'">Добавить способ оплаты</button>
          <button id="dismiss-renewal" onclick="document.body.dataset.dismissed='yes';document.querySelector('#email-background')?.removeAttribute('inert');document.querySelector('#renewal').remove()">Закрыть</button>
          <button onclick="document.body.dataset.payment='pay'">Оплатить сейчас</button>
          <button aria-label="Закрыть диалог" onclick="document.body.dataset.genericClose='yes'">×</button>
          \(extra)
        </div>
        """
    }

    private func authenticatorForm(input: String = "", extra: String = "", heading: String = "Проверьте приложение для аутентификации", label: String = "Код") -> String {
        """
        <h1>\(heading)</h1><form id="authenticator" onsubmit="event.preventDefault();window.submissions++">
          <label>\(label)<input id="auth-code" name="code" autocomplete="one-time-code" inputmode="numeric" pattern="[0-9]{6}" \(input)></label>
          <button id="auth-continue" onclick="if(!this.isConnected){window.staleClicks++;event.preventDefault()}">Продолжить</button>
          \(extra)
        </form><script>window.submissions=0;window.staleClicks=0;</script>
        """
    }

    @Test func observedRussianOneTimeCodeLabelSubmitsOnlyTrustedAuthenticatorChallenge() async throws {
        let url = URL(string: "https://auth.openai.com/mfa-challenge/email-fixture")!
        let session = try await fixture(authenticatorForm(label: "Одноразовый код"), url: url.absoluteString)
        #expect(try await EmailChangeForm.submitAuthenticatorCode("123456", expectedPageURL: url, in: session) == .submitted)
        #expect(try await session.evaluate("window.submissions === 1 && document.querySelector('#auth-code').value === '123456'") as? Bool == true)

        for html in [authenticatorForm(label: "Неизвестный код"),
                     authenticatorForm(heading: "Проверьте электронную почту", label: "Одноразовый код")] {
            let rejected = try await fixture(html, url: url.absoluteString)
            #expect(try await EmailChangeForm.submitAuthenticatorCode("123456", expectedPageURL: url, in: rejected) == .ambiguous)
            #expect(try await rejected.evaluate("window.submissions === 0 && document.querySelector('input').value === ''") as? Bool == true)
        }
        let wrongRoute = URL(string: "https://auth.openai.com/email-verification")!
        let emailChallenge = try await fixture(authenticatorForm(label: "Одноразовый код"), url: wrongRoute.absoluteString)
        #expect(try await EmailChangeForm.submitAuthenticatorCode("123456", expectedPageURL: wrongRoute, in: emailChallenge) == .ambiguous)
        #expect(try await emailChallenge.evaluate("window.submissions === 0 && document.querySelector('input').value === ''") as? Bool == true)
    }

    @Test(arguments: [false, true])
    func authenticatorWaitsAfterInputAndRefindsReplacedContinue(replaceButton: Bool) async throws {
        let reactUpdate = replaceButton
            ? "const next=old.cloneNode(true);old.replaceWith(next);setTimeout(()=>next.disabled=false,120)"
            : "setTimeout(()=>old.disabled=false,120)"
        let input = "oninput=\"const old=document.querySelector('#auth-continue');old.disabled=true;\(reactUpdate)\""
        let url = URL(string: "https://auth.openai.com/mfa-challenge/email-fixture")!
        let session = try await fixture(authenticatorForm(input: input), url: url.absoluteString)
        #expect(try await EmailChangeForm.submitAuthenticatorCode("123456", expectedPageURL: url, in: session) == .submitted)
        #expect(try await session.evaluate("window.submissions === 1 && window.staleClicks === 0") as? Bool == true)
        #expect(try await session.evaluate("document.querySelector('#auth-code').value === '123456'") as? Bool == true)
        try await Task.sleep(for: .milliseconds(200))
        #expect(try await session.evaluate("window.submissions === 1") as? Bool == true)
    }

    @Test func authenticatorRejectsWrongHeadingAmbiguityAndUntrustedDestination() async throws {
        let url = URL(string: "https://auth.openai.com/mfa-challenge/email-fixture")!
        for html in [
            authenticatorForm(heading: "Проверьте электронную почту"),
            authenticatorForm(extra: "<input aria-label='Код'>"),
            authenticatorForm(extra: "<button>Продолжить</button>"),
            authenticatorForm().replacingOccurrences(of: "<form id=\"authenticator\"", with: "<form action='https://external.example' id=\"authenticator\""),
        ] {
            let session = try await fixture(html, url: url.absoluteString)
            #expect(try await EmailChangeForm.submitAuthenticatorCode("123456", expectedPageURL: url, in: session) == .ambiguous)
            #expect(try await session.evaluate("window.submissions === 0 && document.querySelector('input').value === ''") as? Bool == true)
        }
        let session = try await fixture(authenticatorForm(), url: url.absoluteString)
        for invalid in ["12345", "1234567", "abcdef", "１２３４５６"] {
            #expect(try await EmailChangeForm.submitAuthenticatorCode(invalid, expectedPageURL: url, in: session) == .ambiguous)
        }
        #expect(try await session.evaluate("document.querySelector('input').value === ''") as? Bool == true)
        for route in ["https://chatgpt.com/settings/account", "https://auth.openai.com/email-verification"] {
            let wrongRoute = try await fixture(authenticatorForm(), url: route)
            #expect(try await EmailChangeForm.submitAuthenticatorCode("123456", expectedPageURL: URL(string: route)!, in: wrongRoute) == .ambiguous)
            #expect(try await wrongRoute.evaluate("document.querySelector('input').value === ''") as? Bool == true)
        }
        let untrusted = try await fixture(authenticatorForm(), url: "https://external.example/mfa-challenge/email-fixture")
        await #expect(throws: BrowserSessionError.untrustedOrigin) {
            try await EmailChangeForm.submitAuthenticatorCode("123456", expectedPageURL: url, in: untrusted)
        }
    }

    @Test func authenticatorDoesNotSubmitReplacementFieldFormOrChangedRoute() async throws {
        let url = URL(string: "https://auth.openai.com/mfa-challenge/email-fixture")!
        for change in [
            "const old=document.querySelector('#auth-code');const next=old.cloneNode(true);next.value=old.value;old.replaceWith(next)",
            "const old=document.querySelector('#authenticator');const next=old.cloneNode(true);next.querySelector('input').value=old.querySelector('input').value;old.replaceWith(next)",
            "history.replaceState({},'', '/mfa-challenge/different')",
            "document.querySelector('h1').innerText='Проверьте электронную почту'",
        ] {
            let input = "oninput=\"document.querySelector('#auth-continue').disabled=true;setTimeout(()=>{\(change);document.querySelector('#auth-continue').disabled=false},120)\""
            let session = try await fixture(authenticatorForm(input: input), url: url.absoluteString)
            #expect(try await EmailChangeForm.submitAuthenticatorCode("123456", expectedPageURL: url, in: session) == .ambiguous)
            try await Task.sleep(for: .milliseconds(200))
            #expect(try await session.evaluate("window.submissions === 0 && window.staleClicks === 0") as? Bool == true)
        }
        let session = try await fixture("<h1>Проверьте приложение для аутентификации</h1>", url: url.absoluteString)
        #expect(try await EmailChangeForm.submitAuthenticatorCode("123456", expectedPageURL: url, in: session) == .notFound)
    }

    @Test func authenticatorCancellationAfterFillPreventsDeferredSubmission() async throws {
        let url = URL(string: "https://auth.openai.com/mfa-challenge/email-fixture")!
        for cancelTask in [false, true] {
            let input = "oninput=\"document.querySelector('#auth-continue').disabled=true;setTimeout(()=>document.querySelector('#auth-continue').disabled=false,300)\""
            let session = try await fixture(authenticatorForm(input: input), url: url.absoluteString)
            let task = Task { try await EmailChangeForm.submitAuthenticatorCode("123456", expectedPageURL: url, in: session) }
            var filled = false
            for _ in 0..<50 {
                if try await session.evaluate("document.querySelector('input').value.length === 6") as? Bool == true { filled = true; break }
                try await Task.sleep(for: .milliseconds(10))
            }
            try #require(filled)
            if cancelTask { task.cancel() } else { session.cancelLoading() }
            await #expect(throws: CancellationError.self) { try await task.value }
            try await Task.sleep(for: .milliseconds(350))
            #expect(try await session.evaluate("window.submissions === 0") as? Bool == true)
        }
    }

    @Test(arguments: [false, true])
    func observedRenewalNoticeClosesOnlyExplicitDismissButtonOverEmailEditor(inertBackground: Bool) async throws {
        for url in ["https://chatgpt.com/settings/account", "https://chatgpt.com/#settings/Account"] {
            let session = try await fixture("""
            <section id="email-background" \(inertBackground ? "inert" : "")>
              \(emailForm(heading: "Редактировать адрес электронной почты", button: "Отправить код подтверждения по электронной почте"))
            </section>
            \(renewalNotice())
            """, url: url)
            #expect(try await EmailChangeForm.dismissEmailBlockingNotice(in: session))
            #expect(try await session.evaluate("document.body.dataset.dismissed") as? String == "yes")
            #expect(try await session.evaluate("document.body.dataset.payment === undefined && document.body.dataset.genericClose === undefined") as? Bool == true)
            #expect(try await session.evaluate("document.querySelector('input').value === '' && document.body.dataset.saved === undefined") as? Bool == true)
            #expect(try await EmailChangeForm.inspect(in: session).kind == .emailEntry)
            #expect(try await !EmailChangeForm.dismissEmailBlockingNotice(in: session))
        }
    }

    @Test func renewalNoticeRequiresExactUniqueVisibleDialogAndDismissButton() async throws {
        let valid = renewalNotice()
        var rejected = [
            valid.replacingOccurrences(of: "Продлите подписку на ChatGPT Plus", with: "Добавьте способ оплаты"),
            valid.replacingOccurrences(of: "role=\"dialog\"", with: ""),
            valid.replacingOccurrences(of: ">Закрыть</button>", with: ">Оплатить сейчас</button>"),
            valid.replacingOccurrences(of: "id=\"dismiss-renewal\"", with: "id=\"dismiss-renewal\" aria-label='Оплатить сейчас'"),
            valid + valid,
            renewalNotice(extra: "<h2>Продлите подписку на ChatGPT Plus</h2>"),
            renewalNotice(extra: "<h2>Другая операция</h2>"),
            renewalNotice(extra: "<button>Закрыть</button>"),
            renewalNotice(extra: "<input type='password'>"),
            renewalNotice(extra: "<input aria-label='Номер карты'>"),
            renewalNotice(extra: "<div role='dialog'><h2>Другая операция</h2><button>Закрыть</button></div>"),
            valid.replacingOccurrences(of: "id=\"dismiss-renewal\"", with: "id=\"dismiss-renewal\" disabled"),
            valid.replacingOccurrences(of: "id=\"dismiss-renewal\"", with: "id=\"dismiss-renewal\" aria-disabled='true'"),
        ]
        // A close belonging to another dialog must never dismiss the renewal root.
        rejected.append(valid.replacingOccurrences(of: "id=\"dismiss-renewal\"", with: "id=\"dismiss-renewal\" hidden") +
            "<div role='dialog'><h2>Другая операция</h2><button onclick=\"document.body.dataset.wrongClose='yes'\">Закрыть</button></div>")
        for hidden in ["hidden", "style='display:none'", "style='visibility:hidden'", "style='opacity:0'", "aria-hidden='true'", "inert"] {
            rejected.append(valid.replacingOccurrences(of: "id=\"renewal\"", with: "id=\"renewal\" \(hidden)"))
            rejected.append(valid.replacingOccurrences(of: "<h2>", with: "<h2 \(hidden)>"))
            rejected.append(valid.replacingOccurrences(of: "id=\"dismiss-renewal\"", with: "id=\"dismiss-renewal\" \(hidden)"))
        }
        for html in rejected {
            let session = try await fixture(html)
            #expect(try await !EmailChangeForm.dismissEmailBlockingNotice(in: session))
            #expect(try await session.evaluate("Object.keys(document.body.dataset).length === 0") as? Bool == true)
        }
    }

    @Test func renewalNoticeDismissalIsLimitedToTrustedEmailSettingsAndCancelsBeforeClick() async throws {
        for url in ["https://auth.openai.com/log-in/password", "https://chatgpt.com/", "https://chatgpt.com/#settings/Security"] {
            let session = try await fixture(renewalNotice(), url: url)
            #expect(try await !EmailChangeForm.dismissEmailBlockingNotice(in: session))
            #expect(try await session.evaluate("Object.keys(document.body.dataset).length === 0") as? Bool == true)
        }
        for url in ["https://external.example/settings/account", "http://chatgpt.com/settings/account"] {
            let session = try await fixture(renewalNotice(), url: url)
            await #expect(throws: BrowserSessionError.untrustedOrigin) {
                try await EmailChangeForm.dismissEmailBlockingNotice(in: session)
            }
        }
        let session = try await fixture(renewalNotice())
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await EmailChangeForm.dismissEmailBlockingNotice(in: session)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try await session.evaluate("Object.keys(document.body.dataset).length === 0") as? Bool == true)
    }

    @Test func emailEntryUsesObservedRussianAndEnglishDialogs() async throws {
        for (heading, button) in [("Редактировать адрес электронной почты", "Отправить код подтверждения по электронной почте"), ("Edit email address", "Send verification email")] {
            let session = try await fixture(emailForm(heading: heading, button: button))
            #expect(try await EmailChangeForm.inspect(in: session).kind == .emailEntry)
            #expect(try await EmailChangeForm.submitEmail("new+fixture@example.com", in: session))
            #expect(try await session.evaluate("document.querySelector('input').value") as? String == "new+fixture@example.com")
            #expect(try await session.evaluate("document.body.dataset.saved") as? String == "yes")
        }
    }

    @Test func observedEmailEntryWithoutHeadingOrFormSubmitsOnceEnabled() async throws {
        for dialog in [false, true] {
            for title in ["<div><span>Изменить адрес электронной почты</span></div>", "<p>Изменить адрес электронной почты</p>"] {
                let session = try await fixture(observedEmailEntry(dialog: dialog, title: title), url: "https://chatgpt.com/#settings/Account")
                #expect(try await EmailChangeForm.inspect(in: session).kind == .emailEntry)
                #expect(try await EmailChangeForm.submitEmail("new+fixture@example.com", in: session))
                #expect(try await session.evaluate("document.querySelector('#new-email').value") as? String == "new+fixture@example.com")
                #expect(try await session.evaluate("document.body.dataset.saved") as? String == "yes")
            }
        }
    }

    @Test func plainEmailTitleRequiresVisibleUniqueControlsInSameModal() async throws {
        let title = "<div>Изменить адрес электронной почты</div>"
        var rejected = [
            observedEmailEntry(title: "") + title,
            title + observedEmailEntry(dialog: true, title: ""),
            "<main>\(title)\(observedEmailEntry(title: ""))</main>",
            observedEmailEntry(extra: "<input type='email'>"),
            observedEmailEntry(extra: "<button>Отправить письмо с подтверждением</button>"),
            observedEmailEntry(extra: "<button aria-label='Закрыть модальное окно редактирования электронной почты'>×</button>"),
            observedEmailEntry(extra: title),
            observedEmailEntry() + observedEmailEntry(),
            observedEmailEntry().replacingOccurrences(of: "Закрыть модальное окно редактирования электронной почты", with: "Закрыть"),
        ]
        for hidden in ["hidden", "style='display:none'", "style='visibility:hidden'", "style='opacity:0'", "aria-hidden='true'", "inert"] {
            rejected.append(observedEmailEntry(title: "<div \(hidden)>Изменить адрес электронной почты</div>"))
            for id in ["close-email", "new-email", "send-email"] {
                rejected.append(observedEmailEntry().replacingOccurrences(of: "id=\"\(id)\"", with: "id=\"\(id)\" \(hidden)"))
            }
        }
        for html in rejected {
            let session = try await fixture(html)
            #expect(try await EmailChangeForm.inspect(in: session).kind != .emailEntry)
            #expect(try await !EmailChangeForm.submitEmail("new@example.com", in: session))
            #expect(try await session.evaluate("[...document.querySelectorAll('input')].every(e=>e.value==='')") as? Bool == true)
            #expect(try await session.evaluate("document.body.dataset.saved === undefined") as? Bool == true)
        }
    }

    @Test func opensOnlyMatchingAccountEmailControl() async throws {
        for prefix in ["Изменить адрес электронной почты", "Change email address"] {
            let session = try await fixture("""
            <button aria-label="\(prefix): old@example.com" onclick="document.body.dataset.opened='email'">Edit</button>
            <button onclick="document.body.dataset.opened='password'">Password</button>
            """)
            #expect(try await EmailChangeForm.inspect(in: session).displayedEmail == "old@example.com")
            #expect(try await !EmailChangeForm.open(in: session, currentEmail: "other@example.com"))
            #expect(try await EmailChangeForm.open(in: session, currentEmail: "OLD@example.com"))
            #expect(try await session.evaluate("document.body.dataset.opened") as? String == "email")
        }
        let login = try await fixture("<button aria-label='Change email address: old@example.com'>Edit</button>", url: "https://auth.openai.com/log-in/password")
        #expect(try await !EmailChangeForm.open(in: login, currentEmail: "old@example.com"))
    }

    @Test func observedAccountSettingsDialogOpensExactEmailRowWithUppercaseHash() async throws {
        let session = try await fixture(accountSettingsDialog(email: "hecto.rbanks02+y1rn@googlemail.com"), url: "https://chatgpt.com/#settings/Account")
        #expect(try await EmailChangeForm.inspect(in: session) == .init(kind: .accountSettings, displayedEmail: "hecto.rbanks02+y1rn@googlemail.com"))
        #expect(try await !EmailChangeForm.open(in: session, currentEmail: "other@example.com"))
        #expect(try await EmailChangeForm.open(in: session, currentEmail: "hecto.rbanks02+y1rn@googlemail.com"))
        #expect(try await session.evaluate("document.body.dataset.opened") as? String == "email")
    }

    @Test func accountSettingsRouteCaseAndEnglishEmailRowAreRecognized() async throws {
        for url in ["https://chatgpt.com/settings/Account", "https://chatgpt.com/#settings/Account"] {
            let session = try await fixture(accountSettingsDialog(settings: "Settings", account: "Account", label: "Email", search: "Search settings"), url: url)
            #expect(try await EmailChangeForm.inspect(in: session) == .init(kind: .accountSettings, displayedEmail: "old@example.com"))
            #expect(try await EmailChangeForm.open(in: session, currentEmail: "OLD@example.com"))
            #expect(try await session.evaluate("document.body.dataset.opened") as? String == "email")
        }
        let session = try await fixture(emailForm(), url: "https://chatgpt.com/#settings/Account")
        #expect(try await EmailChangeForm.submitEmail("new@example.com", in: session))
        #expect(try await session.evaluate("document.body.dataset.saved") as? String == "yes")
    }

    @Test func settingsEmailRowAcceptsPrefixAriaLabelAndRejectsConflictingEmail() async throws {
        for contents in ["<span>Электронная почта</span> <span>old@example.com</span>", "old@example.com"] {
            let session = try await fixture(accountSettingsDialog())
            _ = try await session.evaluate("""
            (() => {
              const row = document.querySelector('#account > button');
              row.setAttribute('aria-label', 'Электронная почта'); row.innerHTML = '\(contents)';
              return true;
            })()
            """)
            #expect(try await EmailChangeForm.inspect(in: session).displayedEmail == "old@example.com")
            #expect(try await EmailChangeForm.open(in: session, currentEmail: "old@example.com"))
        }
        let session = try await fixture(accountSettingsDialog())
        _ = try await session.evaluate("document.querySelector('#account > button').setAttribute('aria-label', 'Электронная почта other@example.com')")
        #expect(try await !EmailChangeForm.open(in: session, currentEmail: "old@example.com"))
        #expect(try await !EmailChangeForm.open(in: session, currentEmail: "other@example.com"))
        #expect(try await session.evaluate("document.body.dataset.opened === undefined") as? Bool == true)
    }

    @Test func settingsEmailRowRequiresKnownUniqueDialogWithoutCredentialFields() async throws {
        for html in [
            "<button onclick=\"document.body.dataset.opened='email'\">Email old@example.com</button>",
            accountSettingsDialog(settings: "Unrelated dialog"),
            accountSettingsDialog(account: "Безопасность"),
            accountSettingsDialog(extra: "<input type='password'>"),
            accountSettingsDialog(extra: "<input autocomplete='one-time-code'>"),
            accountSettingsDialog(extra: "<input type='search' aria-label='Verification code'>"),
            accountSettingsDialog(extra: "<div role='dialog'><h2>Verify it's you</h2></div>"),
            accountSettingsDialog() + "<div role='dialog'><h2>Unrelated dialog</h2></div>",
            accountSettingsDialog(extra: "<button>Электронная почта old@example.com</button>"),
            accountSettingsDialog(extra: "<button>Электронная почта other@example.com</button>"),
        ] {
            let session = try await fixture(html)
            #expect(try await !EmailChangeForm.open(in: session, currentEmail: "old@example.com"))
            #expect(try await !EmailChangeForm.submitEmail("new@example.com", in: session))
            #expect(try await !EmailChangeForm.submitCode("123456", expectedEmail: "old@example.com", in: session))
            #expect(try await session.evaluate("document.body.dataset.opened === undefined") as? Bool == true)
            #expect(try await session.evaluate("[...document.querySelectorAll('input:not([type=checkbox])')].every(e=>e.value==='')") as? Bool == true)
        }
    }

    @Test func submitsCodeOnlyForVisibleExpectedDestination() async throws {
        for (heading, label, button) in [("Редактировать адрес электронной почты", "Код подтверждения", "Подтвердить"), ("Edit email address", "Verification code", "Verify")] {
            let session = try await fixture(codeForm(address: "NEW@example.com", heading: heading, label: label, button: button))
            #expect(try await EmailChangeForm.inspect(in: session) == .init(kind: .emailCode, displayedEmail: "new@example.com"))
            #expect(try await EmailChangeForm.submitCode("123456", expectedEmail: "new@example.com", in: session))
            #expect(try await session.evaluate("document.querySelector('input').value") as? String == "123456")
            #expect(try await session.evaluate("document.body.dataset.saved") as? String == "yes")
        }
    }

    @Test func actualRussianConfirmationDialogReceivesCodeAfterButtonEnables() async throws {
        let session = try await fixture("""
        <div role="dialog"><h2>Подтвердить электронную почту</h2>
        <p>Введите 6-значный код, который мы только что отправили на new+fixture@icloud.com, чтобы подтвердить адрес электронной почты</p>
        <p>После подтверждения этого адреса электронной почты вы автоматически выйдете из учетной записи на всех устройствах, чтобы мы могли завершить ее обновление. Затем вам нужно будет войти снова.</p>
        <label for="code">Код подтверждения</label>
        <input id="code" autocomplete="one-time-code" oninput="setTimeout(()=>document.querySelector('#confirm').disabled=false,50)">
        <p>Не получили письмо?</p><button>Отправить снова</button><button>Назад</button>
        <button id="confirm" disabled onclick="document.body.dataset.saved='yes'">Подтвердить</button>
        <button>Закрыть диалог</button></div>
        """)
        #expect(try await EmailChangeForm.inspect(in: session) == .init(kind: .emailCode, displayedEmail: "new+fixture@icloud.com"))
        #expect(try await !EmailChangeForm.submitCode("123456", expectedEmail: "other@icloud.com", in: session))
        #expect(try await EmailChangeForm.submitCode("123456", expectedEmail: "new+fixture@icloud.com", in: session))
        #expect(try await session.evaluate("document.body.dataset.saved") as? String == "yes")
    }

    @Test func genericConfirmationHeadingWithoutEmailChangeContextIsRejected() async throws {
        let session = try await fixture(codeForm(address: "new@example.com", heading: "Подтвердить электронную почту", label: "Код подтверждения", button: "Подтвердить"))
        #expect(try await EmailChangeForm.inspect(in: session).kind == .unknown)
        #expect(try await !EmailChangeForm.submitCode("123456", expectedEmail: "new@example.com", in: session))
    }

    @Test func plainConfirmationTitleRequiresScopedVisibleUpdateContextAndExactDestination() async throws {
        let warning = "После подтверждения мы сможем завершить ее обновление."
        for extra in ["<p>\(warning)</p>", "<p hidden>\(warning)</p>", ""] {
            let html = codeForm(heading: "Подтвердить электронную почту", extra: extra)
                .replacingOccurrences(of: "<h2>Подтвердить электронную почту</h2>", with: "<div><span>Подтвердить электронную почту</span></div>")
            let session = try await fixture("<p>\(warning)</p>" + html)
            #expect(try await !EmailChangeForm.submitCode("123456", expectedEmail: "other@example.com", in: session))
            let recognized = extra == "<p>\(warning)</p>"
            #expect(try await EmailChangeForm.submitCode("123456", expectedEmail: "new@example.com", in: session) == recognized)
            #expect(try await session.evaluate("document.querySelector('input').value") as? String == (recognized ? "123456" : ""))
            #expect(try await session.evaluate("document.body.dataset.saved === 'yes'") as? Bool == recognized)
        }
    }

    private func currentCodeModal(email: String = "new@icloud.com", extra: String = "", warning: String = "Подтвердив этот адрес электронной почты, вы выйдете из системы на всех устройствах, чтобы мы могли завершить обновление вашей учетной записи. После этого вам нужно будет снова войти в систему.") -> String {
        """
        <section><div><span>Добавить адрес электронной почты</span>
          <button aria-label="Закрыть модальное окно добавления адреса электронной почты">×</button></div>
        <p>Введите 6-значный код, который мы только что отправили на \(email), чтобы подтвердить вашу почту.</p>
        <p>\(warning)</p>
        <input aria-label="Код подтверждения" placeholder="Введите код" oninput="setTimeout(()=>document.querySelector('#verify').disabled=false,50)">
        <p>Не получили письмо?</p><button>Отправить еще раз</button><button>Назад</button>
        <button id="verify" disabled onclick="document.body.dataset.saved='yes'">Проверить</button>\(extra)</section>
        """
    }

    @Test func currentAddEmailCodeModalUsesExactRecipientAndWaitsForVerify() async throws {
        let session = try await fixture(currentCodeModal(), url: "https://chatgpt.com/#settings/Account")
        #expect(try await EmailChangeForm.inspect(in: session) == .init(kind: .emailCode, displayedEmail: "new@icloud.com"))
        #expect(try await !EmailChangeForm.submitCode("123456", expectedEmail: "wrong@icloud.com", in: session))
        #expect(try await EmailChangeForm.submitCode("123456", expectedEmail: "new@icloud.com", in: session))
        #expect(try await session.evaluate("document.querySelector('input').value") as? String == "123456")
        #expect(try await session.evaluate("document.body.dataset.saved") as? String == "yes")
    }

    @Test func currentAddEmailCodeModalRejectsUnrelatedOrAmbiguousContent() async throws {
        for html in [
            currentCodeModal(warning: "Код для входа в аккаунт."),
            currentCodeModal(warning: "<span hidden>завершить обновление вашей учетной записи</span>"),
            currentCodeModal(email: "<span hidden>new@icloud.com</span>"),
            currentCodeModal(email: "new@icloud.com other@icloud.com"),
            currentCodeModal(extra: "<button>Проверить</button>"),
            currentCodeModal(extra: "<input aria-label='Код подтверждения'>"),
            currentCodeModal().replacingOccurrences(of: "Закрыть модальное окно добавления адреса электронной почты", with: "Закрыть"),
        ] {
            let session = try await fixture(html)
            #expect(try await !EmailChangeForm.submitCode("123456", expectedEmail: "new@icloud.com", in: session))
            #expect(try await session.evaluate("[...document.querySelectorAll('input')].every(e=>e.value==='')") as? Bool == true)
        }
    }

    @Test func hiddenOrOutsideDialogWarningCannotAuthorizeGenericCodeHeading() async throws {
        for (heading, warning) in [
            ("Подтвердить электронную почту", "После подтверждения мы сможем завершить ее обновление."),
            ("Verify your email", "Verify this address to complete the update."),
        ] {
            for hidden in ["hidden", "style='display:none'", "style='visibility:hidden'", "style='opacity:0'", "aria-hidden='true'"] {
                let session = try await fixture(codeForm(heading: heading, extra: "<p \(hidden)>\(warning)</p>"))
                #expect(try await EmailChangeForm.inspect(in: session).kind == .unknown)
                #expect(try await !EmailChangeForm.submitCode("123456", expectedEmail: "new@example.com", in: session))
                #expect(try await session.evaluate("document.querySelector('input').value") as? String == "")
                #expect(try await session.evaluate("document.body.dataset.saved === undefined") as? Bool == true)
            }
            let session = try await fixture("<p>\(warning)</p>" + codeForm(heading: heading))
            #expect(try await EmailChangeForm.inspect(in: session).kind == .unknown)
            #expect(try await !EmailChangeForm.submitCode("123456", expectedEmail: "new@example.com", in: session))
            #expect(try await session.evaluate("document.querySelector('input').value") as? String == "")
            #expect(try await session.evaluate("document.body.dataset.saved === undefined") as? Bool == true)
        }
    }

    @Test func confirmationHeadingWithEmailFieldNeverReceivesNewAddress() async throws {
        for heading in ["Подтвердить электронную почту", "Verify your email"] {
            let session = try await fixture(emailForm(heading: heading, extra: "<p>Change your email address to complete the update.</p>"))
            #expect(try await EmailChangeForm.inspect(in: session).kind == .unknown)
            #expect(try await !EmailChangeForm.submitEmail("new@example.com", in: session))
            #expect(try await session.evaluate("document.querySelector('input').value") as? String == "")
            #expect(try await session.evaluate("document.body.dataset.saved === undefined") as? Bool == true)
        }
    }

    @Test func observedRussianConfirmationRechecksDestinationAfterDisabledWait() async throws {
        let session = try await fixture("""
        <div role="dialog"><h2>Подтвердить электронную почту</h2>
        <p id="destination">Введите код, который мы отправили на new@example.com, чтобы подтвердить адрес.</p>
        <p>После подтверждения адреса вы выйдете из учетной записи, чтобы мы могли завершить ее обновление.</p>
        <label for="code">Код подтверждения</label>
        <input id="code" autocomplete="one-time-code" oninput="setTimeout(() => {
          document.querySelector('#destination').innerText='Введите код, который мы отправили на wrong@example.com, чтобы подтвердить адрес.';
          document.querySelector('#confirm').disabled=false;
        }, 150)">
        <button id="confirm" disabled onclick="document.body.dataset.saved='yes'">Подтвердить</button></div>
        """)
        #expect(try await EmailChangeForm.inspect(in: session) == .init(kind: .emailCode, displayedEmail: "new@example.com"))
        #expect(try await !EmailChangeForm.submitCode("123456", expectedEmail: "new@example.com", in: session))
        #expect(try await session.evaluate("document.querySelector('#code').value") as? String == "123456")
        #expect(try await session.evaluate("document.querySelector('#confirm').disabled") as? Bool == false)
        #expect(try await EmailChangeForm.inspect(in: session).displayedEmail == "wrong@example.com")
        #expect(try await session.evaluate("document.body.dataset.saved === undefined") as? Bool == true)
    }

    @Test func mismatchedMissingHiddenAndAmbiguousDestinationsNeverReceiveCode() async throws {
        for html in [
            codeForm(address: "other@example.com"),
            codeForm(address: ""),
            codeForm(address: "<span hidden>new@example.com</span>"),
            codeForm(address: "<span style='opacity:0'>new@example.com</span>"),
            codeForm(address: "new@example.com and old@example.com"),
            codeForm(extra: "<input aria-label='Code'>"),
            codeForm(extra: "<button>Continue</button>"),
            codeForm(heading: "Verify your email"),
            codeForm(label: "Authenticator code"),
        ] {
            let session = try await fixture(html)
            #expect(try await !EmailChangeForm.submitCode("123456", expectedEmail: "new@example.com", in: session))
            #expect(try await session.evaluate("[...document.querySelectorAll('input')].every(e=>e.value==='')") as? Bool == true)
            #expect(try await session.evaluate("document.body.dataset.saved === undefined") as? Bool == true)
        }
    }

    @Test func ambiguousEmailFormsAndControlsStayUntouched() async throws {
        for html in [emailForm(extra: "<input type='email'>"), emailForm(extra: "<button>Send verification code</button>"), emailForm() + emailForm()] {
            let session = try await fixture(html)
            #expect(try await EmailChangeForm.inspect(in: session).kind == .unknown)
            #expect(try await !EmailChangeForm.submitEmail("new@example.com", in: session))
            #expect(try await session.evaluate("[...document.querySelectorAll('input')].every(e=>e.value==='')") as? Bool == true)
        }
        let session = try await fixture("<button aria-label='Change email address: old@example.com'>Edit</button><button aria-label='Change email address: old@example.com'>Edit</button>")
        #expect(try await !EmailChangeForm.open(in: session, currentEmail: "old@example.com"))
    }

    @Test func authenticationStagesNeverReceiveNewEmailCode() async throws {
        let stages: [(String, EmailChangeForm.Kind)] = [
            ("/log-in/password", .password), ("/mfa-challenge/fixture", .totp),
            ("/email-verification", .emailChallenge), ("/verify-email", .emailChallenge), ("/unknown-email-change", .unknown),
        ]
        for (path, expectedKind) in stages {
            let session = try await fixture(codeForm(), url: "https://auth.openai.com\(path)")
            #expect(try await EmailChangeForm.inspect(in: session).kind == expectedKind)
            #expect(try await !EmailChangeForm.submitCode("123456", expectedEmail: "new@example.com", in: session))
            #expect(try await !EmailChangeForm.submitEmail("new@example.com", in: session))
            #expect(try await session.evaluate("document.querySelector('input').value") as? String == "")
        }
    }

    @Test func externalAndInsecureOriginsAreRejected() async throws {
        for url in ["https://external.example/settings/account", "http://chatgpt.com/settings/account"] {
            let session = try await fixture(emailForm(), url: url)
            do {
                _ = try await EmailChangeForm.inspect(in: session)
                Issue.record("Untrusted inspection was accepted")
            } catch BrowserSessionError.untrustedOrigin {}
            do {
                _ = try await EmailChangeForm.submitEmail("new@example.com", in: session)
                Issue.record("Untrusted email submission was accepted")
            } catch BrowserSessionError.untrustedOrigin {}
        }
    }

    @Test func waitsForEmailButtonToEnableAfterNativeInputEvents() async throws {
        let session = try await fixture(emailForm(input: "oninput=\"setTimeout(()=>document.querySelector('[type=submit]').disabled=false,100)\"", disabled: true))
        #expect(try await EmailChangeForm.submitEmail("new@example.com", in: session))
        #expect(try await session.evaluate("document.body.dataset.saved") as? String == "yes")
    }

    @Test func waitsBeyondOneSecondAndSubmitsEmailAndCodeExactlyOnce() async throws {
        for isCode in [false, true] {
            let input = "oninput=\"setTimeout(()=>document.querySelector('[type=submit]').disabled=false,1800)\""
            let html = (isCode ? codeForm(input: input, disabled: true) : emailForm(input: input, disabled: true))
                .replacingOccurrences(of: "document.body.dataset.saved='yes'", with: "document.body.dataset.submissions=String(Number(document.body.dataset.submissions||0)+1)")
            let session = try await fixture(html)
            let submitted = if isCode {
                try await EmailChangeForm.submitCode("123456", expectedEmail: "new@example.com", in: session)
            } else {
                try await EmailChangeForm.submitEmail("new@example.com", in: session)
            }
            #expect(submitted)
            #expect(try await session.evaluate("document.body.dataset.submissions") as? String == "1")
        }
    }

    @Test func cancellationAfterOneSecondPreventsDelayedSubmission() async throws {
        for cancelTask in [false, true] {
            let session = try await fixture(emailForm(input: "oninput=\"setTimeout(()=>document.querySelector('[type=submit]').disabled=false,1800)\"", disabled: true))
            let task = Task { try await EmailChangeForm.submitEmail("new@example.com", in: session) }
            try await Task.sleep(for: .milliseconds(1200))
            if cancelTask { task.cancel() } else { session.cancelLoading() }
            do {
                _ = try await task.value
                Issue.record("Submission waiting beyond one second did not cancel")
            } catch is CancellationError {}
            try await Task.sleep(for: .milliseconds(700))
            #expect(try await session.evaluate("document.querySelector('[type=submit]').disabled") as? Bool == false)
            #expect(try await session.evaluate("document.body.dataset.saved === undefined") as? Bool == true)
        }
    }

    @Test func recipientChangeAfterOneSecondStopsCodeReadinessWait() async throws {
        let input = """
        oninput="setTimeout(()=>document.querySelector('p').innerText='Code sent to wrong@example.com',1200);setTimeout(()=>document.querySelector('[type=submit]').disabled=false,1800)"
        """
        let session = try await fixture(codeForm(input: input, disabled: true))
        #expect(try await !EmailChangeForm.submitCode("123456", expectedEmail: "new@example.com", in: session))
        #expect(try await EmailChangeForm.inspect(in: session).displayedEmail == "wrong@example.com")
        try await Task.sleep(for: .milliseconds(700))
        #expect(try await session.evaluate("document.body.dataset.saved === undefined") as? Bool == true)
    }

    @Test func replacementFormWithSameValueNeverReceivesDeferredSubmission() async throws {
        let input = """
        oninput="setTimeout(()=>{const old=document.querySelector('[role=dialog]');const replacement=old.cloneNode(true);replacement.querySelector('input').value=old.querySelector('input').value;replacement.querySelector('[type=submit]').disabled=false;old.replaceWith(replacement)},150)"
        """
        let session = try await fixture(emailForm(input: input, disabled: true))
        #expect(try await !EmailChangeForm.submitEmail("new@example.com", in: session))
        #expect(try await session.evaluate("document.body.dataset.saved === undefined") as? Bool == true)
    }

    @Test func cancellationPreventsDeferredEmailAndCodeSubmission() async throws {
        for isCode in [false, true] {
            let input = "oninput=\"setTimeout(()=>document.querySelector('[type=submit]').disabled=false,400)\""
            let session = try await fixture(isCode ? codeForm(input: input, disabled: true) : emailForm(input: input, disabled: true))
            let task = Task {
                if isCode { return try await EmailChangeForm.submitCode("123456", expectedEmail: "new@example.com", in: session) }
                return try await EmailChangeForm.submitEmail("new@example.com", in: session)
            }
            var filled = false
            for _ in 0..<30 {
                if try await session.evaluate("document.querySelector('input').value.length > 0") as? Bool == true { filled = true; break }
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(filled)
            session.cancelLoading()
            do {
                _ = try await task.value
                Issue.record("Stopped submission did not cancel")
            } catch is CancellationError {}
            try await Task.sleep(for: .milliseconds(500))
            #expect(try await session.evaluate("document.body.dataset.saved === undefined") as? Bool == true)
        }
    }

    @Test func changedDestinationWhileWaitingPreventsCodeSubmission() async throws {
        let session = try await fixture(codeForm(input: "oninput=\"document.querySelector('p').innerText='Code sent to wrong@example.com';document.querySelector('[type=submit]').disabled=false\"", disabled: true))
        #expect(try await !EmailChangeForm.submitCode("123456", expectedEmail: "new@example.com", in: session))
        #expect(try await session.evaluate("document.body.dataset.saved === undefined") as? Bool == true)
    }
}
