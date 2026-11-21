import AppKit
import SwiftUI

struct AccountDetailView: View {
    let account: AccountRecord
    let groups: [AccountGroup]
    let actionsDisabled: Bool
    let checkDisabled: Bool
    let isProtected: Bool
    let deletionDisabled: Bool
    let recoveryActionsDisabled: Bool
    let passwordSetupRequired: Bool
    let isRotationPaused: Bool
    let credentialsEditable: Bool
    let rotationState: RotationQueueItemState?
    let onSaveCredentials: (String) -> String?
    let onSaveExternalMailbox: (ExternalMailboxConfiguration?) -> String?
    let onCopyOneTimeCode: (String) -> Void
    let onOpenOAuth: (String, OAuthCallbackMode) async -> String?
    let onOpenSafari: () async -> String?
    let onSaveTag: (String) -> Void
    let onMove: (UUID?) -> Void
    let onCheck: () -> Void
    let onImportCodex: () -> Void
    let onRotate: () -> Void
    let onStageManualSecret: (String) -> String?
    let onResumeRotation: () -> Void
    let onVerifyManualPassword: (String?) -> Void
    let onStopAccessChange: () -> Void
    let onRetryPasswordChange: () -> Void
    let onDelete: () -> Void

    @State private var tagText: String
    @State private var credentialText: String
    @State private var credentialError: String?
    @State private var externalMailboxAddress: String
    @State private var externalMailboxURL = ""
    @State private var externalMailboxError: String?
    @State private var manualSecretText = ""
    @State private var manualPassword = ""
    @State private var manualSecretError: String?
    @State private var oauthURLText = ""
    @State private var oauthError: String?
    @State private var isOpeningOAuth = false
    @State private var callbackMode: OAuthCallbackMode = .automatic
    @State private var showsSafariError = false
    @State private var safariError = ""
    @State private var safariTask: Task<Void, Never>?

    init(
        account: AccountRecord,
        groups: [AccountGroup],
        actionsDisabled: Bool,
        checkDisabled: Bool? = nil,
        isProtected: Bool,
        deletionDisabled: Bool? = nil,
        recoveryActionsDisabled: Bool,
        passwordSetupRequired: Bool,
        isRotationPaused: Bool,
        credentialsEditable: Bool,
        rotationState: RotationQueueItemState?,
        onSaveCredentials: @escaping (String) -> String?,
        onSaveExternalMailbox: @escaping (ExternalMailboxConfiguration?) -> String?,
        onCopyOneTimeCode: @escaping (String) -> Void,
        onOpenOAuth: @escaping (String, OAuthCallbackMode) async -> String?,
        onOpenSafari: @escaping () async -> String?,
        onSaveTag: @escaping (String) -> Void,
        onMove: @escaping (UUID?) -> Void,
        onCheck: @escaping () -> Void,
        onImportCodex: @escaping () -> Void,
        onRotate: @escaping () -> Void,
        onStageManualSecret: @escaping (String) -> String?,
        onResumeRotation: @escaping () -> Void,
        onVerifyManualPassword: @escaping (String?) -> Void,
        onStopAccessChange: @escaping () -> Void,
        onRetryPasswordChange: @escaping () -> Void,
        onDelete: @escaping () -> Void
    ) {
        self.account = account
        self.groups = groups
        self.actionsDisabled = actionsDisabled
        self.checkDisabled = checkDisabled ?? actionsDisabled
        self.isProtected = isProtected
        self.deletionDisabled = deletionDisabled ?? isProtected
        self.recoveryActionsDisabled = recoveryActionsDisabled
        self.passwordSetupRequired = passwordSetupRequired
        self.isRotationPaused = isRotationPaused
        self.credentialsEditable = credentialsEditable
        self.rotationState = rotationState
        self.onSaveCredentials = onSaveCredentials
        self.onSaveExternalMailbox = onSaveExternalMailbox
        self.onCopyOneTimeCode = onCopyOneTimeCode
        self.onOpenOAuth = onOpenOAuth
        self.onOpenSafari = onOpenSafari
        self.onSaveTag = onSaveTag
        self.onMove = onMove
        self.onCheck = onCheck
        self.onImportCodex = onImportCodex
        self.onRotate = onRotate
        self.onStageManualSecret = onStageManualSecret
        self.onResumeRotation = onResumeRotation
        self.onVerifyManualPassword = onVerifyManualPassword
        self.onStopAccessChange = onStopAccessChange
        self.onRetryPasswordChange = onRetryPasswordChange
        self.onDelete = onDelete
        _tagText = State(initialValue: account.tag ?? "")
        _credentialText = State(initialValue: account.credentialLine)
        _externalMailboxAddress = State(initialValue: account.externalMailbox?.address ?? account.email)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text(account.email)
                    .font(.title2.weight(.semibold))
                    .textSelection(.enabled)
                Text(statusLabel)
                    .foregroundStyle(.secondary)
                TokenStatusView(token: account.accessToken)
            }

            HStack(alignment: .firstTextBaseline, spacing: 10) {
                TextField("LOGIN|PASS|2FA", text: $credentialText)
                    .font(.system(.body, design: .monospaced))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(saveCredentials)
                    .disabled(!credentialsEditable)
                OneTimeCodeView(account: account, onCopy: onCopyOneTimeCode)
                    .fixedSize()
                Button("Сохранить", action: saveCredentials)
                    .disabled(
                        !credentialsEditable ||
                            credentialText == account.credentialLine)
            }
            if let credentialError {
                Text(credentialError)
                    .font(.callout)
                    .foregroundStyle(.red)
            }

            externalMailboxSettings

            VStack(alignment: .leading, spacing: 8) {
                Text("Вход по ссылке в сессии аккаунта")
                    .font(.callout.weight(.semibold))
                HStack(spacing: 10) {
                    TextField("https://… Ссылка для входа", text: $oauthURLText)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(openOAuth)
                        .disabled(oauthDisabled)
                        .accessibilityLabel("Ссылка для входа")
                    Button("Открыть в сессии", action: openOAuth)
                        .disabled(
                            oauthDisabled ||
                                oauthURLText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                Picker("После входа", selection: $callbackMode) {
                    ForEach(OAuthCallbackMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(oauthDisabled)
                Text("После «Проверить» вход сохраняется. Для ручного возврата выберите «Скопировать callback», затем скопируйте URL над браузером.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let oauthError {
                    Text(oauthError)
                        .font(.callout)
                        .foregroundStyle(.red)
                }
            }

            if let pending = account.pendingTOTPSecret {
                Text("Ожидающий 2FA: \(pending)")
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
            }

            if RotationStagePresentation.allowsManualSecretRecovery(
                stage: account.rotationStage,
                hasPendingSecret: account.pendingTOTPSecret != nil
            ) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Новый 2FA уже подключён вручную?")
                        .font(.callout.weight(.semibold))
                    HStack(spacing: 10) {
                        TextField("НОВЫЙ 2FA КЛЮЧ", text: $manualSecretText)
                            .font(.system(.body, design: .monospaced))
                            .textFieldStyle(.roundedBorder)
                            .onSubmit(stageManualSecret)
                        Button("Сохранить и проверить", action: stageManualSecret)
                            .disabled(manualSecretText.isEmpty)
                    }
                    if let manualSecretError {
                        Text(manualSecretError)
                            .font(.callout)
                            .foregroundStyle(.red)
                    }
                }
            }

            Grid(alignment: .leading, horizontalSpacing: 28, verticalSpacing: 12) {
                factRow("Подписка", account.planLabel ?? "Не проверена")
                factRow(dateTitle, subscriptionDate)
                factRow("Последняя проверка", lastCheckedDate)
                if let error = account.lastError {
                    factRow("Ошибка", error)
                }
            }

            HStack(alignment: .bottom, spacing: 12) {
                TextField("Тег", text: $tagText)
                    .onSubmit { onSaveTag(tagText) }
                    .frame(maxWidth: 220)
                Button("Сохранить тег") { onSaveTag(tagText) }

                Picker("Группа", selection: groupBinding) {
                    Text("Без группы").tag(UUID?.none)
                    ForEach(groups) { group in
                        Text(group.name).tag(Optional(group.id))
                    }
                }
                .frame(maxWidth: 260)
            }

            HStack(spacing: 10) {
                Button("Проверить", action: onCheck)
                    .keyboardShortcut(.defaultAction)
                    .disabled(checkDisabled || account.hasPendingAccessChange)
                Button("Импорт в CodexAcc", action: onImportCodex)
                    .disabled(oauthDisabled)
                Button("Сменить доступы", action: onRotate)
                    .disabled(
                        actionsDisabled || account.hasPendingAccessChange ||
                            !RotationStagePresentation.allowsFreshRotation(
                                stage: account.rotationStage))
                if canContinueRotation {
                    Button("Продолжить смену доступов", action: onResumeRotation)
                        .disabled(recoveryActionsDisabled || passwordSetupRequired)
                }
                Button("Удалить аккаунт", role: .destructive, action: onDelete)
                    .disabled(deletionDisabled)
            }

            VStack(alignment: .leading, spacing: 6) {
                Button("Создать ключ доступа в Safari", systemImage: "key", action: openPasskeySettings)
                    .disabled(safariDisabled)
                Text("Обычное окно Safari использует вход в браузере. Создайте ключ доступа вручную.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let rotationState {
                Text(rotationLabel(rotationState))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if account.pendingAccessChangeMode?.changesPassword == true, account.rotationStage == nil,
               account.accessChangePasswordVerified != true {
                if account.pendingPassword != nil {
                    Text("Новый пароль ожидает проверки.")
                        .font(.callout).foregroundStyle(.secondary)
                    Button("Открыть смену пароля заново", action: onRetryPasswordChange)
                        .disabled(recoveryActionsDisabled)
                    Text("Если новый пароль не был принят, повторите смену с текущим сохранённым паролем. Оба пароля сохраняются до проверки.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    if passwordSetupRequired {
                        Text(NewPasswordConfiguration.unavailableMessage)
                            .font(.caption).foregroundStyle(.secondary)
                        SecureField("Пароль, уже установленный в ChatGPT", text: $manualPassword)
                            .textFieldStyle(.roundedBorder)
                    }
                    Button("Пароль уже изменён вручную — проверить") {
                        onVerifyManualPassword(passwordSetupRequired ? manualPassword : nil)
                        manualPassword = ""
                    }
                    .disabled(recoveryActionsDisabled || (passwordSetupRequired && NewPasswordConfiguration.validated(manualPassword) == nil))
                    Text("Текущий сохранённый пароль заменится только после успешного входа.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Отменить смену пароля", action: onStopAccessChange)
                        .disabled(recoveryActionsDisabled)
                }
            }
        }
        .onChange(of: account.tag) { _, tag in
            let value = tag ?? ""
            if tagText != value { tagText = value }
        }
        .onChange(of: account.credentialLine) { _, line in
            if credentialText != line { credentialText = line }
            credentialError = nil
        }
        .onChange(of: account.externalMailbox) { resetExternalMailboxForm() }
        .onChange(of: account.email.lowercased()) { resetExternalMailboxForm() }
        .alert("Не удалось открыть Safari", isPresented: $showsSafariError) {
            Button("ОК", role: .cancel) {}
        } message: {
            Text(safariError)
        }
        .onDisappear { safariTask?.cancel() }
    }

    private var externalMailboxSettings: some View {
        DisclosureGroup(account.externalMailbox == nil ? "Внешняя почта для входа" : "Внешняя почта для входа · настроена") {
            VStack(alignment: .leading, spacing: 8) {
                TextField("Адрес почтового ящика", text: $externalMailboxAddress)
                    .accessibilityLabel("Адрес почтового ящика")
                SecureField("Секретная HTTPS-ссылка API", text: $externalMailboxURL)
                    .accessibilityLabel("Секретная HTTPS-ссылка API")
                    .onSubmit(saveExternalMailbox)
                Text("Коды для входа в ChatGPT и импорта в CodexAcc. Ссылка хранится без шифрования в локальном accounts.json.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Сохранить настройку", action: saveExternalMailbox)
                        .disabled(!canSaveExternalMailbox)
                    if account.externalMailbox != nil {
                        Button("Удалить настройку", role: .destructive) {
                            externalMailboxError = onSaveExternalMailbox(nil)
                        }
                    }
                }
                if let externalMailboxError {
                    Text(externalMailboxError)
                        .font(.callout)
                        .foregroundStyle(.red)
                }
            }
            .textFieldStyle(.roundedBorder)
            .disabled(!credentialsEditable)
            .padding(.top, 8)
        }
    }

    private var canSaveExternalMailbox: Bool {
        credentialsEditable && !externalMailboxAddress.allSatisfy(\.isWhitespace) &&
            !externalMailboxURL.allSatisfy(\.isWhitespace)
    }

    private func saveExternalMailbox() {
        guard canSaveExternalMailbox else { return }
        do {
            let configuration = try ExternalMailboxConfiguration(
                address: externalMailboxAddress, codeURL: externalMailboxURL)
            externalMailboxError = onSaveExternalMailbox(configuration)
            if externalMailboxError == nil { externalMailboxURL = "" }
        } catch {
            externalMailboxError = "Проверьте адрес почтового ящика и HTTPS-ссылку API."
        }
    }

    private func resetExternalMailboxForm() {
        externalMailboxAddress = account.externalMailbox?.address ?? account.email
        externalMailboxURL = ""
        externalMailboxError = nil
    }

    private var groupBinding: Binding<UUID?> {
        Binding(
            get: { account.groupID },
            set: { groupID in
                guard groupID != account.groupID else { return }
                onMove(groupID)
            })
    }

    private func saveCredentials() {
        guard credentialsEditable,
              credentialText != account.credentialLine
        else { return }
        credentialError = onSaveCredentials(credentialText)
    }

    private func stageManualSecret() {
        guard !manualSecretText.isEmpty else { return }
        manualSecretError = onStageManualSecret(manualSecretText)
        if manualSecretError == nil {
            manualSecretText = ""
        }
    }

    private func openPasskeySettings() {
        guard !safariDisabled else { return }
        safariTask = Task {
            defer { safariTask = nil }
            if let message = await onOpenSafari(), !Task.isCancelled {
                safariError = message
                showsSafariError = true
            }
        }
    }

    private var safariDisabled: Bool {
        safariTask != nil || actionsDisabled || isProtected || account.rotationStage != nil ||
            account.pendingTOTPSecret != nil || account.hasPendingCredentialChange
    }

    private var oauthDisabled: Bool {
        isOpeningOAuth || actionsDisabled || isProtected || account.rotationStage != nil || account.pendingTOTPSecret != nil || account.hasPendingAccessChange
    }

    private func openOAuth() {
        guard !oauthDisabled else { return }
        let value = oauthURLText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        let mode = callbackMode
        isOpeningOAuth = true
        oauthError = nil
        Task {
            oauthError = await onOpenOAuth(value, mode)
            isOpeningOAuth = false
            if oauthError == nil { oauthURLText = "" }
        }
    }

    private func factRow(_ title: String, _ value: String) -> some View {
        GridRow {
            Text(title).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled)
        }
    }

    private var statusLabel: String {
        switch account.status {
        case .unchecked: "Не проверен"
        case .checking: "Проверяется"
        case .ready: "Готов"
        case .failed: "Ошибка"
        case .needsRecovery:
            account.hasPendingEmailChange ? "Смена email не завершена" :
                (account.rotationStage.map(RotationStagePresentation.status(for:)) ??
                "Требуется восстановление доступов")
        }
    }

    private var canContinueRotation: Bool {
        if account.rotationStage != nil || account.hasPendingAccessChange { return true }
        if case .manualAction = rotationState { return true }
        if isRotationPaused { return true }
        return false
    }

    private func rotationLabel(_ state: RotationQueueItemState) -> String {
        switch state {
        case .queued: "Доступы: в очереди"
        case .running: "Доступы: выполняется"
        case .manualAction(let message): "Доступы: требуется действие — \(message)"
        case .complete: "Доступы: смена завершена"
        case .failed(let message): "Доступы: ошибка — \(message)"
        }
    }

    private var dateTitle: String {
        switch account.subscriptionDateKind {
        case .renews: "Продление"
        case .expires: "Окончание"
        case nil: "Дата подписки"
        }
    }

    private var subscriptionDate: String {
        guard let date = account.subscriptionDate else { return "Нет данных" }
        return date.formatted(date: .long, time: .omitted)
    }

    private var lastCheckedDate: String {
        guard let date = account.lastCheckedAt else { return "Никогда" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}
