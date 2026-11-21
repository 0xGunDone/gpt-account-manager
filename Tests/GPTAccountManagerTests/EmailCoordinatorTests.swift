import Foundation
import Testing
@testable import GPTAccountManager

@MainActor
private final class EmailFixtureChecker: SubscriptionChecking, TwoFARotating {
    var activeSession: BrowserSession?
    var calls = 0
    func cancelActiveOperation() {}
    func check(account: AccountRecord) async -> SubscriptionCheckOutcome { calls += 1; return .failure("unused") }
    func rotate2FA(account: AccountRecord, onCheckpoint: @escaping @MainActor (RotationCheckpointEvent) throws -> Void) async -> TwoFARotationOutcome {
        calls += 1; return .failure(stage: nil, message: "unused")
    }
}

@MainActor
private final class EmailFixtureChanger: EmailChanging {
    var calls = 0
    var checkpoint: (() throws -> Void)?
    var pause = false
    var wrongIdentity = false
    var cancelled = false
    var resetAccounts: [AccountRecord] = []
    var receivedAccounts: [AccountRecord] = []
    var preparedAccounts: [AccountRecord] = []
    var proofAccounts: [AccountRecord] = []
    var replacementProof = EmailChangeProof(email: "old@example.com", userID: "stable-user")
    var holdProof = false
    var resetAccepted = true
    var hold = false
    var suspended: CheckedContinuation<Void, Never>?
    func resetVerificationSession(for account: AccountRecord) -> Bool {
        resetAccounts.append(account)
        return resetAccepted
    }
    func prepareSession(for account: AccountRecord) { preparedAccounts.append(account) }
    func browserSession(for account: AccountRecord) -> BrowserSession? { nil }
    func cancel() { cancelled = true }
    func originalIdentityForAliasReplacement(account: AccountRecord) async throws -> EmailChangeProof {
        proofAccounts.append(account)
        if holdProof { await withCheckedContinuation { suspended = $0 } }
        return replacementProof
    }
    func changeEmail(account: AccountRecord, onCheckpoint: @escaping @MainActor (PendingEmailChange) throws -> Void) async -> EmailChangeOutcome {
        calls += 1
        receivedAccounts.append(account)
        if hold { await withCheckedContinuation { suspended = $0 } }
        do {
            var pending = try #require(account.pendingEmailChange)
            if pending.phase == .reserved {
                pending.phase = .requested
                pending.requestedAt = Date()
                pending.originalUserID = "stable-user"
                pending.baselineMessageIDs = ["old-message"]
                try onCheckpoint(pending)
            }
            try checkpoint?()
            if pause { return .manual("waiting for email") }
            pending.phase = .confirming
            try onCheckpoint(pending)
            return .success(.init(email: pending.newEmail, userID: wrongIdentity ? "wrong-user" : "stable-user"))
        } catch { return .failure("checkpoint rejected") }
    }
}

@MainActor
struct EmailCoordinatorTests {
    private func setup() throws -> (AccountStore, EmailFixtureChecker, EmailFixtureChanger, OperationCoordinator) {
        let store = AccountStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("accounts.json"))
        try store.merge([.init(email: "old@example.com", password: "fixture-password", totpSecret: "JBSWY3DPEHPK3PXP")])
        _ = try store.importEmailAliases("new-fixture@icloud.com\nother-fixture@icloud.com")
        let checker = EmailFixtureChecker()
        let changer = EmailFixtureChanger()
        return (store, checker, changer, OperationCoordinator(store: store, checker: checker, rotator: checker, emailChanger: changer))
    }

    private func reserve(_ store: AccountStore, phase: EmailChangePhase) throws -> AccountRecord {
        let id = store.accounts[0].id
        var change = try store.reserveEmailChange(id: id)
        if phase != .reserved {
            change.originalUserID = "stable-user"
            change.requestedAt = Date()
            change.baselineMessageIDs = ["before-request"]
            change.requestAttemptID = UUID()
            change.phase = .requested
            try store.checkpointEmailChange(id: id, change: change)
            if phase == .confirming {
                change.phase = .confirming
                try store.checkpointEmailChange(id: id, change: change)
            }
        }
        return store.accounts[0]
    }

    @Test func changesEmailOnlyAfterVerifiedProofWithoutChangingPasswordOrTwoFA() async throws {
        let (store, checker, changer, coordinator) = try setup()
        let before = store.accounts[0]
        changer.checkpoint = {
            let reloaded = AccountStore(fileURL: store.fileURL)
            try reloaded.load()
            #expect(reloaded.accounts[0].email == "old@example.com")
            #expect(reloaded.accounts[0].pendingEmailChange?.phase == .requested)
            #expect(reloaded.emailAliases[0].status == .reserved)
        }
        await coordinator.changeEmail(id: before.id)
        let after = store.accounts[0]
        #expect(after.email == "new-fixture@icloud.com")
        #expect(after.id == before.id && after.browserStoreID == before.browserStoreID)
        #expect(after.password == before.password && after.totpSecret == before.totpSecret)
        #expect(after.pendingEmailChange == nil)
        #expect(store.emailAliases[0].status == .used)
        #expect(checker.calls == 0)
        #expect(coordinator.completedCount == 1)
    }

    @Test func exitSubmittedEmailChangeUnlocksOtherActionsAndCanRestore() async throws {
        let (store, checker, changer, coordinator) = try setup()
        let account = try reserve(store, phase: .requested)
        let pending = try #require(account.pendingEmailChange)
        await coordinator.exitEmailChange(id: account.id, operationID: pending.operationID)
        #expect(!coordinator.hasPendingEmailChange && !coordinator.protectedAccountIDs.contains(account.id))
        #expect(changer.cancelled && changer.calls == 0)
        #expect(store.accounts[0].email == account.email && store.accounts[0].browserStoreID == account.browserStoreID)
        #expect(store.accounts[0].abandonedEmailChange == pending)
        await coordinator.check(id: account.id)
        #expect(checker.calls == 1)
        coordinator.restoreAbandonedEmailChange(id: account.id)
        #expect(coordinator.hasPendingEmailChange)
        #expect(store.accounts[0].pendingEmailChange == pending)
        #expect(changer.calls == 0)
    }

    @Test func exitWaitsForCancellationAndRejectsLateCheckpoint() async throws {
        let (store, _, changer, coordinator) = try setup()
        let account = try reserve(store, phase: .requested)
        let pending = try #require(account.pendingEmailChange)
        changer.hold = true
        let running = Task { await coordinator.continueEmailChange(id: account.id) }
        while changer.suspended == nil { await Task.yield() }
        let exit = Task { await coordinator.exitEmailChange(id: account.id, operationID: pending.operationID) }
        while !changer.cancelled { await Task.yield() }
        #expect(store.accounts[0].pendingEmailChange == pending)
        changer.suspended?.resume()
        await running.value
        if coordinator.exitingEmailAccountID != nil {
            await coordinator.continueEmailChange(id: account.id)
            #expect(changer.calls == 1)
        }
        await exit.value
        #expect(!coordinator.isRunning && !coordinator.hasPendingEmailChange)
        #expect(store.accounts[0].pendingEmailChange == nil)
        #expect(store.accounts[0].abandonedEmailChange == pending)
        #expect(store.accounts[0].email == account.email)
    }

    @Test func staleExitCannotClearAnotherEmailOperation() async throws {
        let (store, _, changer, coordinator) = try setup()
        let account = try reserve(store, phase: .requested)
        await coordinator.exitEmailChange(id: account.id, operationID: UUID())
        #expect(store.accounts[0] == account && !changer.cancelled)
    }

    @Test func pausedEmailSurvivesRestartAndBlocksCompetingOperations() async throws {
        let (store, checker, changer, coordinator) = try setup()
        let id = store.accounts[0].id
        changer.pause = true
        await coordinator.changeEmail(id: id)
        coordinator.stop()
        #expect(store.accounts[0].pendingEmailChange?.phase == .requested)
        let disk = AccountStore(fileURL: store.fileURL)
        try disk.load()
        let restarted = OperationCoordinator(store: disk, checker: checker, rotator: checker, emailChanger: changer)
        await restarted.check(id: id)
        await restarted.rotate2FA(id: id)
        #expect(checker.calls == 0)
        #expect(restarted.protectedAccountIDs.contains(id))
        changer.pause = false
        await restarted.continueEmailChange(id: id)
        #expect(disk.accounts[0].email == "new-fixture@icloud.com")
        #expect(disk.emailAliases[1].status == .available)
    }

    @Test func wrongRemoteIdentityNeverCommitsCandidate() async throws {
        let (store, _, changer, coordinator) = try setup()
        changer.wrongIdentity = true
        await coordinator.changeEmail(id: store.accounts[0].id)
        #expect(store.accounts[0].email == "old@example.com")
        #expect(store.accounts[0].pendingEmailChange?.phase == .confirming)
        #expect(store.emailAliases[0].status == .reserved)
    }

    @Test func requestCheckpointFailureDoesNotReturnAliasToPool() async throws {
        let (store, _, changer, coordinator) = try setup()
        let id = store.accounts[0].id
        changer.checkpoint = { coordinator.stop() }
        await coordinator.changeEmail(id: id)
        #expect(changer.cancelled)
        #expect(store.accounts[0].email == "old@example.com")
        #expect(store.emailAliases[0].status == .reserved)
        #expect(store.accounts[0].pendingEmailChange?.phase == .requested)
        #expect(!coordinator.isRunning)
    }

    @Test func freshEmailLoginPreservesSavedOperationAndRetriesOnlyVerification() async throws {
        let (store, checker, changer, coordinator) = try setup()
        let id = store.accounts[0].id
        var change = try store.reserveEmailChange(id: id)
        change.originalUserID = "stable-user"
        change.requestedAt = Date()
        change.baselineMessageIDs = ["before-request"]
        change.phase = .requested
        try store.checkpointEmailChange(id: id, change: change)
        change.phase = .confirming
        try store.checkpointEmailChange(id: id, change: change)
        let before = store.accounts[0]
        let aliases = store.emailAliases
        changer.pause = true
        await coordinator.startFreshEmailLogin(id: id)

        #expect(changer.resetAccounts == [before])
        #expect(changer.receivedAccounts == [before])
        #expect(store.accounts[0] == before)
        #expect(store.emailAliases == aliases)
        #expect(coordinator.browserSession(for: id) == nil)
        #expect(checker.calls == 0)
        #expect(!coordinator.isRunning)

        changer.pause = false
        await coordinator.continueEmailChange(id: id)
        #expect(store.accounts[0].email == "new-fixture@icloud.com")
        #expect(store.accounts[0].pendingEmailChange == nil)
        #expect(store.emailAliases[0].status == .used)
    }

    @Test func freshEmailLoginCannotResetRunningOrUnconfirmedOperation() async throws {
        let (store, _, changer, coordinator) = try setup()
        let id = store.accounts[0].id
        await coordinator.startFreshEmailLogin(id: id)
        _ = try store.reserveEmailChange(id: id)
        await coordinator.startFreshEmailLogin(id: id)
        var change = try #require(store.accounts[0].pendingEmailChange)
        change.phase = .requested
        change.requestedAt = Date()
        change.originalUserID = "stable-user"
        try store.checkpointEmailChange(id: id, change: change)
        await coordinator.startFreshEmailLogin(id: id)
        #expect(changer.resetAccounts.isEmpty)
        #expect(changer.calls == 0)

        change.phase = .confirming
        try store.checkpointEmailChange(id: id, change: change)
        changer.resetAccepted = false
        await coordinator.startFreshEmailLogin(id: id)
        #expect(changer.calls == 0)

        changer.hold = true
        changer.pause = true
        let task = Task { await coordinator.continueEmailChange(id: id) }
        while changer.suspended == nil { try await Task.sleep(for: .milliseconds(5)) }
        let resetCount = changer.resetAccounts.count
        await coordinator.startFreshEmailLogin(id: id)
        await coordinator.replaceEmailAlias(id: id)
        #expect(changer.resetAccounts.count == resetCount)
        #expect(changer.proofAccounts.isEmpty)
        #expect(changer.calls == 1)
        changer.suspended?.resume()
        await task.value
        #expect(store.accounts[0].pendingEmailChange == change)
    }

    @Test(arguments: [EmailChangePhase.reserved, .requested, .confirming])
    func replacingAliasStartsFreshReservationWithoutSendingNewAddress(phase: EmailChangePhase) async throws {
        let (store, checker, changer, coordinator) = try setup()
        let before = try reserve(store, phase: phase)
        await coordinator.replaceEmailAlias(id: before.id, alias: "other-fixture@icloud.com")
        let after = store.accounts[0]
        let pending = try #require(after.pendingEmailChange)
        #expect(changer.proofAccounts == (phase == .reserved ? [] : [before]))
        #expect(changer.calls == 0 && checker.calls == 0)
        #expect(changer.preparedAccounts == [after])
        #expect(pending.phase == .reserved && pending.operationID != before.pendingEmailChange?.operationID)
        #expect(pending.newEmail == "other-fixture@icloud.com")
        #expect(pending.requestedAt == nil && pending.requestAttemptID == nil && pending.baselineMessageIDs.isEmpty)
        #expect(after.email == before.email && after.password == before.password && after.totpSecret == before.totpSecret)
        #expect(after.browserStoreID == before.browserStoreID)
        #expect(store.emailAliases[0].status == .used && store.emailAliases[0].accountID == nil)
        #expect(store.emailAliases[1].status == .reserved && store.emailAliases[1].accountID == before.id)
        #expect(!coordinator.isRunning && coordinator.changingEmailAccountID == nil)
        #expect(coordinator.message?.contains("Продолжить смену email") == true)
    }

    @Test(arguments: [false, true])
    func aliasReplacementRejectsWrongRemoteIdentity(wrongUser: Bool) async throws {
        let (store, _, changer, coordinator) = try setup()
        let before = try reserve(store, phase: .confirming)
        let aliases = store.emailAliases
        changer.replacementProof = .init(email: wrongUser ? before.email : "new-fixture@icloud.com",
                                         userID: wrongUser ? "different-user" : "stable-user")
        await coordinator.replaceEmailAlias(id: before.id)
        #expect(store.accounts[0] == before && store.emailAliases == aliases)
        #expect(changer.calls == 0 && changer.preparedAccounts.isEmpty)
        #expect(!coordinator.isRunning)
    }

    @Test func stoppedAliasReplacementPreservesSavedOperation() async throws {
        let (store, _, changer, coordinator) = try setup()
        let before = try reserve(store, phase: .confirming)
        let aliases = store.emailAliases
        changer.holdProof = true
        let task = Task { await coordinator.replaceEmailAlias(id: before.id) }
        while changer.suspended == nil { try await Task.sleep(for: .milliseconds(5)) }
        #expect(coordinator.isRunning && coordinator.changingEmailAccountID == before.id)
        coordinator.stop()
        changer.suspended?.resume()
        await task.value
        #expect(changer.cancelled)
        #expect(store.accounts[0] == before && store.emailAliases == aliases)
        #expect(changer.calls == 0 && changer.preparedAccounts.isEmpty)
        #expect(!coordinator.isRunning && coordinator.changingEmailAccountID == nil)
    }

    @Test func changedOperationRejectsStaleAliasReplacementProof() async throws {
        let (store, _, changer, coordinator) = try setup()
        let before = try reserve(store, phase: .confirming)
        changer.holdProof = true
        let task = Task { await coordinator.replaceEmailAlias(id: before.id) }
        while changer.suspended == nil { try await Task.sleep(for: .milliseconds(5)) }
        try store.replaceEmailChangeAlias(id: before.id, operationID: before.pendingEmailChange!.operationID,
                                         alias: nil, originalProof: changer.replacementProof)
        let updated = store.accounts[0]
        let aliases = store.emailAliases
        changer.suspended?.resume()
        await task.value
        #expect(store.accounts[0] == updated && store.emailAliases == aliases)
        #expect(changer.calls == 0 && changer.preparedAccounts.isEmpty)
        #expect(!coordinator.isRunning)
    }
}
