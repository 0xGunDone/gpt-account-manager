import Testing
@testable import GPTAccountManager

@Suite struct RotationStagePresentationTests {
    @Test func everyRecoveryStageHasADistinctActionableStatus() {
        #expect(RotationStagePresentation.status(for: .removingOldMethod) ==
            "Проверяется открытая сессия — повторный вход запрещён")
        #expect(RotationStagePresentation.status(for: .oldMethodDisabled) ==
            "Старый 2FA отключён — продолжение только в открытой сессии")
        #expect(RotationStagePresentation.status(for: .pendingSecretCaptured) ==
            "Новый 2FA подготовлен — подтвердите его в открытой сессии")
        #expect(RotationStagePresentation.status(for: .awaitingCleanLogin) ==
            "Новый 2FA включён — осталось проверить чистый вход")
    }

    @Test func freshRotationIsAvailableOnlyWithoutARecoveryStage() {
        #expect(RotationStagePresentation.allowsFreshRotation(stage: nil))
        for stage in [
            RotationStage.removingOldMethod,
            .oldMethodDisabled,
            .pendingSecretCaptured,
            .awaitingCleanLogin,
        ] {
            #expect(!RotationStagePresentation.allowsFreshRotation(stage: stage))
        }
    }

    @Test func manualSecretRecoveryAppearsOnlyBeforeANewSecretWasCaptured() {
        #expect(RotationStagePresentation.allowsManualSecretRecovery(
            stage: .oldMethodDisabled,
            hasPendingSecret: false))
        #expect(!RotationStagePresentation.allowsManualSecretRecovery(
            stage: .oldMethodDisabled,
            hasPendingSecret: true))
        #expect(!RotationStagePresentation.allowsManualSecretRecovery(
            stage: .pendingSecretCaptured,
            hasPendingSecret: true))
        #expect(!RotationStagePresentation.allowsManualSecretRecovery(
            stage: nil,
            hasPendingSecret: false))
    }
}
