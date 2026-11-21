enum RotationStagePresentation {
    static func status(for stage: RotationStage) -> String {
        switch stage {
        case .removingOldMethod:
            "Проверяется открытая сессия — повторный вход запрещён"
        case .oldMethodDisabled:
            "Старый 2FA отключён — продолжение только в открытой сессии"
        case .pendingSecretCaptured:
            "Новый 2FA подготовлен — подтвердите его в открытой сессии"
        case .awaitingCleanLogin:
            "Новый 2FA включён — осталось проверить чистый вход"
        }
    }

    static func allowsFreshRotation(stage: RotationStage?) -> Bool {
        stage == nil
    }

    static func allowsManualSecretRecovery(
        stage: RotationStage?,
        hasPendingSecret: Bool
    ) -> Bool {
        stage == .oldMethodDisabled && !hasPendingSecret
    }
}
