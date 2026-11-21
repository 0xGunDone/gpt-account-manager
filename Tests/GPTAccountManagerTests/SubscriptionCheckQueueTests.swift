import Foundation
import Testing
@testable import GPTAccountManager

@MainActor
private final class QueueSubscriptionChecker: SubscriptionChecking {
    var activeSession: BrowserSession? { nil }
    private(set) var checkedIDs: [UUID] = []
    private(set) var continuedIDs: [UUID] = []
    private(set) var cancellationCount = 0
    private(set) var maximumActiveCalls = 0
    private var activeCalls = 0
    private var waitingAccount: AccountRecord?
    private var continuation: CheckedContinuation<SubscriptionCheckOutcome, Never>?

    var isWaiting: Bool { continuation != nil }

    func check(account: AccountRecord) async -> SubscriptionCheckOutcome {
        checkedIDs.append(account.id)
        return await wait(account: account)
    }

    func continueCheck(account: AccountRecord) async -> SubscriptionCheckOutcome {
        continuedIDs.append(account.id)
        return await wait(account: account)
    }

    private func wait(account: AccountRecord) async -> SubscriptionCheckOutcome {
        activeCalls += 1
        maximumActiveCalls = max(maximumActiveCalls, activeCalls)
        defer { activeCalls -= 1 }
        waitingAccount = account
        return await withCheckedContinuation { continuation = $0 }
    }

    func release(_ outcome: SubscriptionCheckOutcome? = nil) {
        guard let account = waitingAccount, let continuation else { return }
        waitingAccount = nil
        self.continuation = nil
        continuation.resume(returning: outcome ?? .success(.init(
            signedInEmail: account.email, planLabel: "plus", activeUntil: nil, willRenew: nil)))
    }

    // Deliberately non-cooperative: late results must not escape the coordinator's stop guard.
    func cancelActiveOperation() { cancellationCount += 1 }
}

@MainActor
private final class QueueRotationFixture: TwoFARotating {
    private(set) var calls = 0
    private var continuation: CheckedContinuation<TwoFARotationOutcome, Never>?

    var isWaiting: Bool { continuation != nil }

    func rotate2FA(
        account: AccountRecord,
        onCheckpoint: @escaping @MainActor (RotationCheckpointEvent) throws -> Void
    ) async -> TwoFARotationOutcome {
        calls += 1
        return await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        continuation?.resume(returning: .failure(stage: nil, message: "Fixture rotation finished"))
        continuation = nil
    }
}

@MainActor
@Suite struct SubscriptionCheckQueueTests {
    private func store(count: Int = 2) throws -> AccountStore {
        let store = AccountStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("accounts.json"))
        try store.merge((0..<count).map {
            .init(email: "queue\($0)@example.com", password: "fixture-password",
                  totpSecret: "JBSWY3DPEHPK3PXP")
        })
        return store
    }

    private func eventually(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<1_000 {
            if condition() { return true }
            await Task.yield()
        }
        return condition()
    }

    @Test func duplicateRequestsAwaitOneAccountCheckWithoutResettingCounts() async throws {
        let store = try store(count: 1)
        defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
        let id = store.accounts[0].id
        let checker = QueueSubscriptionChecker()
        let coordinator = OperationCoordinator(store: store, checker: checker)
        let first = Task { await coordinator.check(id: id) }
        #expect(await eventually { checker.isWaiting })
        var duplicateFinished = false
        let duplicate = Task {
            await coordinator.check(id: id)
            duplicateFinished = true
        }
        for _ in 0..<10 { await Task.yield() }

        #expect(!duplicateFinished)
        #expect(coordinator.totalCount == 1 && coordinator.completedCount == 0)
        #expect(coordinator.checkingAccountID == id && coordinator.pendingCheckCount == 0)
        #expect(coordinator.isCheckingAccounts && coordinator.canEnqueueChecks)
        checker.release()
        await first.value
        await duplicate.value

        #expect(checker.checkedIDs == [id] && checker.cancellationCount == 0)
        #expect(coordinator.completedCount == 1 && store.accounts[0].status == .ready)
        #expect(!coordinator.isRunning && !coordinator.isCheckingAccounts)
    }

    @Test func overlappingRequestsAppendUniqueAccountsAndKeepSerialProgress() async throws {
        let store = try store(count: 3)
        defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
        let ids = store.accounts.map(\.id)
        let group = try store.createGroup(name: "Queue fixture", tag: nil)
        try store.moveAccounts(ids: Set(ids.dropFirst()), to: group.id, protectedIDs: [])
        let checker = QueueSubscriptionChecker()
        let coordinator = OperationCoordinator(store: store, checker: checker)
        let first = Task { await coordinator.check(id: ids[0]) }
        #expect(await eventually { checker.isWaiting })
        let groupRequest = Task { await coordinator.checkGroup(groupID: group.id) }
        #expect(await eventually { coordinator.pendingCheckCount == 2 })
        let allRequest = Task { await coordinator.checkAll() }
        let duplicate = Task { await coordinator.check(id: ids[1]) }
        for _ in 0..<10 { await Task.yield() }

        #expect(coordinator.totalCount == 3 && coordinator.completedCount == 0)
        #expect(coordinator.protectedAccountIDs.isSuperset(of: ids))
        #expect(store.selectedID == ids[0] && checker.checkedIDs == [ids[0]])
        checker.release()
        #expect(await eventually { checker.checkedIDs.count == 2 && checker.isWaiting })
        #expect(coordinator.completedCount == 1 && coordinator.totalCount == 3)
        #expect(coordinator.checkingAccountID == ids[1] && coordinator.pendingCheckCount == 1)
        checker.release()
        #expect(await eventually { checker.checkedIDs.count == 3 && checker.isWaiting })
        checker.release()
        await first.value
        await groupRequest.value
        await allRequest.value
        await duplicate.value

        #expect(checker.checkedIDs == ids && checker.maximumActiveCalls == 1)
        #expect(coordinator.completedCount == 3 && coordinator.totalCount == 3)
        #expect(coordinator.pendingCheckCount == 0 && store.accounts.allSatisfy { $0.status == .ready })
    }

    @Test func cancellingJoinedCallerKeepsSharedAccountCheckRunning() async throws {
        let store = try store(count: 1)
        defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
        let id = store.accounts[0].id
        let checker = QueueSubscriptionChecker()
        let coordinator = OperationCoordinator(store: store, checker: checker)
        let first = Task { await coordinator.check(id: id) }
        #expect(await eventually { checker.isWaiting })
        let duplicate = Task { await coordinator.check(id: id) }
        for _ in 0..<10 { await Task.yield() }
        duplicate.cancel()
        await duplicate.value

        #expect(coordinator.isRunning && coordinator.checkingAccountID == id)
        #expect(checker.cancellationCount == 0 && coordinator.completedCount == 0)
        checker.release()
        await first.value

        #expect(checker.checkedIDs == [id] && store.accounts[0].status == .ready)
        #expect(coordinator.completedCount == 1)
    }

    @Test func manualPauseKeepsOriginalQueueUntilExplicitResume() async throws {
        let store = try store()
        defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
        let ids = store.accounts.map(\.id)
        let checker = QueueSubscriptionChecker()
        let coordinator = OperationCoordinator(store: store, checker: checker)
        let first = Task { await coordinator.checkAll() }
        #expect(await eventually { checker.isWaiting })
        let duplicate = Task { await coordinator.check(id: ids[0]) }
        for _ in 0..<10 { await Task.yield() }
        checker.release(.manualActionRequired("Complete fixture challenge"))
        await first.value
        await duplicate.value

        #expect(coordinator.pausedAccountID == ids[0] && coordinator.pendingCheckCount == 1)
        #expect(coordinator.isCheckingAccounts && !coordinator.isRunning && !coordinator.canEnqueueChecks)
        await coordinator.check(id: ids[0])
        await coordinator.check(id: ids[1])
        #expect(checker.checkedIDs == [ids[0]] && checker.continuedIDs.isEmpty)
        #expect(coordinator.totalCount == 2 && coordinator.completedCount == 0)

        let resumed = Task { await coordinator.resume() }
        #expect(await eventually { checker.continuedIDs == [ids[0]] && checker.isWaiting })
        checker.release()
        #expect(await eventually { checker.checkedIDs == ids && checker.isWaiting })
        checker.release()
        await resumed.value

        #expect(checker.checkedIDs == ids && checker.continuedIDs == [ids[0]])
        #expect(coordinator.pausedAccountID == nil && coordinator.completedCount == 2)
        #expect(!coordinator.isCheckingAccounts)
    }

    @Test func stopDropsPendingAccountsAndIgnoresNonCooperativeLateSuccess() async throws {
        let store = try store()
        defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
        let original = store.accounts
        let checker = QueueSubscriptionChecker()
        let coordinator = OperationCoordinator(store: store, checker: checker)
        let first = Task { await coordinator.checkAll() }
        #expect(await eventually { checker.isWaiting })
        let duplicate = Task { await coordinator.check(id: original[1].id) }
        for _ in 0..<10 { await Task.yield() }

        coordinator.stop()
        #expect(coordinator.pendingCheckCount == 0 && !coordinator.canEnqueueChecks)
        #expect(!coordinator.protectedAccountIDs.contains(original[1].id))
        #expect(coordinator.isRunning)
        checker.release()
        await first.value
        await duplicate.value

        #expect(checker.checkedIDs == [original[0].id] && checker.cancellationCount == 1)
        #expect(store.accounts == original)
        #expect(coordinator.completedCount == 0 && !coordinator.isRunning && !coordinator.isCheckingAccounts)
    }

    @Test(arguments: ["failure", "manual"])
    func callerCancellationCannotWriteLateFailureOrPause(outcome: String) async throws {
        let store = try store(count: 1)
        defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
        let original = store.accounts[0]
        let checker = QueueSubscriptionChecker()
        let coordinator = OperationCoordinator(store: store, checker: checker)
        let first = Task { await coordinator.check(id: original.id) }
        #expect(await eventually { checker.isWaiting })
        first.cancel()
        checker.release(outcome == "failure" ? .failure("Fixture failure") : .manualActionRequired("Fixture challenge"))
        await first.value

        #expect(store.accounts[0] == original)
        #expect(coordinator.pausedAccountID == nil && !coordinator.isRunning && !coordinator.isCheckingAccounts)
    }

    @Test(arguments: ["failure", "manual"])
    func accountEditedDuringCheckCannotReceiveLateFailureOrPause(outcome: String) async throws {
        let store = try store(count: 1)
        defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
        let id = store.accounts[0].id
        let checker = QueueSubscriptionChecker()
        let coordinator = OperationCoordinator(store: store, checker: checker)
        let first = Task { await coordinator.check(id: id) }
        #expect(await eventually { checker.isWaiting })
        try store.mutate(id: id) {
            $0.browserStoreID = UUID()
            $0.status = .needsRecovery
            $0.lastError = "Fixture newer recovery state"
        }
        let edited = store.accounts[0]
        checker.release(outcome == "failure" ? .failure("Fixture failure") : .manualActionRequired("Fixture challenge"))
        await first.value

        #expect(store.accounts[0] == edited)
        #expect(coordinator.pausedAccountID == nil && !coordinator.isRunning)
    }

    @Test func uncertainFailureDoesNotRetryAuthenticationBeforeNextQueuedAccount() async throws {
        let store = try store()
        defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
        let ids = store.accounts.map(\.id)
        let checker = QueueSubscriptionChecker()
        let coordinator = OperationCoordinator(store: store, checker: checker)
        let request = Task { await coordinator.checkAll() }
        #expect(await eventually { checker.isWaiting })
        checker.release(.failure("NSURLErrorDomain Code=-1001 after submitting authentication"))
        #expect(await eventually { checker.checkedIDs == ids && checker.isWaiting })
        #expect(store.accounts[0].status == .failed && checker.continuedIDs.isEmpty)
        checker.release()
        await request.value

        #expect(checker.checkedIDs == ids && coordinator.completedCount == 2)
        #expect(store.accounts[1].status == .ready)
    }

    @Test func pendingCapacityIsBoundedWithoutReplacingAcceptedAccounts() async throws {
        let store = try store(count: 260)
        defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
        let ids = store.accounts.map(\.id)
        let checker = QueueSubscriptionChecker()
        let coordinator = OperationCoordinator(store: store, checker: checker)
        let first = Task { await coordinator.check(id: ids[0]) }
        #expect(await eventually { checker.isWaiting })
        let allRequest = Task { await coordinator.checkAll() }
        #expect(await eventually { coordinator.pendingCheckCount == 256 })

        #expect(coordinator.totalCount == 257 && coordinator.completedCount == 0)
        #expect(coordinator.protectedAccountIDs.isSuperset(of: ids.prefix(257)))
        #expect(Set(ids.suffix(3)).isDisjoint(with: coordinator.protectedAccountIDs))
        #expect(coordinator.message?.contains("256") == true)
        coordinator.stop()
        checker.release()
        await first.value
        await allRequest.value

        #expect(checker.checkedIDs == [ids[0]])
        #expect(store.accounts.allSatisfy { $0.status == .unchecked })
    }

    @Test func runningRotationRejectsCheckRequestsWithoutChangingItsProgress() async throws {
        let store = try store()
        defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
        let checker = QueueSubscriptionChecker()
        let rotator = QueueRotationFixture()
        let coordinator = OperationCoordinator(store: store, checker: checker, rotator: rotator)
        let rotation = Task { await coordinator.rotate2FA(id: store.accounts[0].id) }
        #expect(await eventually { rotator.isWaiting })
        let totalCount = coordinator.totalCount

        await coordinator.check(id: store.accounts[1].id)
        await coordinator.checkAll()
        await coordinator.checkGroup(groupID: nil)

        #expect(!coordinator.isCheckingAccounts && !coordinator.canEnqueueChecks)
        #expect(coordinator.totalCount == totalCount && coordinator.pendingCheckCount == 0)
        #expect(checker.checkedIDs.isEmpty && rotator.calls == 1 && coordinator.isRotating)
        rotator.release()
        await rotation.value
    }
}
