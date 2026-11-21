import Foundation

enum RotationRecoverySessionState: Equatable, Sendable {
    case authenticated
    case unavailable
}

enum RotationRecoveryDecision: Equatable, Sendable {
    case continueRemoval
    case continueSetup
    case manualRecovery
}

enum RotationRecoveryPolicy {
    static func decision(
        stage: RotationStage,
        session: RotationRecoverySessionState,
        authenticatorEnabled: Bool
    ) -> RotationRecoveryDecision {
        guard session == .authenticated else { return .manualRecovery }

        switch stage {
        case .removingOldMethod:
            return authenticatorEnabled ? .continueRemoval : .continueSetup
        case .oldMethodDisabled, .pendingSecretCaptured, .awaitingCleanLogin:
            return .continueSetup
        }
    }

    static func usesOldSecret(for stage: RotationStage) -> Bool {
        stage == .removingOldMethod
    }
}
