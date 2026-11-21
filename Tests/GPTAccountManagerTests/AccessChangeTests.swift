import Foundation
import Testing
@testable import GPTAccountManager

@MainActor
private final class AccessAutomation: SubscriptionChecking, TwoFARotating, PasswordChanging {
    var activeSession: BrowserSession?
    var events: [String] = []
    var passwordAccounts: [AccountRecord] = []
    var submittedPasswordIDs: [UUID] = []
    var requestedPasswords: [String] = []
    var passwordOutcome: PasswordChangeOutcome?
    var checkpoint: (() throws -> Void)?
    var pause2FA = false
    var submitPassword = true
    var retryIDs: [UUID] = []
    func retryPasswordChange(for id: UUID) { retryIDs.append(id) }
    func cancelActiveOperation() {}

    func check(account: AccountRecord) async -> SubscriptionCheckOutcome { .failure("unused") }
    func changePassword(account: AccountRecord, newPassword: String,
                        onSubmission: @escaping @MainActor () throws -> Void) async -> PasswordChangeOutcome {
        events.append("password")
        passwordAccounts.append(account)
        requestedPasswords.append(newPassword)
        do {
            if submitPassword && account.pendingPassword == nil {
                try onSubmission()
                submittedPasswordIDs.append(account.id)
            }
            try checkpoint?()
        }
        catch { return .failure("checkpoint failed") }
        return passwordOutcome ?? .success(signedInEmail: account.email)
    }
    func rotate2FA(account: AccountRecord,
                   onCheckpoint: @escaping @MainActor (RotationCheckpointEvent) throws -> Void) async -> TwoFARotationOutcome {
        events.append("2FA:\(account.password)")
        if pause2FA { return .manualActionRequired(stage: nil, message: "manual") }
        do {
            try onCheckpoint(.removalStarted)
            try onCheckpoint(.secretCaptured("KRUGS4ZANFZSAYJA"))
            try onCheckpoint(.setupConfirmed)
        } catch { return .failure(stage: nil, message: "checkpoint failed") }
        return .success(snapshot: .init(signedInEmail: account.email, planLabel: "plus", activeUntil: nil, willRenew: nil),
                        proof: .init(passwordSubmitted: true, pendingOTPSubmitted: true,
                                     authenticatedImmediatelyAfterPendingOTP: true))
    }
}

@MainActor
struct AccessChangeTests {
    private let configuredPassword = "access-fixture-password"

    private func setup(accountCount: Int = 1, passwordConfigured: Bool = true) throws -> (AccountStore, AccessAutomation, OperationCoordinator) {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("accounts.json")
        let store = AccountStore(fileURL: file)
        try store.merge([.init(email: "test@example.com", password: "old-fixture", totpSecret: "JBSWY3DPEHPK3PXP")])
        for index in 1..<accountCount {
            try store.merge([.init(email: "test\(index)@example.com", password: "old-fixture-\(index)", totpSecret: "JBSWY3DPEHPK3PXP")])
        }
        let automation = AccessAutomation()
        return (store, automation, OperationCoordinator(store: store, checker: automation, rotator: automation,
                                                        configuredPassword: passwordConfigured ? configuredPassword : nil))
    }

    @Test func passwordOnlyLeavesAuthenticatorUntouchedAndPersistsVerifiedPassword() async throws {
        let (store, automation, coordinator) = try setup()
        let original = store.accounts[0]
        automation.checkpoint = {
            let disk = AccountStore(fileURL: store.fileURL)
            try disk.load()
            #expect(disk.accounts[0].password == "old-fixture")
            #expect(disk.accounts[0].pendingPassword == configuredPassword)
            #expect(disk.accounts[0].status == .needsRecovery)
        }
        await coordinator.changeAccess(id: original.id, mode: .password)
        #expect(automation.events == ["password"])
        #expect(store.accounts[0].password == configuredPassword)
        #expect(store.accounts[0].totpSecret == original.totpSecret)
        #expect(store.accounts[0].rotationStage == nil)
        #expect(!store.accounts[0].hasPendingAccessChange)
        #expect(store.accounts[0].status == .ready)
        #expect(store.accounts[0].lastError == nil)
        #expect(coordinator.rotationStates[original.id] == .complete)
    }

    @Test func combinedModePassesSavedNewPasswordIntoUnchangedTwoFAFlow() async throws {
        let (store, automation, coordinator) = try setup()
        await coordinator.changeAccess(id: store.accounts[0].id, mode: .passwordAndTwoFA)
        #expect(automation.events == ["password", "2FA:\(configuredPassword)"])
        #expect(store.accounts[0].totpSecret == "KRUGS4ZANFZSAYJA")
        #expect(!store.accounts[0].hasPendingAccessChange)
    }

    @Test func twoFAOnlyNeverCallsPasswordChange() async throws {
        let (store, automation, coordinator) = try setup(passwordConfigured: false)
        await coordinator.changeAccess(id: store.accounts[0].id, mode: .twoFA)
        #expect(automation.events == ["2FA:old-fixture"])
        #expect(store.accounts[0].password == "old-fixture")
    }

    @Test func interruptedPasswordDoesNotStartTwoFAAndCanResumeAfterRestart() async throws {
        let (store, automation, coordinator) = try setup()
        let id = store.accounts[0].id
        automation.passwordOutcome = .manualActionRequired("email verification")
        await coordinator.changeAccess(id: id, mode: .passwordAndTwoFA)
        #expect(automation.events == ["password"])
        #expect(store.accounts[0].password == "old-fixture")
        #expect(store.accounts[0].pendingPassword == configuredPassword)
        let reloaded = AccountStore(fileURL: store.fileURL)
        try reloaded.load()
        automation.passwordOutcome = nil
        let resumed = OperationCoordinator(store: reloaded, checker: automation, rotator: automation,
                                           configuredPassword: "different-fixture-password")
        await resumed.continueRotation(id: id)
        #expect(automation.requestedPasswords == [configuredPassword, configuredPassword])
        #expect(automation.events == ["password", "password", "2FA:\(configuredPassword)"])
        #expect(!reloaded.accounts[0].hasPendingAccessChange)
    }

    @Test func wrongIdentityDoesNotReplacePasswordOrStartTwoFA() async throws {
        let (store, automation, coordinator) = try setup()
        automation.passwordOutcome = .success(signedInEmail: "other@example.com")
        await coordinator.changeAccess(id: store.accounts[0].id, mode: .passwordAndTwoFA)
        #expect(automation.events == ["password"])
        #expect(store.accounts[0].password == "old-fixture")
        #expect(store.accounts[0].pendingPassword != nil)
    }
    @Test func stopBeforePasswordSubmissionAllowsTwoFAOnly() async throws {
        let (store, automation, coordinator) = try setup()
        let id = store.accounts[0].id
        automation.submitPassword = false
        automation.passwordOutcome = .manualActionRequired("email verification")
        await coordinator.changeAccess(id: id, mode: .passwordAndTwoFA)
        #expect(store.accounts[0].hasPendingAccessChange)
        coordinator.stop()
        #expect(!store.accounts[0].hasPendingAccessChange)
        #expect(store.accounts[0].status == .unchecked)
        #expect(store.accounts[0].lastError == nil)
        await coordinator.changeAccess(id: id, mode: .twoFA)
        #expect(automation.events == ["password", "2FA:old-fixture"])
    }

    @Test(arguments: [false, true])
    func stopBeforeSubmissionDoesNotRestoreRecoveryStateWhenAutomationReturns(manual: Bool) async throws {
        let (store, automation, coordinator) = try setup()
        automation.submitPassword = false
        automation.checkpoint = { coordinator.stop() }
        automation.passwordOutcome = manual ? .manualActionRequired("stopped") : .failure("stopped")
        await coordinator.changeAccess(id: store.accounts[0].id, mode: .password)
        #expect(!store.accounts[0].hasPendingAccessChange)
        #expect(store.accounts[0].status == .unchecked)
        #expect(store.accounts[0].lastError == nil)
        #expect(store.accounts[0].password == "old-fixture")
    }

    @Test func stopAfterSubmissionKeepsBothPasswordsAndMode() async throws {
        let (store, automation, coordinator) = try setup()
        let id = store.accounts[0].id
        automation.passwordOutcome = .manualActionRequired("verification failed")
        await coordinator.changeAccess(id: id, mode: .password)
        coordinator.stop()
        #expect(store.accounts[0].password == "old-fixture")
        #expect(store.accounts[0].pendingPassword == configuredPassword)
        #expect(store.accounts[0].pendingAccessChange == .password)
    }

    @Test func manualPasswordCompletionCanBeVerifiedWithoutSubmittingChangeAgain() async throws {
        let (store, automation, coordinator) = try setup(passwordConfigured: false)
        let id = store.accounts[0].id
        try store.mutate(id: id) { $0.pendingAccessChange = .password }
        automation.checkpoint = { #expect(store.accounts[0].pendingPassword == configuredPassword) }
        await coordinator.verifyManuallyChangedPassword(id: id, password: configuredPassword)
        #expect(automation.submittedPasswordIDs.isEmpty)
        #expect(store.accounts[0].password == configuredPassword)
        #expect(!store.accounts[0].hasPendingAccessChange)
    }

    @Test func completedTwoFAClearsCombinedModeInSameCheckpoint() throws {
        var account = AccountRecord(credential: .init(email: "test@example.com", password: configuredPassword, totpSecret: "JBSWY3DPEHPK3PXP"))
        account.pendingAccessChange = .passwordAndTwoFA
        account.pendingTOTPSecret = "KRUGS4ZANFZSAYJA"
        account.rotationStage = .awaitingCleanLogin
        try RotationState.markCleanLoginVerified(signedInEmail: "test@example.com",
            proof: .init(passwordSubmitted: true, pendingOTPSubmitted: true, authenticatedImmediatelyAfterPendingOTP: true), in: &account)
        #expect(account.pendingAccessChange == nil)
        #expect(account.rotationStage == nil)
        #expect(account.totpSecret == "KRUGS4ZANFZSAYJA")
    }

    @Test func interruptedSubmissionCanReopenUsingRetainedCredentialsAfterRestart() async throws {
        let (store, automation, _) = try setup()
        let id = store.accounts[0].id
        try store.mutate(id: id) {
            $0.pendingPassword = configuredPassword
            $0.pendingAccessChange = .passwordAndTwoFA
        }
        let reloaded = AccountStore(fileURL: store.fileURL)
        try reloaded.load()
        automation.passwordOutcome = .manualActionRequired("retry old password")
        let restarted = OperationCoordinator(store: reloaded, checker: automation, rotator: automation,
                                             configuredPassword: nil)
        await restarted.retryPasswordChange(id: id)
        #expect(automation.retryIDs == [id])
        #expect(automation.events == ["password"])
        #expect(reloaded.accounts[0].password == "old-fixture")
        #expect(reloaded.accounts[0].pendingPassword == configuredPassword)
        #expect(restarted.pausedRotationAccountIDs == [id])
    }

    @Test(arguments: [false, true])
    func groupPasswordChangeResumesFirstAccountAndRemainingAccountsAfterRestart(submitted: Bool) async throws {
        let (store, automation, coordinator) = try setup(accountCount: 3)
        for account in store.accounts { try store.mutate(id: account.id) { $0.status = .ready } }
        let originals = store.accounts
        let ids = originals.map(\.id)
        automation.submitPassword = submitted
        automation.passwordOutcome = .manualActionRequired("email verification")
        await coordinator.changeAccess(accountIDs: ids, mode: .password)
        #expect(automation.passwordAccounts.map(\.id) == [ids[0]])
        #expect(store.accounts[0].pendingAccessChange == .password)
        #expect(store.accounts[0].pendingPassword == (submitted ? configuredPassword : nil))
        #expect(store.accounts[0].status == .needsRecovery)
        #expect(Array(store.accounts.dropFirst()) == Array(originals.dropFirst()))

        let reloaded = AccountStore(fileURL: store.fileURL)
        try reloaded.load()
        #expect(reloaded.accounts[0].lastError == "email verification")
        let resumedAutomation = AccessAutomation()
        let restarted = OperationCoordinator(store: reloaded, checker: resumedAutomation, rotator: resumedAutomation,
                                             configuredPassword: configuredPassword)
        await restarted.changeAccess(accountIDs: ids + [ids[0]], mode: .password, concurrency: 3)

        #expect(resumedAutomation.passwordAccounts.map(\.id) == ids)
        #expect(resumedAutomation.passwordAccounts[0].pendingPassword == (submitted ? configuredPassword : nil))
        #expect(resumedAutomation.submittedPasswordIDs == (submitted ? Array(ids.dropFirst()) : ids))
        #expect(resumedAutomation.requestedPasswords == Array(repeating: configuredPassword, count: 3))
        #expect(resumedAutomation.events == ["password", "password", "password"])
        #expect(resumedAutomation.retryIDs.isEmpty)
        #expect(reloaded.accounts.allSatisfy {
            $0.password == configuredPassword && !$0.hasPendingAccessChange &&
                $0.status == .ready && $0.lastError == nil && $0.rotationStage == nil
        })
        #expect(reloaded.accounts.map(\.totpSecret) == originals.map(\.totpSecret))
        #expect(restarted.rotationTotalCount == 3)
        #expect(restarted.rotationStates.values.allSatisfy { $0 == .complete })

        await restarted.changeAccess(accountIDs: ids, mode: .password)
        #expect(resumedAutomation.passwordAccounts.map(\.id) == ids)
    }

    @Test func repeatingGroupPasswordRequestResumesExistingPausedQueue() async throws {
        let (store, automation, coordinator) = try setup(accountCount: 3)
        let ids = store.accounts.map(\.id)
        automation.submitPassword = false
        automation.passwordOutcome = .manualActionRequired("email verification")
        await coordinator.changeAccess(accountIDs: ids, mode: .password)
        #expect(coordinator.pausedRotationAccountIDs == [ids[0]])
        #expect(coordinator.rotationStates[ids[1]] == .queued)

        automation.submitPassword = true
        automation.passwordOutcome = nil
        await coordinator.changeAccess(accountIDs: ids + [ids[1]], mode: .password)
        #expect(automation.passwordAccounts.map(\.id) == [ids[0]] + ids)
        #expect(automation.submittedPasswordIDs == ids)
        #expect(coordinator.pausedRotationAccountIDs.isEmpty)
        #expect(coordinator.rotationTotalCount == 3)
        #expect(coordinator.rotationStates.values.allSatisfy { $0 == .complete })
        #expect(store.accounts.allSatisfy { $0.password == configuredPassword && !$0.hasPendingAccessChange })
    }

    @Test func passwordGroupRejectsPendingCombinedModeWithoutChangingAnyAccount() async throws {
        let (store, automation, coordinator) = try setup(accountCount: 3)
        try store.mutate(id: store.accounts[0].id) { $0.pendingAccessChange = .passwordAndTwoFA }
        let originals = store.accounts
        await coordinator.changeAccess(accountIDs: originals.map(\.id), mode: .password)
        #expect(automation.events.isEmpty)
        #expect(store.accounts == originals)
        #expect(coordinator.rotationAccountIDs.isEmpty)
        #expect(coordinator.message?.contains("режим отличается") == true)
    }

    @Test func batchWithoutConfiguredPasswordLeavesFreshAndPendingAccountsUntouched() async throws {
        let (store, automation, coordinator) = try setup(accountCount: 2, passwordConfigured: false)
        let ids = store.accounts.map(\.id)
        try store.mutate(id: ids[0]) { $0.pendingPassword = configuredPassword }
        let original = store.accounts
        await coordinator.changeAccess(accountIDs: ids, mode: .password)
        #expect(store.accounts == original)
        #expect(automation.events.isEmpty)
        #expect(coordinator.message == NewPasswordConfiguration.unavailableMessage)

        await coordinator.continueRotation(id: ids[0])
        #expect(automation.requestedPasswords == [configuredPassword])
        #expect(store.accounts[0].password == configuredPassword)
        #expect(store.accounts[1] == original[1])
    }

    @Test func resumingCombinedModeWithVerifiedPasswordNeedsOnlyTwoFA() async throws {
        let (store, automation, coordinator) = try setup()
        let id = store.accounts[0].id
        automation.pause2FA = true
        await coordinator.changeAccess(id: id, mode: .passwordAndTwoFA)

        let reloaded = AccountStore(fileURL: store.fileURL)
        try reloaded.load()
        #expect(reloaded.accounts[0].password == configuredPassword)
        #expect(reloaded.accounts[0].pendingPassword == nil)
        #expect(reloaded.accounts[0].accessChangePasswordVerified == true)

        automation.pause2FA = false
        let restarted = OperationCoordinator(store: reloaded, checker: automation, rotator: automation,
                                             configuredPassword: nil)
        await restarted.continueRotation(id: id)
        #expect(automation.requestedPasswords == [configuredPassword])
        #expect(reloaded.accounts[0].totpSecret == "KRUGS4ZANFZSAYJA")
        #expect(!reloaded.accounts[0].hasPendingAccessChange)
        #expect(reloaded.accounts[0].accessChangePasswordVerified == nil)
    }

    @Test(arguments: [false, true])
    func passwordInterruptionPersistsRecoveryStateAndRedactedError(manual: Bool) async throws {
        let (store, automation, coordinator) = try setup()
        let original = store.accounts[0]
        try store.mutate(id: original.id) { $0.status = .ready }
        let message = "Cannot verify \(original.email) with \(original.password) or \(configuredPassword)"
        automation.passwordOutcome = manual ? .manualActionRequired(message) : .failure(message)
        await coordinator.changeAccess(id: original.id, mode: .password)
        let reloaded = AccountStore(fileURL: store.fileURL)
        try reloaded.load()
        #expect(reloaded.accounts[0].status == .needsRecovery)
        #expect(reloaded.accounts[0].lastError == "Cannot verify [redacted] with [redacted] or [redacted]")
        #expect(reloaded.accounts[0].password == original.password)
        #expect(reloaded.accounts[0].pendingPassword == configuredPassword)
    }

}
