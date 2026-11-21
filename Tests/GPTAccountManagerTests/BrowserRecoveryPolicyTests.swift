import Testing
@testable import GPTAccountManager

@Suite struct BrowserRecoveryPolicyTests {
    @Test func freshLoginModeMatchesEveryRotationStage() {
        #expect(BrowserRecoveryPolicy.availability(
            context: .subscriptionCheck,
            hasTrustedPage: true,
            hasCandidate: false).freshLoginMode == .storedSecret)
        #expect(BrowserRecoveryPolicy.availability(
            context: .rotation(stage: nil),
            hasTrustedPage: true,
            hasCandidate: false).freshLoginMode == .storedSecret)
        #expect(BrowserRecoveryPolicy.availability(
            context: .rotation(stage: .removingOldMethod),
            hasTrustedPage: true,
            hasCandidate: false).freshLoginMode == .manualFactor)
        #expect(BrowserRecoveryPolicy.availability(
            context: .rotation(stage: .oldMethodDisabled),
            hasTrustedPage: true,
            hasCandidate: false).freshLoginMode == .manualFactor)
        #expect(BrowserRecoveryPolicy.availability(
            context: .rotation(stage: .pendingSecretCaptured),
            hasTrustedPage: true,
            hasCandidate: false).freshLoginMode == .manualFactor)
        #expect(BrowserRecoveryPolicy.availability(
            context: .rotation(stage: .awaitingCleanLogin),
            hasTrustedPage: true,
            hasCandidate: false).freshLoginMode == .pendingSecret)
    }

    @Test func expectedSectionAndReturnActionAreConservative() {
        let check = BrowserRecoveryPolicy.availability(
            context: .subscriptionCheck,
            hasTrustedPage: false,
            hasCandidate: false)
        #expect(!check.canReload)
        #expect(check.reopenDestination == .chatGPT)
        #expect(!check.canReturnToOriginalSession)

        let cleanLogin = BrowserRecoveryPolicy.availability(
            context: .rotation(stage: .awaitingCleanLogin),
            hasTrustedPage: true,
            hasCandidate: false)
        #expect(cleanLogin.canReload)
        #expect(cleanLogin.reopenDestination == nil)

        let candidate = BrowserRecoveryPolicy.availability(
            context: .rotation(stage: .oldMethodDisabled),
            hasTrustedPage: true,
            hasCandidate: true)
        #expect(candidate.reopenDestination == nil)
        #expect(candidate.canReturnToOriginalSession)
        #expect(candidate.warning.contains("Старый 2FA"))
    }
}
