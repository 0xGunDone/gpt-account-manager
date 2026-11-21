import Testing
@testable import GPTAccountManager

@Suite struct RotationRecoveryPolicyTests {
    @Test func authenticatedLegacyStageUsesVisibleAuthenticatorState() {
        #expect(RotationRecoveryPolicy.decision(
            stage: .removingOldMethod,
            session: .authenticated,
            authenticatorEnabled: true) == .continueRemoval)
        #expect(RotationRecoveryPolicy.decision(
            stage: .removingOldMethod,
            session: .authenticated,
            authenticatorEnabled: false) == .continueSetup)
    }

    @Test func authenticatedConfirmedDisableContinuesSetup() {
        #expect(RotationRecoveryPolicy.decision(
            stage: .oldMethodDisabled,
            session: .authenticated,
            authenticatorEnabled: true) == .continueSetup)
        #expect(RotationRecoveryPolicy.decision(
            stage: .oldMethodDisabled,
            session: .authenticated,
            authenticatorEnabled: false) == .continueSetup)
    }

    @Test func unavailableSessionAlwaysStopsStagedRecovery() {
        for stage in [
            RotationStage.removingOldMethod,
            .oldMethodDisabled,
            .pendingSecretCaptured,
            .awaitingCleanLogin,
        ] {
            #expect(RotationRecoveryPolicy.decision(
                stage: stage,
                session: .unavailable,
                authenticatorEnabled: true) == .manualRecovery)
            #expect(RotationRecoveryPolicy.decision(
                stage: stage,
                session: .unavailable,
                authenticatorEnabled: false) == .manualRecovery)
        }
    }

    @Test func onlyLegacyRemovalMayUseTheOldSecret() {
        #expect(RotationRecoveryPolicy.usesOldSecret(for: .removingOldMethod))
        #expect(!RotationRecoveryPolicy.usesOldSecret(for: .oldMethodDisabled))
        #expect(!RotationRecoveryPolicy.usesOldSecret(for: .pendingSecretCaptured))
        #expect(!RotationRecoveryPolicy.usesOldSecret(for: .awaitingCleanLogin))
    }
}
