import Foundation
import Testing
@testable import GPTAccountManager

@MainActor
private final class GroupEmailChecker: SubscriptionChecking, TwoFARotating {
    var activeSession: BrowserSession?
    var calls = 0
    func cancelActiveOperation() {}
    func check(account: AccountRecord) async -> SubscriptionCheckOutcome {
        calls += 1
        return .failure("unused")
    }
    func rotate2FA(account: AccountRecord, onCheckpoint: @escaping @MainActor (RotationCheckpointEvent) throws -> Void) async -> TwoFARotationOutcome {
        calls += 1
        return .failure(stage: nil, message: "unused")
    }
}

private enum GroupEmailResult: Equatable {
    case success, manual, failure, unsubmittedManual, wrongIdentity
}

@MainActor
private final class GroupEmailChanger: EmailChanging {
    var results: [GroupEmailResult] = []
    var receivedAccounts: [AccountRecord] = []
    var requestedOperationIDs: [UUID] = []
    var beforeResult: ((AccountRecord) throws -> Void)?
    var holdResult = false
    var suspended: CheckedContinuation<Void, Never>?
    var cancelled = false
    var activeCalls = 0
    var maximumActiveCalls = 0

    func prepareSession(for account: AccountRecord) {}
    func browserSession(for account: AccountRecord) -> BrowserSession? { nil }
    func cancel() { cancelled = true }

    func changeEmail(account: AccountRecord, onCheckpoint: @escaping @MainActor (PendingEmailChange) throws -> Void) async -> EmailChangeOutcome {
        receivedAccounts.append(account)
        activeCalls += 1
        maximumActiveCalls = max(maximumActiveCalls, activeCalls)
        defer { activeCalls -= 1 }
        let result = results.isEmpty ? .success : results.removeFirst()
        do {
            var pending = try #require(account.pendingEmailChange)
            if case .unsubmittedManual = result { return .manual("before request") }
            if pending.phase == .reserved {
                requestedOperationIDs.append(pending.operationID)
                pending.phase = .requested
                pending.originalUserID = account.id.uuidString
                pending.requestedAt = Date()
                pending.requestAttemptID = UUID()
                pending.baselineMessageIDs = ["fixture-old-message"]
                try onCheckpoint(pending)
            }
            switch result {
            case .manual: return .manual("fixture manual step")
            case .failure: return .failure("fixture failure")
            case .success, .wrongIdentity, .unsubmittedManual: break
            }
            if pending.phase != .confirming {
                pending.phase = .confirming
                try onCheckpoint(pending)
            }
            try beforeResult?(account)
            if holdResult { await withCheckedContinuation { suspended = $0 } }
            return .success(.init(email: pending.newEmail,
                                  userID: result == .wrongIdentity ? "wrong-user" : account.id.uuidString))
        } catch { return .failure("fixture checkpoint rejected") }
    }
}

@MainActor
struct GroupEmailChangeTests {
    private func setup(aliasCount: Int = 3) throws -> (AccountStore, AccountGroup, GroupEmailChecker, GroupEmailChanger, OperationCoordinator) {
        let store = AccountStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathComponent("accounts.json"))
        try store.merge((0..<4).map {
            .init(email: "group-fixture-\($0)@example.com", password: "fixture-password-\($0)", totpSecret: "JBSWY3DPEHPK3PXP")
        })
        let group = try store.createGroup(name: "Email fixture", tag: "fixture")
        try store.moveAccounts(ids: Set(store.accounts.prefix(3).map(\.id)), to: group.id, protectedIDs: [])
        if aliasCount > 0 {
            _ = try store.importEmailAliases((0..<aliasCount).map { "alias-fixture-\($0)@icloud.com" }.joined(separator: "\n"))
        }
        let checker = GroupEmailChecker()
        let changer = GroupEmailChanger()
        let coordinator = OperationCoordinator(store: store, checker: checker, rotator: checker, emailChanger: changer)
        return (store, group, checker, changer, coordinator)
    }

    @Test func groupChangesSeriallyWithDistinctAliasesAndPreservesCredentialsAndMembership() async throws {
        let (store, group, checker, changer, coordinator) = try setup()
        let before = store.accounts
        var reservedCounts: [Int] = []
        changer.beforeResult = { account in
            reservedCounts.append(store.emailAliases.filter { $0.status == .reserved }.count)
            #expect(store.accounts.filter(\.hasPendingEmailChange).map(\.id) == [account.id])
            #expect(coordinator.protectedAccountIDs.isSuperset(of: coordinator.emailQueueAccountIDs))
            #expect(coordinator.completedCount == changer.receivedAccounts.count - 1)
            #expect(coordinator.totalCount == 3)
        }

        await coordinator.changeEmail(groupID: group.id)

        #expect(changer.receivedAccounts.map(\.id) == before.prefix(3).map(\.id))
        #expect(reservedCounts == [1, 1, 1])
        #expect(changer.maximumActiveCalls == 1)
        #expect(Set(changer.requestedOperationIDs).count == 3)
        #expect(Set(store.accounts.prefix(3).map(\.email)).count == 3)
        #expect(store.emailAliases.allSatisfy { $0.status == .used })
        #expect(coordinator.completedCount == 3 && coordinator.totalCount == 3)
        #expect(coordinator.emailQueueRemainingCount == 0 && !coordinator.hasPendingEmailChange)
        #expect(!coordinator.isRunning && checker.calls == 0)
        for index in 0..<3 {
            #expect(store.accounts[index].email == "alias-fixture-\(index)@icloud.com")
            #expect(store.accounts[index].id == before[index].id)
            #expect(store.accounts[index].browserStoreID == before[index].browserStoreID)
            #expect(store.accounts[index].groupID == group.id)
            #expect(store.accounts[index].password == before[index].password)
            #expect(store.accounts[index].totpSecret == before[index].totpSecret)
            #expect(store.accounts[index].pendingEmailChange == nil)
        }
        #expect(store.accounts[3] == before[3])
    }

    @Test(arguments: [false, true])
    func pauseResumesCurrentRequestAndThenRemainingWithoutRepeatingCompletedAccounts(failure: Bool) async throws {
        let (store, group, checker, changer, coordinator) = try setup()
        let ids = store.accounts.prefix(3).map(\.id)
        changer.results = [.success, failure ? .failure : .manual]
        await coordinator.changeEmail(groupID: group.id)
        let pending = try #require(store.accounts[1].pendingEmailChange)
        #expect(coordinator.emailQueueAccountIDs == Array(ids.dropFirst()))
        #expect(coordinator.completedCount == 1 && coordinator.totalCount == 3)
        #expect(coordinator.pendingEmailAccountIDs == [ids[1]])
        #expect(store.emailAliases.map(\.status) == [.used, .reserved, .available])
        #expect(store.accounts[2].pendingEmailChange == nil)

        await coordinator.check(id: ids[2])
        await coordinator.rotate2FA(id: ids[2])
        await coordinator.changeEmail(id: ids[2])
        await coordinator.changeEmail(groupID: group.id)
        #expect(checker.calls == 0 && changer.receivedAccounts.count == 2)
        #expect(throws: AccountStoreError.accountBusy) {
            try store.moveAccounts(ids: [ids[2]], to: nil, protectedIDs: coordinator.protectedAccountIDs)
        }
        await coordinator.continueEmailChange(id: ids[1])

        #expect(changer.receivedAccounts.map(\.id) == [ids[0], ids[1], ids[1], ids[2]])
        #expect(changer.receivedAccounts[2].pendingEmailChange == pending)
        #expect(changer.requestedOperationIDs.count == 3)
        #expect(Set(changer.requestedOperationIDs).count == 3)
        #expect(coordinator.completedCount == 3 && coordinator.totalCount == 3)
        #expect(coordinator.emailQueueAccountIDs.isEmpty)
    }

    @Test func stopRetainsCurrentReservationAndUnstartedQueueEvenWhenSuccessArrivesLate() async throws {
        let (store, group, _, changer, coordinator) = try setup()
        let before = store.accounts
        changer.holdResult = true
        let task = Task { await coordinator.changeEmail(groupID: group.id) }
        while changer.suspended == nil { try await Task.sleep(for: .milliseconds(5)) }
        coordinator.stop()
        changer.suspended?.resume()
        await task.value

        #expect(changer.cancelled && changer.receivedAccounts.count == 1)
        #expect(store.accounts[0].email == before[0].email)
        #expect(store.accounts[0].pendingEmailChange?.phase == .confirming)
        #expect(store.emailAliases.map(\.status) == [.reserved, .available, .available])
        #expect(coordinator.emailQueueAccountIDs == before.prefix(3).map(\.id))
        #expect(!coordinator.isRunning && coordinator.completedCount == 0)
        changer.holdResult = false
        await coordinator.resumeEmailGroup()
        #expect(changer.requestedOperationIDs.count == 3)
        #expect(changer.receivedAccounts.map(\.id) == [before[0].id, before[0].id, before[1].id, before[2].id])
        #expect(coordinator.completedCount == 3 && coordinator.emailQueueAccountIDs.isEmpty)
    }

    @Test func insufficientAliasesRejectsGroupBeforeAnyMutation() async throws {
        let (store, group, _, changer, coordinator) = try setup(aliasCount: 2)
        let before = store.accounts
        let aliases = store.emailAliases
        let fileData = try Data(contentsOf: store.fileURL)
        await coordinator.changeEmail(groupID: group.id)
        #expect(store.accounts == before && store.emailAliases == aliases)
        #expect(try Data(contentsOf: store.fileURL) == fileData)
        #expect(changer.receivedAccounts.isEmpty && coordinator.emailQueueAccountIDs.isEmpty)
        #expect(coordinator.message?.contains("нужно 3, доступно 2") == true)
    }

    @Test func pauseBeforeReservationCanResumeAndBlocksCompetingOperations() async throws {
        let (store, group, checker, changer, coordinator) = try setup()
        let ids = store.accounts.prefix(3).map(\.id)
        changer.beforeResult = { _ in
            for alias in store.emailAliases where alias.status == .available {
                try store.deleteAvailableEmailAlias(id: alias.id)
            }
        }
        await coordinator.changeEmail(groupID: group.id)
        #expect(coordinator.completedCount == 1)
        #expect(coordinator.pendingEmailAccountIDs.isEmpty)
        #expect(coordinator.emailQueueAccountIDs == Array(ids.dropFirst()))
        #expect(coordinator.hasPendingEmailChange && !coordinator.isRunning)
        coordinator.stop()
        await coordinator.checkAll()
        await coordinator.changeEmail(id: store.accounts[3].id)
        #expect(checker.calls == 0 && changer.receivedAccounts.count == 1)
        #expect(coordinator.protectedAccountIDs.isSuperset(of: ids.dropFirst()))

        changer.beforeResult = nil
        _ = try store.importEmailAliases("replacement-fixture-1@icloud.com\nreplacement-fixture-2@icloud.com")
        await coordinator.resumeEmailGroup()
        #expect(changer.receivedAccounts.map(\.id) == ids)
        #expect(coordinator.completedCount == 3 && coordinator.totalCount == 3)
        #expect(!coordinator.hasPendingEmailChange)
    }

    @Test func wrongIdentityPausesQueueAndRestartRecoversOnlyPersistedCurrentOperation() async throws {
        let (store, group, checker, changer, coordinator) = try setup()
        let before = store.accounts
        changer.results = [.wrongIdentity]
        await coordinator.changeEmail(groupID: group.id)
        #expect(store.accounts[0].email == before[0].email)
        #expect(store.accounts[0].pendingEmailChange?.phase == .confirming)
        #expect(coordinator.emailQueueRemainingCount == 3 && coordinator.completedCount == 0)
        let reloaded = AccountStore(fileURL: store.fileURL)
        try reloaded.load()
        let restarted = OperationCoordinator(store: reloaded, checker: checker, rotator: checker, emailChanger: changer)
        await restarted.changeEmail(groupID: group.id)
        await restarted.checkAll()
        #expect(changer.receivedAccounts.count == 1 && checker.calls == 0)
        #expect(restarted.protectedAccountIDs.contains(before[0].id))
        await restarted.continueEmailChange(id: before[0].id)
        #expect(reloaded.accounts[0].email == "alias-fixture-0@icloud.com")
        #expect(reloaded.emailAliases.map(\.status) == [.used, .available, .available])
        #expect(reloaded.accounts[1] == before[1] && reloaded.accounts[2] == before[2])
        #expect(changer.requestedOperationIDs.count == 1)
    }

    @Test func unsubmittedCancellationAbortsRemainingGroup() async throws {
        let (store, group, _, changer, coordinator) = try setup()
        let before = store.accounts
        changer.results = [.unsubmittedManual]
        await coordinator.changeEmail(groupID: group.id)
        coordinator.cancelUnsubmittedEmailChange(id: before[0].id)
        await coordinator.resumeEmailGroup()
        #expect(coordinator.emailQueueAccountIDs.isEmpty && !coordinator.hasPendingEmailChange)
        #expect(store.accounts == before)
        #expect(store.emailAliases.allSatisfy { $0.status == .available })
        #expect(changer.receivedAccounts.count == 1)
    }

    @Test func exitingUnavailableEmailClearsQueueWithoutChangingFinishedOrUnstartedAccounts() async throws {
        let (store, group, checker, changer, coordinator) = try setup()
        changer.results = [.success, .manual]
        await coordinator.changeEmail(groupID: group.id)
        let before = store.accounts
        let pending = try #require(before[1].pendingEmailChange)
        await coordinator.exitEmailChange(id: before[1].id, operationID: pending.operationID)
        #expect(coordinator.emailQueueAccountIDs.isEmpty && !coordinator.hasPendingEmailChange)
        #expect(store.accounts[0] == before[0] && store.accounts[2] == before[2] && store.accounts[3] == before[3])
        #expect(store.accounts[1].email == before[1].email && store.accounts[1].status == .unchecked)
        #expect(store.accounts[1].abandonedEmailChange == pending)
        #expect(store.emailAliases.map(\.status) == [.used, .used, .available])
        #expect(coordinator.completedCount == 1 && coordinator.totalCount == 1)
        await coordinator.resumeEmailGroup()
        #expect(changer.receivedAccounts.count == 2)
        await coordinator.check(id: before[2].id)
        #expect(checker.calls == 1)
    }

    @Test(arguments: [false, true])
    func cancellingRemainderKeepsOnlyPersistedCurrentOperation(currentPending: Bool) async throws {
        let (store, group, checker, changer, coordinator) = try setup()
        let ids = store.accounts.prefix(3).map(\.id)
        changer.results = [.success, .manual]
        changer.beforeResult = { _ in
            coordinator.cancelEmailGroupQueue()
            #expect(coordinator.emailQueueRemainingCount == 3)
            if !currentPending {
                for alias in store.emailAliases where alias.status == .available {
                    try store.deleteAvailableEmailAlias(id: alias.id)
                }
            }
        }
        await coordinator.changeEmail(groupID: group.id)
        let before = store.accounts
        let aliases = store.emailAliases
        coordinator.cancelEmailGroupQueue()
        await coordinator.resumeEmailGroup()

        #expect(coordinator.emailQueueAccountIDs.isEmpty)
        #expect(store.accounts == before && store.emailAliases == aliases)
        #expect(coordinator.completedCount == (currentPending ? 0 : 1))
        #expect(coordinator.totalCount == 1)
        #expect(coordinator.hasPendingEmailChange == currentPending)
        #expect(!coordinator.protectedAccountIDs.contains(ids[2]))
        if currentPending {
            #expect(coordinator.protectedAccountIDs == [ids[1]])
            await coordinator.check(id: ids[2])
            #expect(checker.calls == 0)
            changer.beforeResult = nil
            await coordinator.continueEmailChange(id: ids[1])
            #expect(changer.receivedAccounts.map(\.id) == [ids[0], ids[1], ids[1]])
            #expect(store.accounts[2] == before[2])
            #expect(coordinator.completedCount == 1 && coordinator.totalCount == 1)
        } else {
            await coordinator.check(id: ids[2])
            #expect(checker.calls == 1)
            #expect(changer.receivedAccounts.map(\.id) == [ids[0]])
        }
        #expect(!coordinator.hasPendingEmailChange)
    }

    @Test func groupSkipsRecoveryMembersAndReportsWhenNoEligibleAccountsRemain() async throws {
        let (store, group, _, changer, coordinator) = try setup(aliasCount: 1)
        try store.mutate(id: store.accounts[0].id) { $0.rotationStage = .oldMethodDisabled }
        try store.mutate(id: store.accounts[1].id) { $0.pendingAccessChange = .password }
        let before = store.accounts
        await coordinator.changeEmail(groupID: group.id)
        #expect(changer.receivedAccounts.map(\.id) == [before[2].id])
        #expect(coordinator.completedCount == 1 && coordinator.totalCount == 1)
        #expect(store.accounts[0] == before[0] && store.accounts[1] == before[1])
        try store.mutate(id: before[2].id) { $0.pendingTOTPSecret = "JBSWY3DPEHPK3PXP" }
        await coordinator.changeEmail(groupID: group.id)
        #expect(coordinator.message == "В группе нет аккаунтов для новой смены email.")
        #expect(changer.receivedAccounts.count == 1)
    }
}
