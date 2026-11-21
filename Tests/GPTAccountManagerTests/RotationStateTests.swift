import Foundation
import Testing
@testable import GPTAccountManager

@Suite struct RotationStateTests {
    @Test func pendingSecretPromotesOnlyAfterCleanLogin() throws {
        var account = AccountRecord(credential: .init(
            email: "a@example.com",
            password: "pw",
            totpSecret: "JBSWY3DPEHPK3PXP"))

        RotationState.capture(secret: "KRUGS4ZANFZSAYJA", in: &account)
        #expect(account.totpSecret == "JBSWY3DPEHPK3PXP")
        #expect(account.pendingTOTPSecret == "KRUGS4ZANFZSAYJA")
        #expect(account.status == .needsRecovery)

        RotationState.markSetupConfirmed(in: &account)
        #expect(account.totpSecret == "JBSWY3DPEHPK3PXP")

        try RotationState.markCleanLoginVerified(
            signedInEmail: "A@example.com",
            proof: .init(
                passwordSubmitted: true,
                pendingOTPSubmitted: true,
                authenticatedImmediatelyAfterPendingOTP: true),
            in: &account)
        #expect(account.totpSecret == "KRUGS4ZANFZSAYJA")
        #expect(account.pendingTOTPSecret == nil)
        #expect(account.rotationStage == nil)
        #expect(account.status == .ready)
    }

    @Test func mismatchedIdentityCannotPromotePendingSecret() {
        var account = AccountRecord(credential: .init(
            email: "a@example.com",
            password: "pw",
            totpSecret: "JBSWY3DPEHPK3PXP"))
        RotationState.capture(secret: "KRUGS4ZANFZSAYJA", in: &account)

        #expect(throws: RotationVerificationError.identityOrSecretMissing) {
            try RotationState.markCleanLoginVerified(
                signedInEmail: "other@example.com",
                proof: .init(
                    passwordSubmitted: true,
                    pendingOTPSubmitted: true,
                    authenticatedImmediatelyAfterPendingOTP: true),
                in: &account)
        }
        #expect(account.totpSecret == "JBSWY3DPEHPK3PXP")
        #expect(account.pendingTOTPSecret == "KRUGS4ZANFZSAYJA")
    }

    @Test func oldMethodDisabledCheckpointSurvivesPersistenceWithoutLosingPendingSecret() throws {
        var account = AccountRecord(credential: .init(
            email: "a@example.com",
            password: "pw",
            totpSecret: "JBSWY3DPEHPK3PXP"))
        RotationState.capture(secret: "KRUGS4ZANFZSAYJA", in: &account)

        RotationState.markOldMethodDisabled(in: &account)

        #expect(account.rotationStage == .oldMethodDisabled)
        #expect(account.pendingTOTPSecret == "KRUGS4ZANFZSAYJA")
        #expect(account.totpSecret == "JBSWY3DPEHPK3PXP")
        #expect(account.status == .needsRecovery)

        let data = try JSONEncoder().encode(account)
        let restored = try JSONDecoder().decode(AccountRecord.self, from: data)
        #expect(restored.rotationStage == .oldMethodDisabled)
        #expect(restored.pendingTOTPSecret == "KRUGS4ZANFZSAYJA")
    }

    @Test func manuallyConfiguredSecretWaitsForCleanLoginBeforeReplacingStoredSecret() throws {
        var account = AccountRecord(credential: .init(
            email: "a@example.com",
            password: "pw",
            totpSecret: "JBSWY3DPEHPK3PXP"))
        RotationState.markOldMethodDisabled(in: &account)

        try RotationState.stageManuallyConfiguredSecret(
            " krug-s4za-nfzs-ayja ",
            in: &account)

        #expect(account.totpSecret == "JBSWY3DPEHPK3PXP")
        #expect(account.pendingTOTPSecret == "KRUGS4ZANFZSAYJA")
        #expect(account.rotationStage == .awaitingCleanLogin)
        #expect(account.status == .needsRecovery)
        #expect(account.lastError == nil)
    }

    @Test func manuallyConfiguredSecretRequiresTheDisabledCheckpoint() {
        var account = AccountRecord(credential: .init(
            email: "a@example.com",
            password: "pw",
            totpSecret: "JBSWY3DPEHPK3PXP"))

        #expect(throws: ManualAuthenticatorRecoveryError.invalidStage) {
            try RotationState.stageManuallyConfiguredSecret(
                "KRUGS4ZANFZSAYJA",
                in: &account)
        }
        #expect(account.pendingTOTPSecret == nil)
        #expect(account.rotationStage == nil)
    }

    @Test func manuallyConfiguredSecretMustBeValidBase32() {
        var account = AccountRecord(credential: .init(
            email: "a@example.com",
            password: "pw",
            totpSecret: "JBSWY3DPEHPK3PXP"))
        RotationState.markOldMethodDisabled(in: &account)

        #expect(throws: ManualAuthenticatorRecoveryError.invalidSecret) {
            try RotationState.stageManuallyConfiguredSecret("not-a-secret", in: &account)
        }
        #expect(account.pendingTOTPSecret == nil)
        #expect(account.rotationStage == .oldMethodDisabled)
    }

    @Test func manuallyConfiguredSecretMustDifferFromTheStoredSecret() {
        var account = AccountRecord(credential: .init(
            email: "a@example.com",
            password: "pw",
            totpSecret: "JBSWY3DPEHPK3PXP"))
        RotationState.markOldMethodDisabled(in: &account)

        #expect(throws: ManualAuthenticatorRecoveryError.invalidSecret) {
            try RotationState.stageManuallyConfiguredSecret(
                "jbsw-y3dp-ehpk-3pxp",
                in: &account)
        }
        #expect(account.pendingTOTPSecret == nil)
        #expect(account.rotationStage == .oldMethodDisabled)
    }

    @Test func legacyRemovingStageRemainsDistinctFromConfirmedDisable() {
        #expect(RotationStage.removingOldMethod != .oldMethodDisabled)
        #expect(RotationStage.removingOldMethod.rawValue == "removingOldMethod")
        #expect(RotationStage.oldMethodDisabled.rawValue == "oldMethodDisabled")
    }
}
