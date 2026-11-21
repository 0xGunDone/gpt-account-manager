import SwiftUI

struct EmailAliasesView: View {
    let store: AccountStore
    let onClose: () -> Void
    var markingUsedDisabled = false
    @State private var text = ""
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("База почт").font(.title2.weight(.semibold))
            Text("Добавьте свои iCloud-алиасы, по одному на строку. Настройте пересылку в свой ящик Mail.ru и укажите его во вкладке «Почта».")
                .font(.callout).foregroundStyle(.secondary)
            TextEditor(text: $text).font(.system(.body, design: .monospaced))
                .frame(height: 100).border(.separator).accessibilityLabel("Новые алиасы iCloud")
            HStack {
                Button("Добавить алиасы") {
                    do { let count = try store.importEmailAliases(text); message = "Добавлено: \(count)"; text = "" }
                    catch { message = "Проверьте адреса: нужны свободные алиасы @icloud.com, без дубликатов аккаунтов." }
                }.disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if let message { Text(message).font(.callout).foregroundStyle(.secondary) }
            }
            List(store.emailAliases) { alias in
                HStack {
                    Text(alias.email).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                    Spacer()
                    Text(title(alias.status)).foregroundStyle(alias.status == .available ? Color.secondary : Color.orange)
                    if alias.status == .available {
                        Button("Отметить использованной") {
                            do {
                                try store.markEmailAliasUsed(id: alias.id)
                                message = "Почта отмечена использованной и больше не будет выбираться автоматически."
                            } catch AccountStoreError.emailAliasUnavailable {
                                message = "Почта уже занята текущей операцией; отметка не изменена."
                            } catch {
                                message = "Не удалось сохранить отметку. Повторите попытку."
                            }
                        }
                        .buttonStyle(.borderless)
                        .disabled(markingUsedDisabled)
                        Button("Удалить") {
                            do { try store.deleteAvailableEmailAlias(id: alias.id) }
                            catch { message = "Алиас уже зарезервирован; удалить нельзя." }
                        }.buttonStyle(.borderless)
                    }
                }
            }.frame(minHeight: 200)
            if markingUsedDisabled {
                Text("Ручная отметка доступна после завершения или сброса очереди регистрации.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack { Spacer(); Button("Готово", action: onClose).keyboardShortcut(.cancelAction) }
        }.padding(24).frame(width: 820, height: 500)
    }

    private func title(_ status: EmailAliasStatus) -> String {
        switch status { case .available: "Свободен"; case .reserved: "В работе"; case .used: "Использован" }
    }
}

struct EmailChangeControls: View {
    let account: AccountRecord
    let aliases: [EmailAlias]
    let disabled: Bool
    let running: Bool
    let onStart: (String?) -> Void
    let onContinue: () -> Void
    let canExit: Bool
    let onExit: (UUID) -> Void
    let onRestore: () -> Void
    let onVerify: () -> Void
    let onReturn: () -> Void
    let onFreshLogin: () -> Void
    let onReplaceAlias: (String?) -> Void
    let onShowMailbox: () -> Void
    let onShowAliases: () -> Void
    @State private var selectedAlias = ""
    @State private var confirm = false
    @State private var replacingAlias = false
    @State private var showAliasesAfterReplacement = false
    @State private var confirmingExit = false
    @State private var exitingChange: PendingEmailChange?

    private var available: [EmailAlias] { aliases.filter { $0.status == .available } }
    private var target: String? { selectedAlias.isEmpty ? available.first?.email : selectedAlias }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Смена email").font(.headline)
            if let pending = account.pendingEmailChange {
                Text("\(pending.originalEmail) → \(pending.newEmail)")
                    .font(.callout).textSelection(.enabled)
                Text(pending.phase == .reserved ? "Алиас зарезервирован. Запрос кода ещё не отправлен." :
                     pending.phase == .requested ? "Запрос кода начат. Проверьте форму и свежее письмо на новый адрес." :
                     "Подтверждение начато. Требуется проверка входа с новым email.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Продолжить смену email", action: onContinue).disabled(running)
                    if pending.phase != .reserved { Button("Проверить новый email", action: onVerify).disabled(running) }
                    Button("Почта Mail.ru", action: onShowMailbox)
                }
                if pending.phase == .confirming {
                    HStack {
                        Button("Новый вход", action: onFreshLogin)
                            .help("Открыть чистую сессию и повторить вход с новым email")
                        Button("Вернуться к подтверждению email", action: onReturn)
                    }
                    .disabled(running)
                    Text("Если проверочный вход завис, «Новый вход» начнёт его в чистой сессии с новым email.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Button("Выйти из смены email") {
                        if pending.phase == .reserved { onExit(pending.operationID) }
                        else { exitingChange = pending; confirmingExit = true }
                    }.disabled(!canExit)
                    Button("Заменить email для смены") { replacingAlias = true }
                        .disabled(running)
                    Button("База почт", action: onShowAliases)
                }
            } else {
                if let abandoned = account.abandonedEmailChange {
                    Text("Смена email остановлена: \(abandoned.originalEmail) → \(abandoned.newEmail). Результат на сайте не подтверждён.")
                        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    Button("Восстановить проверку смены email", action: onRestore)
                        .disabled(disabled || running || account.email.caseInsensitiveCompare(abandoned.originalEmail) != .orderedSame)
                }
                HStack {
                    Picker("Новый email", selection: $selectedAlias) {
                        Text("Первый свободный алиас").tag("")
                        ForEach(available) { Text($0.email).tag($0.email) }
                    }.disabled(disabled)
                    Button("Сменить email") { confirm = true }.disabled(disabled || target == nil)
                }
                HStack {
                    Button("База почт", action: onShowAliases)
                    Button("Почта Mail.ru", action: onShowMailbox)
                    Text("Свободно: \(available.count)").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .sheet(isPresented: $replacingAlias, onDismiss: {
            if showAliasesAfterReplacement {
                showAliasesAfterReplacement = false
                onShowAliases()
            }
        }) {
            ReplaceEmailAliasSheet(
                currentEmail: account.pendingEmailChange?.newEmail ?? "",
                aliases: available,
                onCancel: { replacingAlias = false },
                onShowAliases: { showAliasesAfterReplacement = true; replacingAlias = false },
                onReplace: { alias in
                    replacingAlias = false
                    onReplaceAlias(alias)
                })
        }
        .confirmationDialog("Сменить email аккаунта?", isPresented: $confirm, titleVisibility: .visible) {
            Button("Сменить email", role: .destructive) { onStart(target) }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("\(account.email) → \(target ?? ""). Приложение получит код из Mail.ru, подтвердит смену и проверит вход. Сохранённый логин заменится только после проверки; пароль и 2FA остаются прежними.")
        }
        .confirmationDialog("Выйти из смены email?", isPresented: $confirmingExit, titleVisibility: .visible, presenting: exitingChange) { change in
            Button("Выйти из смены email") { onExit(change.operationID) }
            Button("Отмена", role: .cancel) {}
        } message: { change in
            Text("Автоматизация и очередь email остановятся. В приложении останется \(change.originalEmail). Изменение на сайте не отменяется: адрес \(change.newEmail) и этап проверки сохранятся для восстановления, алиас не будет выдан другому аккаунту. Пароль, 2FA и сессия сохранятся.")
        }
    }
}

private struct ReplaceEmailAliasSheet: View {
    let currentEmail: String
    let aliases: [EmailAlias]
    let onCancel: () -> Void
    let onShowAliases: () -> Void
    let onReplace: (String) -> Void
    @State private var selectedAlias = ""

    private var target: String? {
        selectedAlias.isEmpty ? aliases.first?.email : aliases.first(where: { $0.email == selectedAlias })?.email
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Заменить email для смены").font(.title2.weight(.semibold))
            Text("Текущий адрес: \(currentEmail)").textSelection(.enabled)
            Text("Если этот адрес уже занят другим аккаунтом, выберите свободный. Текущий адрес будет отмечен использованным в базе почт.")
                .foregroundStyle(.secondary)
            if aliases.isEmpty {
                Text("Свободных адресов нет. Добавьте новый алиас в базу почт.")
            } else {
                Picker("Новый email", selection: $selectedAlias) {
                    Text("Первый свободный алиас").tag("")
                    ForEach(aliases) { Text($0.email).tag($0.email) }
                }
                if let target { Text("Будет выбран: \(target)").font(.callout).textSelection(.enabled) }
            }
            Text("Если подтверждение уже начиналось, приложение сначала проверит, что исходный аккаунт всё ещё использует прежний email. После замены нажмите «Продолжить смену email».")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Button("База почт", action: onShowAliases)
                Spacer()
                Button("Отмена", action: onCancel).keyboardShortcut(.cancelAction)
                Button("Заменить адрес") {
                    if let target { onReplace(target) }
                }
                .disabled(target == nil)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 580)
    }
}
