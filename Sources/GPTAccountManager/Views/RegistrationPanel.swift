import SwiftUI

struct RegistrationPanel: View {
    let store: AccountStore
    let registration: RegistrationCoordinator
    var proxies: ProxyStore? = nil
    let canStart: Bool
    let onClose: () -> Void
    var onReplaceProxy: ((UUID) -> Void)? = nil
    var proxyActionMessage: String? = nil
    @State private var email = ""
    @State private var accountCount = 1
    @State private var installedPassword = ""
    @State private var error: String?

    private var pending: AccountRecord? {
        store.accounts.first { $0.id == registration.accountID && $0.pendingRegistration != nil }
    }

    private var availableEmails: [EmailAlias] { store.emailAliases.filter { $0.status == .available } }

    private var maximumCount: Int {
        let entered = email.trimmingCharacters(in: .whitespacesAndNewlines)
        return max(1, availableEmails.count + (entered.isEmpty || availableEmails.contains {
            $0.email.caseInsensitiveCompare(entered) == .orderedSame
        } ? 0 : 1))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Новая регистрация").font(.title2.bold())
                Spacer()
                if (registration.activeSession != nil || registration.hasPendingBatch) && !registration.isRunning {
                    Button("Новая регистрация") {
                        registration.newRegistration()
                        email = ""
                        error = nil
                    }
                }
                Button("Закрыть", action: onClose).disabled(registration.isRunning)
            }
            if let pending {
                HStack {
                    VStack(alignment: .leading) {
                        Text(pending.email).font(.headline).textSelection(.enabled)
                        if let profile = pending.pendingRegistration {
                            Text("\(profile.fullName) · \(profile.age) лет").foregroundStyle(.secondary)
                        }
                        if let proxy = pending.proxy {
                            Text("Прокси: \(proxy.displayName)").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if registration.isRunning {
                        Button("Остановить") { registration.stop() }
                    } else {
                        if pending.pendingRegistration?.phase == .verifyingLogin {
                            Button("Скопировать пароль") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(pending.password, forType: .string)
                            }
                            .help("Сохранённый пароль для установки в настройках ChatGPT, если там указано «Добавить».")
                        }
                        if pending.proxy != nil, proxies?.isEnabled == true, let onReplaceProxy {
                            Button("Сменить прокси") { onReplaceProxy(pending.id) }
                                .disabled(!canStart)
                        }
                        Button("Возобновить") { registration.resume(id: pending.id) }
                            .buttonStyle(.borderedProminent)
                            .disabled(!canStart)
                    }
                }
                if pending.pendingRegistration?.pendingSecret != nil {
                    HStack(spacing: 12) {
                        OneTimeCodeView(account: pending) { code in
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(code, forType: .string)
                        }
                        Text("Нажмите на код, чтобы скопировать его для запроса 2FA.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if pending.pendingRegistration?.phase == .verifyingLogin && !registration.isRunning {
                    HStack {
                        SecureField("Пароль, уже установленный в ChatGPT", text: $installedPassword)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityLabel("Установленный пароль")
                        Button("Сохранить пароль и продолжить") {
                            do {
                                try registration.verifyInstalledPassword(id: pending.id, password: installedPassword)
                                installedPassword = ""
                                error = nil
                            } catch {
                                self.error = "Не удалось сохранить пароль. Проверьте поле и повторите."
                            }
                        }
                        .disabled(!canStart || installedPassword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    Text("Если пароль установили вручную, укажите его здесь. После подтверждения 2FA и сохранения текущей сессии аккаунт станет готовым.")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("Сохранить аккаунт без проверки") {
                            do {
                                try registration.saveRegisteredAccountWithoutVerification(id: pending.id)
                                error = nil
                                onClose()
                            } catch {
                                self.error = "Не удалось сохранить аккаунт. Черновик и доступы остались на месте."
                            }
                        }
                        .disabled(!canStart)
                        Text("Закрывает регистрацию, сохраняя пароль, ключ 2FA и сессию. Готовность не подтверждается; очередь завершается.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            } else if registration.activeSession == nil {
                HStack {
                    TextField("Адрес электронной почты", text: $email)
                        .textFieldStyle(.roundedBorder)
                    if !availableEmails.isEmpty {
                        Menu("Из базы почт") {
                            ForEach(availableEmails) { alias in
                                Button(alias.email) { email = alias.email }
                            }
                        }
                    }
                }
                .disabled(registration.isRunning || registration.hasPendingBatch)
                .onAppear {
                    if email.isEmpty {
                        email = store.emailAliases.first(where: { $0.status == .available })?.email ?? ""
                    }
                }
                HStack {
                    Text("Аккаунтов подряд")
                    TextField("Количество", value: $accountCount, format: .number.grouping(.never))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 64)
                        .accessibilityLabel("Количество аккаунтов подряд")
                    Stepper("Количество аккаунтов подряд", value: $accountCount, in: 1...maximumCount)
                        .labelsHidden()
                    Text("Свободных почт: \(availableEmails.count)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .disabled(registration.isRunning || registration.hasPendingBatch)
                if accountCount > 1 {
                    Text("Первый аккаунт — с выбранной почтой, остальные — со свободными адресами из базы. Строго по одному; при ошибке очередь ждёт.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text(registration.canCreateDraft
                     ? "Случайный профиль, настроенный пароль, код из почты и 2FA — автоматически. Готовый аккаунт и сессия сохранятся в new-novoreg."
                     : NewPasswordConfiguration.unavailableMessage)
                    .font(.callout).foregroundStyle(.secondary)
                if let proxies {
                    Text(proxies.isEnabled ? "Прокси включены — перед запуском выберем и проверим случайный адрес." : "Прокси выключены — прямое подключение.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Button("Начать") {
                        do {
                            try registration.start(email: email, count: accountCount)
                            error = nil
                        } catch {
                            self.error = (error as? RegistrationBatchError)?.localizedDescription ??
                                "Проверьте email. Адрес не должен принадлежать существующему аккаунту или незавершённой операции."
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canStart || !registration.canCreateDraft || registration.isRunning || registration.hasPendingBatch ||
                              accountCount < 1 || email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    let drafts = store.accounts.filter { $0.pendingRegistration != nil }
                    if !drafts.isEmpty {
                        Menu("Незавершённые") {
                            ForEach(drafts) { draft in
                                Button(draft.email) { registration.show(id: draft.id) }
                            }
                        }
                    }
                }
                Text("Нажимая «Начать», вы принимаете [условия OpenAI](https://openai.com/policies/terms-of-use) для нового аккаунта.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let error { Text(error).foregroundStyle(.red) }
            if registration.totalCount > 1 {
                ProgressView(value: Double(registration.completedCount), total: Double(registration.totalCount)) {
                    Text("Регистрация: готово \(registration.completedCount) из \(registration.totalCount)")
                }
            }
            if registration.blockedCount > 0 {
                Text("OpenAI заблокировал аккаунтов: \(registration.blockedCount). Они не засчитаны готовыми.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if registration.skippedCount > 0 {
                Text("Пропущено пользователем: \(registration.skippedCount). Они не засчитаны готовыми.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if registration.hasPendingBatch && !registration.isRunning && pending == nil {
                Button("Продолжить очередь") { registration.resumeBatch() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canStart)
            }
            if let proxyActionMessage {
                Text(proxyActionMessage).font(.callout).foregroundStyle(.secondary)
            }
            if !canStart && !registration.isRunning {
                Text("Сначала завершите или остановите текущую операцию Account Manager. Почта используется одним процессом за раз.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            HStack {
                if registration.isRunning { ProgressView().controlSize(.small) }
                Text(registration.message).font(.callout).textSelection(.enabled)
                if registration.isRunning && pending == nil {
                    Button("Остановить") { registration.stop() }
                }
            }
            if let session = registration.activeSession {
                BrowserAddressBar(session: session, navigationDisabled: registration.isRunning)
                BrowserStatusView(session: session)
                BrowserView(session: session).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView("Новая регистрация", systemImage: "person.badge.plus",
                                       description: Text("Регистрация, код из почты, пароль, 2FA и сохранённая сессия — без повторного входа."))
            }
        }
        .padding(20)
        .frame(minWidth: 820, idealWidth: 960, minHeight: 650, idealHeight: 820)
        .interactiveDismissDisabled(registration.isRunning)
        .onChange(of: registration.accountID) { _, _ in installedPassword = ""; error = nil }
    }
}
