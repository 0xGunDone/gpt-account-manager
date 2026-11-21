import Foundation
import Testing
import WebKit
@testable import GPTAccountManager

@MainActor
private final class FakeChecker: SubscriptionChecking {
    var activeSession: BrowserSession?
    var checked: [String] = []
    var continued: [String] = []
    var outcomes: [SubscriptionCheckOutcome] = []

    func check(account: AccountRecord) async -> SubscriptionCheckOutcome {
        checked.append(account.email)
        if !outcomes.isEmpty { return outcomes.removeFirst() }
        return .success(.init(
            signedInEmail: account.email,
            planLabel: "plus",
            activeUntil: nil,
            willRenew: nil))
    }

    func continueCheck(account: AccountRecord) async -> SubscriptionCheckOutcome {
        continued.append(account.email)
        if !outcomes.isEmpty { return outcomes.removeFirst() }
        return .success(.init(
            signedInEmail: account.email,
            planLabel: "plus",
            activeUntil: nil,
            willRenew: nil))
    }
}

@MainActor
private final class CancellableChecker: SubscriptionChecking {
    var activeSession: BrowserSession?
    private(set) var started = false
    private(set) var cancelRequested = false

    func check(account: AccountRecord) async -> SubscriptionCheckOutcome {
        started = true
        for _ in 0..<100 {
            if cancelRequested { return .failure("Cancelled") }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return .failure("Timed out")
    }

    func cancelActiveOperation() {
        cancelRequested = true
    }
}

@MainActor
private final class FakeRotator: TwoFARotating {
    var calls = 0

    func rotate2FA(
        account: AccountRecord,
        onCheckpoint: @escaping @MainActor (RotationCheckpointEvent) throws -> Void
    ) async -> TwoFARotationOutcome {
        calls += 1
        if calls == 1 {
            do {
                try onCheckpoint(.removalStarted)
                try onCheckpoint(.secretCaptured("KRUGS4ZANFZSAYJA"))
                try onCheckpoint(.setupConfirmed)
                return .manualActionRequired(
                    stage: .awaitingCleanLogin,
                    message: "Log out manually")
            } catch {
                return .failure(stage: account.rotationStage, message: "Checkpoint failed")
            }
        }
        return .success(
            snapshot: .init(
                signedInEmail: account.email,
                planLabel: "unknown",
                activeUntil: nil,
                willRenew: nil),
            proof: .init(
                passwordSubmitted: true,
                pendingOTPSubmitted: true,
                authenticatedImmediatelyAfterPendingOTP: true))
    }
}

@MainActor
private final class UnprovenRotator: TwoFARotating {
    func rotate2FA(
        account: AccountRecord,
        onCheckpoint: @escaping @MainActor (RotationCheckpointEvent) throws -> Void
    ) async -> TwoFARotationOutcome {
        .success(
            snapshot: .init(
                signedInEmail: account.email,
                planLabel: "unknown",
                activeUntil: nil,
                willRenew: nil),
            proof: .init(passwordSubmitted: true, pendingOTPSubmitted: true))
    }
}

@MainActor
private final class SnapshotRotator: TwoFARotating {
    let snapshot: SubscriptionSnapshot

    init(snapshot: SubscriptionSnapshot) {
        self.snapshot = snapshot
    }

    func rotate2FA(
        account: AccountRecord,
        onCheckpoint: @escaping @MainActor (RotationCheckpointEvent) throws -> Void
    ) async -> TwoFARotationOutcome {
        .success(
            snapshot: snapshot,
            proof: .init(
                passwordSubmitted: true,
                pendingOTPSubmitted: true,
                authenticatedImmediatelyAfterPendingOTP: true))
    }
}

@MainActor
private final class CancellableRotator: TwoFARotating {
    private(set) var started = 0
    private(set) var cancelRequested = false
    var pauseBeforeWaiting = false
    var returnManualAfterCancel = false

    func rotate2FA(
        account: AccountRecord,
        onCheckpoint: @escaping @MainActor (RotationCheckpointEvent) throws -> Void
    ) async -> TwoFARotationOutcome {
        started += 1
        if pauseBeforeWaiting && started == 1 {
            return .manualActionRequired(stage: account.rotationStage, message: "Retry login")
        }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .milliseconds(250))
        while !cancelRequested && clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        if returnManualAfterCancel && cancelRequested {
            return .manualActionRequired(stage: account.rotationStage, message: "Interrupted page")
        }
        return .failure(stage: nil, message: cancelRequested ? "Stopped" : "Synthetic timeout")
    }

    func cancelActiveOperation() {
        cancelRequested = true
    }
}

@MainActor
private final class ConcurrencyTrackingRotator: TwoFARotating {
    private(set) var active = 0
    private(set) var maximumActive = 0
    private(set) var started: [String] = []
    var manualEmails: Set<String> = []
    var failureEmails: Set<String> = []
    private(set) var preparedIDs: Set<UUID> = []

    func prepareBrowserSession(for account: AccountRecord) {
        preparedIDs.insert(account.id)
    }

    func rotate2FA(
        account: AccountRecord,
        onCheckpoint: @escaping @MainActor (RotationCheckpointEvent) throws -> Void
    ) async -> TwoFARotationOutcome {
        active += 1
        maximumActive = max(maximumActive, active)
        started.append(account.email)
        try? await Task.sleep(for: .milliseconds(80))
        active -= 1
        if manualEmails.contains(account.email) {
            return .manualActionRequired(stage: nil, message: "Complete CAPTCHA")
        }
        do {
            if account.rotationStage == nil {
                try onCheckpoint(.removalStarted)
                try onCheckpoint(.oldMethodDisabled)
            }
            if failureEmails.contains(account.email) {
                return .failure(stage: .oldMethodDisabled, message: "Page stalled after disabling old method")
            }
            try onCheckpoint(.secretCaptured("MFRGGZDFMZTWQ2LK"))
            try onCheckpoint(.setupConfirmed)
            return .success(snapshot: .init(signedInEmail: account.email, planLabel: "plus", activeUntil: nil, willRenew: nil),
                            proof: .init(passwordSubmitted: true, pendingOTPSubmitted: true, authenticatedImmediatelyAfterPendingOTP: true))
        } catch { return .failure(stage: account.rotationStage, message: "Checkpoint failed") }
    }
}

@MainActor
private final class FakeBrowserRecovery: BrowserRecoveryHandling {
    var session: BrowserSession?
    var hasCandidate = false
    var suspendedReload: CheckedContinuation<Void, Never>?
    var holdReload = false
    var nextResult: BrowserRecoveryResult = .manualAction("Ожидается действие")
    private(set) var reloadCalls: [UUID] = []
    private(set) var reopenCalls: [UUID] = []
    private(set) var freshCalls: [UUID] = []
    private(set) var returnCalls: [UUID] = []

    func recoverySession(
        for account: AccountRecord,
        context: BrowserRecoveryContext
    ) -> BrowserSession? { session }

    func hasCandidateSession(for accountID: UUID) -> Bool { hasCandidate }

    func rotationRecoverySessionState(for account: AccountRecord) -> RotationRecoverySessionState {
        .unavailable
    }

    func reloadRecoveryPage(
        for account: AccountRecord,
        context: BrowserRecoveryContext
    ) async -> BrowserRecoveryResult {
        reloadCalls.append(account.id)
        if holdReload { await withCheckedContinuation { suspendedReload = $0 } }
        return nextResult
    }

    func reopenExpectedPage(
        for account: AccountRecord,
        context: BrowserRecoveryContext
    ) async -> BrowserRecoveryResult {
        reopenCalls.append(account.id)
        return nextResult
    }

    func startFreshLogin(
        for account: AccountRecord,
        context: BrowserRecoveryContext
    ) async -> BrowserRecoveryResult {
        freshCalls.append(account.id)
        return nextResult
    }

    func returnToOriginalSession(for account: AccountRecord) {
        returnCalls.append(account.id)
    }
}


@MainActor
@Suite struct OperationCoordinatorTests {
    private func store(accountCount: Int = 2) throws -> AccountStore {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("accounts.json")
        let store = AccountStore(fileURL: file)
        try store.merge((0..<accountCount).map { index in
            .init(
                email: "user\(index)@example.com",
                password: "password",
                totpSecret: index.isMultiple(of: 2)
                    ? "JBSWY3DPEHPK3PXP"
                    : "KRUGS4ZANFZSAYJA")
        })
        return store
    }

    @Test func checkAllPreservesSequentialOrder() async throws {
        let store = try store()
        let checker = FakeChecker()
        let coordinator = OperationCoordinator(store: store, checker: checker)

        await coordinator.checkAll()

        #expect(checker.checked == ["user0@example.com", "user1@example.com"])
        #expect(coordinator.completedCount == 2)
        #expect(!coordinator.isRunning)
        #expect(store.accounts.allSatisfy { $0.status == .ready })
    }

    @Test func checkGroupOnlyChecksEligibleMembersInStoreOrder() async throws {
        let store = try store(accountCount: 5)
        let group = try store.createGroup(name: "Пачка", tag: nil)
        let otherGroup = try store.createGroup(name: "Другая", tag: nil)
        let members = [store.accounts[0], store.accounts[2], store.accounts[4]]
        try store.moveAccounts(ids: Set(members.map(\.id)), to: group.id, protectedIDs: [])
        try store.moveAccounts(ids: [store.accounts[1].id], to: otherGroup.id, protectedIDs: [])
        try store.mutate(id: members[1].id) { $0.pendingAccessChange = .password }
        let before = store.accounts
        let checker = FakeChecker()
        let coordinator = OperationCoordinator(store: store, checker: checker)

        await coordinator.checkGroup(groupID: group.id)

        #expect(checker.checked == [members[0].email, members[2].email])
        #expect(coordinator.totalCount == 2)
        #expect(coordinator.completedCount == 2)
        #expect(!coordinator.isRunning)
        for index in [1, 2, 3] { #expect(store.accounts[index] == before[index]) }
    }

    @Test func checkUngroupedOnlyChecksAccountsWithoutAGroup() async throws {
        let store = try store(accountCount: 3)
        let group = try store.createGroup(name: "Пачка", tag: nil)
        try store.moveAccounts(ids: [store.accounts[1].id], to: group.id, protectedIDs: [])
        let groupedAccount = store.accounts[1]
        let checker = FakeChecker()
        let coordinator = OperationCoordinator(store: store, checker: checker)

        await coordinator.checkGroup(groupID: nil)

        #expect(checker.checked == [store.accounts[0].email, store.accounts[2].email])
        #expect(coordinator.totalCount == 2)
        #expect(coordinator.completedCount == 2)
        #expect(store.accounts[1] == groupedAccount)
    }

    @Test func emptyAndUnknownGroupsNeverCheckOtherAccounts() async throws {
        let store = try store()
        let group = try store.createGroup(name: "Пустая", tag: nil)
        let before = store.accounts
        let checker = FakeChecker()
        let coordinator = OperationCoordinator(store: store, checker: checker)

        for groupID in [group.id, UUID()] {
            await coordinator.checkGroup(groupID: groupID)
            #expect(checker.checked.isEmpty)
            #expect(coordinator.totalCount == 0)
            #expect(coordinator.completedCount == 0)
            #expect(!coordinator.isRunning)
        }
        #expect(store.accounts == before)
    }

    @Test func groupCheckPauseKeepsOriginalMembersAndRejectsReplacementQueues() async throws {
        let store = try store(accountCount: 4)
        let group = try store.createGroup(name: "Пачка", tag: nil)
        let otherGroup = try store.createGroup(name: "Другая", tag: nil)
        let members = [store.accounts[0], store.accounts[2]]
        try store.moveAccounts(ids: Set(members.map(\.id)), to: group.id, protectedIDs: [])
        try store.moveAccounts(ids: [store.accounts[1].id], to: otherGroup.id, protectedIDs: [])
        let before = store.accounts
        let checker = FakeChecker()
        checker.outcomes = [.manualActionRequired("Complete CAPTCHA")]
        let coordinator = OperationCoordinator(store: store, checker: checker)

        await coordinator.checkGroup(groupID: group.id)
        await coordinator.checkGroup(groupID: otherGroup.id)
        await coordinator.checkGroup(groupID: nil)

        #expect(checker.checked == [members[0].email])
        #expect(coordinator.pausedAccountID == members[0].id)
        #expect(coordinator.totalCount == 2)
        #expect(coordinator.completedCount == 0)
        #expect(coordinator.message == "Complete CAPTCHA")
        await coordinator.resume()
        #expect(checker.checked == members.map(\.email))
        #expect(checker.continued == [members[0].email])
        #expect(coordinator.pausedAccountID == nil)
        #expect(coordinator.completedCount == 2)
        for index in [1, 3] { #expect(store.accounts[index] == before[index]) }
    }

    @Test func groupCheckPreservesPendingEmailChange() async throws {
        let store = try store()
        let group = try store.createGroup(name: "Пачка", tag: nil)
        try store.moveAccounts(ids: [store.accounts[1].id], to: group.id, protectedIDs: [])
        _ = try store.importEmailAliases("new-fixture@icloud.com")
        _ = try store.reserveEmailChange(id: store.accounts[0].id)
        let before = store.accounts
        let checker = FakeChecker()
        let coordinator = OperationCoordinator(store: store, checker: checker)

        await coordinator.checkGroup(groupID: group.id)

        #expect(checker.checked.isEmpty)
        #expect(coordinator.totalCount == 0)
        #expect(store.accounts == before)
    }

    @Test func groupCheckPreservesPausedRotation() async throws {
        let store = try store()
        let group = try store.createGroup(name: "Пачка", tag: nil)
        try store.moveAccounts(ids: [store.accounts[1].id], to: group.id, protectedIDs: [])
        let checker = FakeChecker()
        let coordinator = OperationCoordinator(store: store, checker: checker, rotator: FakeRotator())
        await coordinator.rotate2FA(id: store.accounts[0].id)
        let before = store.accounts
        let message = coordinator.message

        await coordinator.checkGroup(groupID: group.id)

        #expect(checker.checked.isEmpty)
        #expect(coordinator.pausedRotationAccountIDs == [store.accounts[0].id])
        #expect(coordinator.totalCount == 1)
        #expect(coordinator.message == message)
        #expect(store.accounts == before)
    }

    @Test func groupCheckEnqueuesWithoutReplacingAnActiveCheck() async throws {
        let store = try store(accountCount: 3)
        let group = try store.createGroup(name: "Пачка", tag: nil)
        try store.moveAccounts(ids: Set(store.accounts.dropFirst().map(\.id)), to: group.id, protectedIDs: [])
        let checker = CancellableChecker()
        let coordinator = OperationCoordinator(store: store, checker: checker)
        let task = Task { await coordinator.check(id: store.accounts[0].id) }
        while !checker.started { await Task.yield() }

        let groupTask = Task { await coordinator.checkGroup(groupID: group.id) }
        for _ in 0..<200 where coordinator.pendingCheckCount < 2 { await Task.yield() }

        #expect(coordinator.isRunning)
        #expect(coordinator.totalCount == 3)
        #expect(coordinator.pendingCheckCount == 2)
        #expect(store.selectedID == store.accounts[0].id)
        #expect(store.accounts.dropFirst().allSatisfy { $0.status == .unchecked })
        coordinator.stop()
        await task.value
        await groupTask.value
    }

    @Test func completedCheckKeepsItsBrowserAvailableForTheAccount() async throws {
        let store = try store(accountCount: 1)
        let account = try #require(store.accounts.first)
        let checker = FakeChecker()
        let session = BrowserSession(dataStore: .nonPersistent())
        checker.activeSession = session
        let coordinator = OperationCoordinator(store: store, checker: checker)

        await coordinator.check(id: account.id)

        #expect(coordinator.browserSession(for: account.id) === session)
    }

    @Test func oauthUsesChosenAccountAfterCheckingAnotherAccount() async throws {
        let store = try store()
        let first = store.accounts[0]
        let second = store.accounts[1]
        let checker = FakeChecker()
        let browser = ManualOAuthFixtureSessions()
        let coordinator = OperationCoordinator(store: store, checker: checker, accountSessions: browser)
        let firstSession = browser.accountSession(for: first)
        let secondSession = browser.accountSession(for: second)
        checker.activeSession = firstSession
        await coordinator.check(id: first.id)
        checker.activeSession = secondSession
        await coordinator.check(id: second.id)

        let error = await coordinator.openOAuthURL(for: first.id, text:
            "https://auth.openai.com/oauth/authorize?client_id=fixture&redirect_uri=http%3A%2F%2Flocalhost%3A1455%2Fauth%2Fcallback&state=fixture")
        firstSession.cancelLoading()

        #expect(error == nil)
        #expect(store.selectedID == first.id)
        #expect(coordinator.browserSession(for: first.id) === firstSession)
        #expect(coordinator.browserSession(for: second.id) === secondSession)
        #expect(firstSession.allowsNavigation(URL(string: "http://localhost:1455/auth/callback?code=x&state=fixture")))
        #expect(!secondSession.allowsNavigation(URL(string: "http://localhost:1455/auth/callback?code=x&state=fixture")))
        firstSession.endOAuth()
        #expect(!firstSession.allowsNavigation(URL(string: "http://localhost:1455/auth/callback?code=x&state=fixture")))
    }

    @Test func oauthCannotReplaceAPausedAuthenticationPage() async throws {
        let store = try store(accountCount: 1)
        let account = store.accounts[0]
        let checker = FakeChecker()
        checker.outcomes = [.manualActionRequired("Complete challenge")]
        let browser = ChatGPTAutomation(sessionManager: WebSessionManager())
        let coordinator = OperationCoordinator(store: store, checker: checker, accountSessions: browser)
        await coordinator.check(id: account.id)

        #expect(await coordinator.openOAuthURL(for: account.id, text:
            "https://auth.openai.com/oauth/authorize?client_id=x&redirect_uri=https://example.com/cb") != nil)
        #expect(browser.existingAccountSession(for: account) == nil)
        #expect(coordinator.pausedAccountID == account.id)
    }

    @Test func oauthCannotNavigateDuringTwoFARecovery() async throws {
        let store = try store(accountCount: 1)
        let id = store.accounts[0].id
        try store.mutate(id: id) { $0.rotationStage = .oldMethodDisabled }
        let browser = ChatGPTAutomation(sessionManager: WebSessionManager())
        let coordinator = OperationCoordinator(store: store, checker: FakeChecker(), accountSessions: browser)

        #expect(await coordinator.openOAuthURL(for: id, text:
            "https://auth.openai.com/oauth/authorize?client_id=x&redirect_uri=https://example.com/cb") != nil)
        #expect(browser.existingAccountSession(for: store.accounts[0]) == nil)
    }

    @Test func changingEmailDoesNotExposePreviousBrowserSession() async throws {
        let store = try store(accountCount: 1)
        let account = store.accounts[0]
        let checker = FakeChecker()
        checker.activeSession = BrowserSession(dataStore: .nonPersistent())
        let coordinator = OperationCoordinator(store: store, checker: checker)
        await coordinator.check(id: account.id)
        try store.updateCredentials(id: account.id, credential: .init(
            email: "different@example.com", password: "pw", totpSecret: "KRUGS4ZANFZSAYJA"), protectedIDs: [])
        #expect(coordinator.browserSession(for: account.id) == nil)
    }

    @Test func stopCancelsCurrentCheckAndRestoresPreviousStatus() async throws {
        let store = try store(accountCount: 1)
        let account = try #require(store.accounts.first)
        let checker = CancellableChecker()
        let coordinator = OperationCoordinator(store: store, checker: checker)
        let task = Task { await coordinator.check(id: account.id) }

        while !checker.started {
            try await Task.sleep(for: .milliseconds(10))
        }
        coordinator.stop()
        await task.value

        #expect(checker.cancelRequested)
        #expect(!coordinator.isRunning)
        #expect(coordinator.message == "Stopped")
        #expect(store.accounts[0].status == account.status)
        #expect(store.accounts[0].lastError == account.lastError)
    }

    @Test func manualStepPausesAndResumeRetriesBeforeContinuing() async throws {
        let store = try store()
        let checker = FakeChecker()
        checker.outcomes = [
            .manualActionRequired("Complete CAPTCHA"),
            .success(.init(
                signedInEmail: "user0@example.com",
                planLabel: "plus",
                activeUntil: nil,
                willRenew: nil)),
        ]
        let coordinator = OperationCoordinator(store: store, checker: checker)
        store.selectedID = store.accounts[1].id

        await coordinator.checkAll()
        #expect(checker.checked == ["user0@example.com"])
        #expect(coordinator.pausedAccountID == store.accounts[0].id)
        #expect(store.selectedID == store.accounts[0].id)

        await coordinator.resume()
        #expect(checker.checked == ["user0@example.com", "user1@example.com"])
        #expect(checker.continued == ["user0@example.com"])
        #expect(coordinator.pausedAccountID == nil)
        #expect(coordinator.completedCount == 2)
    }

    @Test func rotationPromotesSecretOnlyAfterResumedCleanLogin() async throws {
        let store = try store()
        let checker = FakeChecker()
        let rotator = FakeRotator()
        let coordinator = OperationCoordinator(store: store, checker: checker, rotator: rotator)
        let id = try #require(store.accounts.first?.id)
        let originalSecret = try #require(store.accounts.first?.totpSecret)

        await coordinator.rotate2FA(id: id)

        #expect(store.accounts[0].totpSecret == originalSecret)
        #expect(store.accounts[0].pendingTOTPSecret == "KRUGS4ZANFZSAYJA")
        #expect(store.accounts[0].rotationStage == .awaitingCleanLogin)
        #expect(coordinator.pausedRotationAccountID == id)

        await coordinator.resumeRotation()

        #expect(store.accounts[0].totpSecret == "KRUGS4ZANFZSAYJA")
        #expect(store.accounts[0].pendingTOTPSecret == nil)
        #expect(store.accounts[0].rotationStage == nil)
        #expect(coordinator.pausedRotationAccountID == nil)
    }

    @Test func manuallyConfigured2FAIsStagedForCleanLogin() throws {
        let store = try store(accountCount: 1)
        let id = try #require(store.accounts.first?.id)
        let originalSecret = try #require(store.accounts.first?.totpSecret)
        try store.mutate(id: id) {
            RotationState.markOldMethodDisabled(in: &$0)
        }
        let coordinator = OperationCoordinator(
            store: store,
            checker: FakeChecker(),
            rotator: FakeRotator())

        try coordinator.stageManuallyConfigured2FA(
            id: id,
            secret: " krug-s4za-nfzs-ayja ")

        #expect(store.accounts[0].totpSecret == originalSecret)
        #expect(store.accounts[0].pendingTOTPSecret == "KRUGS4ZANFZSAYJA")
        #expect(store.accounts[0].rotationStage == .awaitingCleanLogin)
        #expect(store.accounts[0].status == .needsRecovery)
    }

    @Test func rotationDoesNotPromotePendingSecretFromAuthenticatedEmailAlone() async throws {
        let store = try store()
        let id = try #require(store.accounts.first?.id)
        let originalSecret = try #require(store.accounts.first?.totpSecret)
        try store.mutate(id: id) {
            $0.pendingTOTPSecret = "MFRGGZDFMZTWQ2LK"
            $0.rotationStage = .awaitingCleanLogin
            $0.status = .needsRecovery
        }
        let coordinator = OperationCoordinator(
            store: store,
            checker: FakeChecker(),
            rotator: UnprovenRotator())

        await coordinator.continueRotation(id: id)

        #expect(store.accounts[0].totpSecret == originalSecret)
        #expect(store.accounts[0].pendingTOTPSecret == "MFRGGZDFMZTWQ2LK")
        #expect(store.accounts[0].rotationStage == .awaitingCleanLogin)
    }

    @Test func rotationStoresSubscriptionFromCleanLoginWithoutSecondCheck() async throws {
        let store = try store(accountCount: 1)
        let id = try #require(store.accounts.first?.id)
        let pendingSecret = "MFRGGZDFMZTWQ2LK"
        let activeUntil = Date(timeIntervalSince1970: 1_790_000_000)
        try store.mutate(id: id) {
            $0.pendingTOTPSecret = pendingSecret
            $0.rotationStage = .awaitingCleanLogin
            $0.status = .needsRecovery
        }
        let snapshot = SubscriptionSnapshot(
            signedInEmail: store.accounts[0].email,
            planLabel: "plus",
            activeUntil: activeUntil,
            willRenew: true)
        let checker = FakeChecker()
        let coordinator = OperationCoordinator(
            store: store,
            checker: checker,
            rotator: SnapshotRotator(snapshot: snapshot))

        await coordinator.continueRotation(id: id)

        let updated = try #require(store.accounts.first)
        #expect(updated.totpSecret == pendingSecret)
        #expect(updated.planLabel == "plus")
        #expect(updated.subscriptionDate == activeUntil)
        #expect(updated.subscriptionDateKind == .renews)
        #expect(updated.lastCheckedAt != nil)
        #expect(updated.status == .ready)
        #expect(checker.checked.isEmpty)
    }

    @Test func stoppingPausedRotationUnblocksOtherAccountsAndPreservesRecovery() async throws {
        let store = try store(accountCount: 2)
        let id = store.accounts[0].id
        let other = store.accounts[1]
        let originalSecret = store.accounts[0].totpSecret
        let checker = FakeChecker()
        let coordinator = OperationCoordinator(store: store, checker: checker, rotator: FakeRotator())
        await coordinator.rotate2FA(id: id)
        #expect(coordinator.pausedRotationAccountIDs.contains(id))

        coordinator.stop()

        #expect(coordinator.pausedRotationAccountIDs.isEmpty)
        #expect(coordinator.rotationStates[id] == .failed("Stopped"))
        #expect(store.accounts[0].totpSecret == originalSecret)
        #expect(store.accounts[0].pendingTOTPSecret == "KRUGS4ZANFZSAYJA")
        #expect(store.accounts[0].rotationStage == .awaitingCleanLogin)
        await coordinator.check(id: other.id)
        #expect(checker.checked == [other.email])
        await coordinator.continueRotation(id: id)
        #expect(store.accounts[0].totpSecret == "KRUGS4ZANFZSAYJA")
        #expect(store.accounts[0].rotationStage == nil)
    }

    @Test func stopCancelsRotationAndDoesNotStartQueuedAccounts() async throws {
        let store = try store(accountCount: 2)
        let rotator = CancellableRotator()
        let coordinator = OperationCoordinator(
            store: store,
            checker: FakeChecker(),
            rotator: rotator)
        let task = Task {
            await coordinator.rotate2FA(
                accountIDs: store.accounts.map(\.id),
                concurrency: 1)
        }

        while rotator.started == 0 {
            try await Task.sleep(for: .milliseconds(5))
        }
        coordinator.stop()
        await task.value

        #expect(rotator.cancelRequested)
        #expect(rotator.started == 1)
        #expect(!coordinator.isRunning)
        #expect(coordinator.message == "Stopped")
    }

    @Test func stopDuringResumedRotationKeepsPendingSecretWithoutManualPause() async throws {
        let store = try store(accountCount: 1)
        let id = try #require(store.accounts.first?.id)
        let originalSecret = store.accounts[0].totpSecret
        try store.mutate(id: id) {
            $0.pendingTOTPSecret = "MFRGGZDFMZTWQ2LK"
            $0.rotationStage = .awaitingCleanLogin
            $0.status = .needsRecovery
        }
        let rotator = CancellableRotator()
        rotator.pauseBeforeWaiting = true
        rotator.returnManualAfterCancel = true
        let coordinator = OperationCoordinator(store: store, checker: FakeChecker(), rotator: rotator)
        await coordinator.continueRotation(id: id)
        #expect(coordinator.pausedRotationAccountID == id)

        let task = Task { await coordinator.resumeRotation(id: id) }
        while rotator.started < 2 {
            try await Task.sleep(for: .milliseconds(5))
        }
        coordinator.stop()
        await task.value

        #expect(!coordinator.isRunning)
        #expect(coordinator.pausedRotationAccountIDs.isEmpty)
        #expect(coordinator.message == "Stopped")
        #expect(coordinator.rotationStates[id] == .failed("Stopped"))
        #expect(store.accounts[0].totpSecret == originalSecret)
        #expect(store.accounts[0].pendingTOTPSecret == "MFRGGZDFMZTWQ2LK")
        #expect(store.accounts[0].rotationStage == .awaitingCleanLogin)
    }

    @Test func persistedCleanLoginRecoveryCanContinueAfterCoordinatorRestart() async throws {
        let store = try store()
        let id = try #require(store.accounts.first?.id)
        let pendingSecret = "MFRGGZDFMZTWQ2LK"
        try store.mutate(id: id) {
            $0.pendingTOTPSecret = pendingSecret
            $0.rotationStage = .awaitingCleanLogin
            $0.status = .needsRecovery
        }
        let rotator = FakeRotator()
        rotator.calls = 1
        let coordinator = OperationCoordinator(
            store: store,
            checker: FakeChecker(),
            rotator: rotator)

        await coordinator.continueRotation(id: id)

        #expect(rotator.calls == 2)
        #expect(store.accounts[0].totpSecret == pendingSecret)
        #expect(store.accounts[0].pendingTOTPSecret == nil)
        #expect(store.accounts[0].rotationStage == nil)
        #expect(store.accounts[0].status == .ready)
    }

    @Test func persistedRemovalWithNoBrowserRequestsNewLoginWithoutStartingRotation() async throws {
        let store = try store(accountCount: 1)
        let id = store.accounts[0].id
        try store.mutate(id: id) { RotationState.markRemovalStarted(in: &$0) }
        let rotator = FakeRotator()
        let recovery = FakeBrowserRecovery()
        let coordinator = OperationCoordinator(
            store: store, checker: FakeChecker(), rotator: rotator, browserRecovery: recovery)

        await coordinator.continueRotation(id: id)

        #expect(coordinator.message?.contains("Новый вход") == true)
        #expect(rotator.calls == 0)
        #expect(recovery.freshCalls.isEmpty)
        #expect(store.accounts[0].rotationStage == .removingOldMethod)
    }

    @Test func loadedUnprovenRotationBrowserRequestsFreshLoginWithoutStartingRotation() async throws {
        let store = try store(accountCount: 1)
        let id = store.accounts[0].id
        try store.mutate(id: id) { RotationState.markRemovalStarted(in: &$0) }
        let account = store.accounts[0]
        let rotator = FakeRotator()
        let recovery = ChatGPTAutomation(sessionManager: WebSessionManager())
        let coordinator = OperationCoordinator(
            store: store, checker: FakeChecker(), rotator: rotator, browserRecovery: recovery)

        recovery.prepareBrowserSession(for: account)
        let session = try #require(recovery.recoverySession(for: account, context: .rotation(stage: .removingOldMethod)))
        let url = URL(string: "https://chatgpt.com/#settings/Security")!
        session.webView.navigationDelegate = nil
        session.webView.loadHTMLString("<html><body>Security</body></html>", baseURL: url)
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while (session.webView.isLoading || session.webView.url != url), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        try #require(!session.webView.isLoading && session.webView.url == url)
        #expect(session.canReloadTrustedPage && !session.needsInitialPageLoad)
        #expect(recovery.rotationRecoverySessionState(for: account) == .unavailable)

        #expect(coordinator.rotationNeedsNewLogin(for: id))
        await coordinator.continueRotation(id: id)

        #expect(coordinator.message == OperationCoordinator.missingRotationSessionMessage)
        #expect(rotator.calls == 0)
        #expect(!recovery.hasCandidateSession(for: id))
        #expect(store.accounts[0] == account)
    }

    @Test func groupRotationStaysSerialEvenWithLegacyParallelRequest() async throws {
        let store = try store(accountCount: 5)
        let group = try store.createGroup(name: "Пачка", tag: nil)
        try store.moveAccounts(
            ids: Set(store.accounts.map(\.id)),
            to: group.id,
            protectedIDs: [])
        let rotator = ConcurrencyTrackingRotator()
        let coordinator = OperationCoordinator(
            store: store,
            checker: FakeChecker(),
            rotator: rotator)

        await coordinator.rotate2FA(groupID: group.id, concurrency: 2)

        #expect(rotator.maximumActive == 1)
        #expect(rotator.started.count == 5)
        #expect(coordinator.rotationTotalCount == 5)
    }

    @Test func freshRotationDoesNotEnqueueAStagedAccount() async throws {
        let store = try store(accountCount: 1)
        let id = try #require(store.accounts.first?.id)
        try store.mutate(id: id) {
            RotationState.markOldMethodDisabled(in: &$0)
        }
        let rotator = ConcurrencyTrackingRotator()
        let coordinator = OperationCoordinator(
            store: store,
            checker: FakeChecker(),
            rotator: rotator)

        await coordinator.rotate2FA(id: id)

        #expect(rotator.started.isEmpty)
        #expect(coordinator.rotationTotalCount == 0)
    }

    @Test func freshGroupRotationSkipsStagedAccountsAndContinuesOthers() async throws {
        let store = try store(accountCount: 2)
        let group = try store.createGroup(name: "Пачка", tag: nil)
        try store.moveAccounts(
            ids: Set(store.accounts.map(\.id)),
            to: group.id,
            protectedIDs: [])
        let stagedID = store.accounts[0].id
        try store.mutate(id: stagedID) {
            RotationState.markOldMethodDisabled(in: &$0)
        }
        let rotator = ConcurrencyTrackingRotator()
        let coordinator = OperationCoordinator(
            store: store,
            checker: FakeChecker(),
            rotator: rotator)

        await coordinator.rotate2FA(groupID: group.id, concurrency: 2)

        #expect(rotator.started == [store.accounts[1].email])
        #expect(coordinator.rotationTotalCount == 1)
        #expect(store.accounts[0].rotationStage == .oldMethodDisabled)
    }

    @Test func manualAccountPausesWholeGroupAndResumeKeepsItsOrder() async throws {
        let store = try store(accountCount: 3)
        let group = try store.createGroup(name: "Пачка", tag: nil)
        try store.moveAccounts(
            ids: Set(store.accounts.map(\.id)),
            to: group.id,
            protectedIDs: [])
        let rotator = ConcurrencyTrackingRotator()
        rotator.manualEmails = [store.accounts[0].email]
        let coordinator = OperationCoordinator(
            store: store,
            checker: FakeChecker(),
            rotator: rotator)

        await coordinator.rotate2FA(groupID: group.id, concurrency: 1)

        #expect(rotator.started == [store.accounts[0].email])
        #expect(rotator.preparedIDs == [store.accounts[0].id])
        #expect(coordinator.rotationStates[store.accounts[1].id] == .queued)
        #expect(coordinator.pausedRotationAccountIDs.contains(store.accounts[0].id))
        #expect(throws: AccountStoreError.accountBusy) {
            try store.deleteAccount(id: store.accounts[1].id, protectedIDs: coordinator.protectedAccountIDs)
        }
        #expect(throws: AccountStoreError.accountBusy) {
            try store.deleteAccount(id: store.accounts[0].id, protectedIDs: coordinator.protectedAccountIDs)
        }
        #expect(throws: AccountStoreError.accountBusy) {
            try store.updateCredentials(id: store.accounts[1].id,
                credential: .init(email: "replacement@example.com", password: "fixture", totpSecret: "JBSWY3DPEHPK3PXP"),
                protectedIDs: coordinator.protectedAccountIDs)
        }
        rotator.manualEmails.removeAll()
        await coordinator.resumeRotation(id: store.accounts[0].id)
        #expect(rotator.started == [store.accounts[0].email] + store.accounts.map(\.email))
        #expect(coordinator.rotationStates.values.allSatisfy { $0 == .complete })
    }

    @Test func groupRotationLeavesLaterAccountsQueuedWhenOneNeedsManualAction() async throws {
        let store = try store(accountCount: 3)
        let group = try store.createGroup(name: "Пачка", tag: nil)
        try store.moveAccounts(
            ids: Set(store.accounts.map(\.id)),
            to: group.id,
            protectedIDs: [])
        let rotator = ConcurrencyTrackingRotator()
        rotator.manualEmails = [store.accounts[1].email]
        let coordinator = OperationCoordinator(
            store: store,
            checker: FakeChecker(),
            rotator: rotator)

        await coordinator.rotate2FA(groupID: group.id, concurrency: 3)

        #expect(coordinator.rotationStates.count == 3)
        #expect(coordinator.rotationStates[store.accounts[0].id] == .complete)
        #expect(coordinator.pausedRotationAccountIDs == [store.accounts[1].id])
        #expect(coordinator.rotationStates[store.accounts[2].id] == .queued)
        #expect(coordinator.rotationCompletedCount == 2)
    }

    @Test func failureAfterDisableKeepsCheckpointAndDoesNotPrepareNextAccount() async throws {
        let store = try store(accountCount: 3)
        let first = store.accounts[0]
        let rotator = ConcurrencyTrackingRotator()
        rotator.failureEmails = [first.email]
        let coordinator = OperationCoordinator(store: store, checker: FakeChecker(), rotator: rotator)
        await coordinator.rotate2FA(accountIDs: store.accounts.map(\.id), concurrency: 3)
        #expect(rotator.preparedIDs == [first.id])
        #expect(rotator.started == [first.email])
        #expect(store.selectedID == first.id)
        #expect(store.accounts[0].rotationStage == .oldMethodDisabled)
        #expect(store.accounts[0].totpSecret == first.totpSecret)
        #expect(coordinator.pausedRotationAccountIDs == [first.id])
        #expect(coordinator.rotationStates[store.accounts[1].id] == .queued)
        rotator.failureEmails.removeAll()
        await coordinator.continueRotation(id: first.id)
        #expect(rotator.started == [first.email] + store.accounts.map(\.email))
        #expect(coordinator.rotationStates.values.allSatisfy { $0 == .complete })
    }

    @Test func freshCheckLoginAutomaticallyResumesThePausedCheck() async throws {
        let store = try store(accountCount: 1)
        let account = try #require(store.accounts.first)
        let checker = FakeChecker()
        checker.outcomes = [
            .manualActionRequired("Complete CAPTCHA"),
            .success(.init(
                signedInEmail: account.email,
                planLabel: "plus",
                activeUntil: nil,
                willRenew: nil)),
        ]
        let recovery = FakeBrowserRecovery()
        recovery.nextResult = .readyToContinue("Новая сессия готова")
        let coordinator = OperationCoordinator(
            store: store,
            checker: checker,
            browserRecovery: recovery)

        await coordinator.check(id: account.id)
        await coordinator.startFreshBrowserLogin(for: account.id)

        #expect(checker.continued == [account.email])
        #expect(recovery.freshCalls == [account.id])
        #expect(store.accounts[0].status == .ready)
    }

    @Test func manualRecoveryResultDoesNotResumeRotation() async throws {
        let store = try store(accountCount: 1)
        let account = try #require(store.accounts.first)
        let rotator = FakeRotator()
        let recovery = FakeBrowserRecovery()
        let coordinator = OperationCoordinator(
            store: store,
            checker: FakeChecker(),
            rotator: rotator,
            browserRecovery: recovery)

        await coordinator.rotate2FA(id: account.id)
        #expect(rotator.calls == 1)
        recovery.nextResult = .manualAction("Введите код вручную")
        await coordinator.startFreshBrowserLogin(for: account.id)

        #expect(rotator.calls == 1)
        #expect(recovery.freshCalls == [account.id])
    }

    @Test func readyCleanLoginResetResumesExistingRotation() async throws {
        let store = try store(accountCount: 1)
        let account = try #require(store.accounts.first)
        let rotator = FakeRotator()
        let recovery = FakeBrowserRecovery()
        let coordinator = OperationCoordinator(
            store: store,
            checker: FakeChecker(),
            rotator: rotator,
            browserRecovery: recovery)

        await coordinator.rotate2FA(id: account.id)
        #expect(store.accounts[0].rotationStage == .awaitingCleanLogin)
        recovery.nextResult = .readyToContinue("Новый проверочный вход готов")
        await coordinator.startFreshBrowserLogin(for: account.id)

        #expect(rotator.calls == 2)
        #expect(store.accounts[0].rotationStage == nil)
        #expect(store.accounts[0].status == .ready)
    }

    @Test func reloadAndReopenDoNotStartAnotherWorker() async throws {
        let store = try store(accountCount: 1)
        let account = try #require(store.accounts.first)
        let rotator = FakeRotator()
        let recovery = FakeBrowserRecovery()
        recovery.nextResult = .readyToContinue("Страница готова")
        let coordinator = OperationCoordinator(
            store: store,
            checker: FakeChecker(),
            rotator: rotator,
            browserRecovery: recovery)

        await coordinator.rotate2FA(id: account.id)
        await coordinator.reloadBrowser(for: account.id)
        await coordinator.reopenBrowserSection(for: account.id)

        #expect(rotator.calls == 1)
        #expect(recovery.reloadCalls == [account.id])
        #expect(recovery.reopenCalls == [account.id])
    }

    @Test func recoveryNavigationBlocksConcurrentActionsAndProtectsTheAccount() async throws {
        let store = try store(accountCount: 1)
        let id = store.accounts[0].id
        let rotator = FakeRotator()
        let recovery = FakeBrowserRecovery()
        let coordinator = OperationCoordinator(store: store, checker: FakeChecker(),
            rotator: rotator, browserRecovery: recovery)
        await coordinator.rotate2FA(id: id)
        recovery.holdReload = true
        let reload = Task { await coordinator.reloadBrowser(for: id) }
        while recovery.suspendedReload == nil { await Task.yield() }
        #expect(coordinator.isRunning)
        #expect(coordinator.protectedAccountIDs.contains(id))
        #expect(coordinator.recoveryAvailability(for: id) == nil)
        await coordinator.startFreshBrowserLogin(for: id)
        await coordinator.reopenBrowserSection(for: id)
        await coordinator.continueRotation(id: id)
        coordinator.returnToOriginalBrowserSession(for: id)
        #expect(recovery.freshCalls.isEmpty)
        #expect(recovery.reopenCalls.isEmpty)
        #expect(recovery.returnCalls.isEmpty)
        #expect(rotator.calls == 1)
        recovery.suspendedReload?.resume()
        await reload.value
        #expect(!coordinator.isRunning)
    }

    @Test func failedCheckCanStartFreshAndContinueTheReplacementSession() async throws {
        let store = try store(accountCount: 1)
        let id = store.accounts[0].id
        let checker = FakeChecker()
        checker.outcomes = [.failure("Authentication failed")]
        let recovery = FakeBrowserRecovery()
        recovery.nextResult = .readyToContinue("Готово")
        let coordinator = OperationCoordinator(store: store, checker: checker, browserRecovery: recovery)
        await coordinator.check(id: id)
        #expect(coordinator.recoveryAvailability(for: id) != nil)
        await coordinator.startFreshBrowserLogin(for: id)
        #expect(checker.continued == [store.accounts[0].email])
        #expect(checker.checked.count == 1)
        #expect(store.accounts[0].status == .ready)
    }

}
