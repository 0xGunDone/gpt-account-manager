import SwiftUI

struct GroupDetailView: View {
    let group: AccountGroup?
    let accounts: [AccountRecord]
    let checkDisabled: Bool
    let importDisabled: Bool
    let rotationDisabled: Bool
    let deleteDisabled: Bool
    let rotationStates: [UUID: RotationQueueItemState]
    let rotationCompletedCount: Int
    let rotationTotalCount: Int
    let accessTokenCount: Int
    let accessTokenCopying: Bool
    let accessTokenMessage: String?
    let onSave: (String, String) -> Void
    let onCopyAll: () -> Void
    let onCopyAccessTokens: () -> Void
    let onExportAccessTokens: () -> Void
    let onOpenAccessTokenFolder: () -> Void
    let onCheck: () -> Void
    let onImportCodex: () -> Void
    let onChangeEmail: () -> Void
    let onRotate: () -> Void
    let onDelete: () -> Void

    @State private var nameText: String
    @State private var tagText: String

    init(
        group: AccountGroup?,
        accounts: [AccountRecord],
        checkDisabled: Bool,
        importDisabled: Bool? = nil,
        rotationDisabled: Bool,
        deleteDisabled: Bool,
        rotationStates: [UUID: RotationQueueItemState],
        rotationCompletedCount: Int,
        rotationTotalCount: Int,
        accessTokenCount: Int,
        accessTokenCopying: Bool,
        accessTokenMessage: String?,
        onSave: @escaping (String, String) -> Void,
        onCopyAll: @escaping () -> Void,
        onCopyAccessTokens: @escaping () -> Void,
        onExportAccessTokens: @escaping () -> Void = {},
        onOpenAccessTokenFolder: @escaping () -> Void,
        onCheck: @escaping () -> Void,
        onImportCodex: @escaping () -> Void,
        onChangeEmail: @escaping () -> Void = {},
        onRotate: @escaping () -> Void,
        onDelete: @escaping () -> Void
    ) {
        self.group = group
        self.accounts = accounts
        self.checkDisabled = checkDisabled
        self.importDisabled = importDisabled ?? checkDisabled
        self.rotationDisabled = rotationDisabled
        self.deleteDisabled = deleteDisabled
        self.rotationStates = rotationStates
        self.rotationCompletedCount = rotationCompletedCount
        self.rotationTotalCount = rotationTotalCount
        self.accessTokenCount = accessTokenCount
        self.accessTokenCopying = accessTokenCopying
        self.accessTokenMessage = accessTokenMessage
        self.onSave = onSave
        self.onCopyAll = onCopyAll
        self.onCopyAccessTokens = onCopyAccessTokens
        self.onExportAccessTokens = onExportAccessTokens
        self.onOpenAccessTokenFolder = onOpenAccessTokenFolder
        self.onCheck = onCheck
        self.onImportCodex = onImportCodex
        self.onChangeEmail = onChangeEmail
        self.onRotate = onRotate
        self.onDelete = onDelete
        _nameText = State(initialValue: group?.name ?? "Без группы")
        _tagText = State(initialValue: group?.tag ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(group?.name ?? "Без группы")
                .font(.title2.weight(.semibold))

            if group != nil {
                HStack(alignment: .bottom, spacing: 12) {
                    TextField("Название", text: $nameText)
                    TextField("Тег", text: $tagText)
                    Button("Сохранить") { onSave(nameText, tagText) }
                }
            }

            HStack(spacing: 10) {
                Button("Копировать все", action: onCopyAll)
                    .disabled(accounts.isEmpty)
                Button("Проверить группу", action: onCheck)
                    .disabled(checkDisabled || !accounts.contains(where: { !$0.hasPendingAccessChange }))
                Button("Импорт группы в CodexAcc", action: onImportCodex)
                    .disabled(importDisabled || accounts.isEmpty)
                Text("Строго по одному")
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                Button("Копировать почта|accessToken", action: onCopyAccessTokens)
                    .disabled(accounts.isEmpty || accessTokenCopying)
                    .help("Обновляет токены из сохранённых сессий, когда нет других операций. Во время операций копирует сохранённый кэш без проверки актуальности.")
                if accessTokenCopying {
                    ProgressView().controlSize(.small)
                }
                Text("В кэше: \(accessTokenCount) из \(accounts.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                Button("Экспорт токенов…", action: onExportAccessTokens).disabled(accounts.isEmpty)
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    let states = accounts.map { AccessTokenMetadata(token: $0.accessToken).validity(at: context.date) }
                    Text("Истекло: \(states.filter { $0 == .expired }.count). Скоро истекут: \(states.filter { $0 == .expiringSoon }.count). Срок неизвестен: \(states.filter { $0 == .unknown }.count).")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            if group?.name.caseInsensitiveCompare("new-novoreg") == .orderedSame {
                HStack(spacing: 10) {
                    Text("Файл почта|accessToken сохраняется автоматически.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Открыть папку", action: onOpenAccessTokenFolder)
                }
            }

            if let accessTokenMessage {
                Text(accessTokenMessage)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                Button("Сменить почту группы", action: onChangeEmail)
                    .disabled(group == nil || importDisabled || !accounts.contains {
                        !$0.hasPendingCredentialChange && $0.rotationStage == nil && $0.pendingTOTPSecret == nil
                    })
                Button("Сменить доступы у группы", action: onRotate)
                    .disabled(
                        group == nil ||
                            !accounts.contains(where: {
                                !$0.hasPendingAccessChange && RotationStagePresentation.allowsFreshRotation(
                                    stage: $0.rotationStage)
                            }) ||
                            rotationDisabled)
                if group != nil {
                    Button("Удалить группу с аккаунтами", role: .destructive, action: onDelete)
                        .disabled(deleteDisabled)
                }
            }

            if group != nil {
                Text("Смена почты: каждому аккаунту — отдельный свободный адрес из базы, строго по одному. Коды приходят в подключённый Mail.ru.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Divider()

            if rotationTotalCount > 0,
               accounts.contains(where: { rotationStates[$0.id] != nil }) {
                ProgressView(
                    value: Double(rotationCompletedCount),
                    total: Double(rotationTotalCount)) {
                        Text("Смена доступов: \(rotationCompletedCount) из \(rotationTotalCount)")
                    }
            }

            if accounts.isEmpty {
                Text("В группе нет аккаунтов")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(accounts) { account in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(account.credentialLine)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                        if let state = rotationStates[account.id] {
                            Text(rotationLabel(state))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else if let stage = account.rotationStage {
                            Text(RotationStagePresentation.status(for: stage))
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                }
            }
        }
        .onChange(of: group) { _, value in
            nameText = value?.name ?? "Без группы"
            tagText = value?.tag ?? ""
        }
    }

    private func rotationLabel(_ state: RotationQueueItemState) -> String {
        switch state {
        case .queued: "В очереди"
        case .running: "Смена доступов"
        case .manualAction: "Нужно ручное действие"
        case .complete: "Готово"
        case .failed: "Ошибка"
        }
    }
}
