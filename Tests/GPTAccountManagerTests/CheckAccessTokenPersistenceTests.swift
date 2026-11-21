import Foundation
import Testing
@testable import GPTAccountManager

@MainActor
private final class CheckTokenFixtureChecker: SubscriptionChecking {
    var activeSession: BrowserSession? { nil }
    var outcomes: [SubscriptionCheckOutcome] = []
    var token: String? = "fixture-checked-access-token.not-a-live-secret"
    var tokenError: Error?
    var holdToken = false
    var tokenContinuation: CheckedContinuation<Void, Never>?
    private(set) var checkedIDs: [UUID] = []
    private(set) var continuedIDs: [UUID] = []
    private(set) var tokenAccountIDs: [UUID] = []

    func check(account: AccountRecord) async -> SubscriptionCheckOutcome {
        checkedIDs.append(account.id)
        return outcome(for: account)
    }

    func continueCheck(account: AccountRecord) async -> SubscriptionCheckOutcome {
        continuedIDs.append(account.id)
        return outcome(for: account)
    }

    private func outcome(for account: AccountRecord) -> SubscriptionCheckOutcome {
        if !outcomes.isEmpty { return outcomes.removeFirst() }
        return .success(.init(signedInEmail: account.email, planLabel: "plus",
                              activeUntil: Date(timeIntervalSince1970: 1_800_000_000), willRenew: true))
    }

    func accessTokenAfterCheck(for account: AccountRecord) async throws -> String? {
        tokenAccountIDs.append(account.id)
        if holdToken { await withCheckedContinuation { tokenContinuation = $0 } }
        if let tokenError { throw tokenError }
        return token
    }

    func releaseToken() {
        tokenContinuation?.resume()
        tokenContinuation = nil
    }
}

@MainActor
@Suite struct CheckAccessTokenPersistenceTests {
    private let cachedToken = "fixture-old-cached-token.not-a-live-secret"

    private func store(count: Int = 1) throws -> AccountStore {
        let store = AccountStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("accounts.json"))
        try store.merge((0..<count).map {
            .init(email: "fixture\($0)@example.com", password: "fixture-password",
                  totpSecret: "JBSWY3DPEHPK3PXP")
        })
        return store
    }

    private func exportURL(_ store: AccountStore) -> URL {
        store.fileURL.deletingLastPathComponent().appendingPathComponent("new-novoreg-access-tokens.txt")
    }

    private func reloaded(_ store: AccountStore) throws -> [AccountRecord] {
        let reloaded = AccountStore(fileURL: store.fileURL)
        try reloaded.load()
        return reloaded.accounts
    }

    private func persistedMatches(_ store: AccountStore, _ expected: [AccountRecord]) throws -> Bool {
        // Compare at the store's ISO8601 precision, before load repairs interrupted operations.
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let saved = try decoder.decode(PersistedAccountData.self, from: Data(contentsOf: store.fileURL)).accounts
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .sortedKeys
        return try encoder.encode(saved) == encoder.encode(expected)
    }

    private func hasTokenWarning(_ coordinator: OperationCoordinator, account: AccountRecord) -> Bool {
        let text = [coordinator.message, account.lastError].compactMap { $0 }.joined(separator: " ").lowercased()
        return text.contains("token") || text.contains("токен")
    }

    @Test(arguments: ["single", "group", "all", "resume"])
    func successfulChecksPersistTokensAndRefreshRegistrationExport(mode: String) async throws {
        let store = try store(count: mode == "single" ? 1 : 2)
        defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
        let group = try store.createGroup(name: "NEW-NOVOREG", tag: nil)
        let ids = store.accounts.map(\.id)
        try store.moveAccounts(ids: Set(ids), to: group.id, protectedIDs: [])
        let checker = CheckTokenFixtureChecker()
        let coordinator = OperationCoordinator(store: store, checker: checker)
        if mode == "resume" { checker.outcomes = [.manualActionRequired("Complete fixture challenge")] }

        switch mode {
        case "single": await coordinator.check(id: ids[0])
        case "group": await coordinator.checkGroup(groupID: group.id)
        default: await coordinator.checkAll()
        }
        if mode == "resume" {
            #expect(checker.tokenAccountIDs.isEmpty)
            #expect(coordinator.pausedAccountID == ids[0])
            await coordinator.resume()
            #expect(checker.continuedIDs == [ids[0]])
        }

        let token = try #require(checker.token)
        #expect(checker.tokenAccountIDs == ids)
        #expect(coordinator.completedCount == ids.count && !coordinator.isRunning)
        #expect(store.accounts.allSatisfy {
            $0.accessToken == token && $0.status == .ready && $0.planLabel == "plus"
                && $0.lastCheckedAt != nil && $0.subscriptionDateKind == .renews
        })
        #expect(try persistedMatches(store, store.accounts))
        let expected = store.accounts.map { "\($0.email)|\(token)\n" }.joined()
        #expect(try String(contentsOf: exportURL(store), encoding: .utf8) == expected)
    }

    @Test func otherGroupsCacheTokensWithoutEnteringRegistrationExport() async throws {
        let store = try store(count: 3)
        defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
        let registration = try store.createGroup(name: "new-novoreg", tag: nil)
        let other = try store.createGroup(name: "Existing accounts", tag: nil)
        try store.moveAccounts(ids: [store.accounts[0].id], to: registration.id, protectedIDs: [])
        try store.moveAccounts(ids: [store.accounts[1].id], to: other.id, protectedIDs: [])
        let checker = CheckTokenFixtureChecker()
        let coordinator = OperationCoordinator(store: store, checker: checker)

        await coordinator.checkAll()

        let token = try #require(checker.token)
        #expect(try reloaded(store).allSatisfy { $0.accessToken == token && $0.status == .ready })
        #expect(try String(contentsOf: exportURL(store), encoding: .utf8) == "\(store.accounts[0].email)|\(token)\n")
    }

    @Test func wrongSignedInIdentityNeverReadsOrSavesToken() async throws {
        let store = try store()
        defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
        let id = store.accounts[0].id
        try store.saveAccessToken(id: id, accessToken: cachedToken)
        let checker = CheckTokenFixtureChecker()
        checker.outcomes = [.success(.init(signedInEmail: "other@example.com", planLabel: "plus", activeUntil: nil, willRenew: nil))]
        let coordinator = OperationCoordinator(store: store, checker: checker)

        await coordinator.check(id: id)

        #expect(checker.tokenAccountIDs.isEmpty)
        #expect(store.accounts[0].status == .failed)
        #expect(store.accounts[0].accessToken == cachedToken)
        #expect(store.accounts[0].planLabel == nil)
        #expect(try persistedMatches(store, store.accounts))
        #expect(!FileManager.default.fileExists(atPath: exportURL(store).path))
    }

    @Test(arguments: ["missing", "error", "invalid"])
    func unavailableTokenPreservesReadyResultAndCachedTokenWithSafeWarning(reason: String) async throws {
        let store = try store()
        defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
        let id = store.accounts[0].id
        try store.saveAccessToken(id: id, accessToken: cachedToken)
        let checker = CheckTokenFixtureChecker()
        if reason == "missing" { checker.token = nil }
        if reason == "invalid" { checker.token = "fixture|invalid-token" }
        if reason == "error" {
            checker.tokenError = NSError(domain: "Fixture", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "fixture-error-secret \(cachedToken) fixture-password JBSWY3DPEHPK3PXP"
            ])
        }
        let coordinator = OperationCoordinator(store: store, checker: checker)

        await coordinator.check(id: id)

        let account = store.accounts[0]
        #expect(account.status == .ready && account.planLabel == "plus" && account.lastCheckedAt != nil)
        #expect(account.accessToken == cachedToken)
        #expect(try persistedMatches(store, store.accounts))
        #expect(hasTokenWarning(coordinator, account: account))
        let text = [coordinator.message, account.lastError].compactMap { $0 }.joined()
        for secret in [cachedToken, "fixture-error-secret", "fixture-password", "JBSWY3DPEHPK3PXP", "fixture|invalid-token"] {
            #expect(!text.contains(secret))
        }
    }

    @Test func exportFailurePreservesSavedTokenAndReadyResultWithWarning() async throws {
        let store = try store()
        defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
        let id = store.accounts[0].id
        let group = try store.createGroup(name: "new-novoreg", tag: nil)
        try store.moveAccounts(ids: [id], to: group.id, protectedIDs: [])
        try FileManager.default.createDirectory(at: exportURL(store), withIntermediateDirectories: false)
        let checker = CheckTokenFixtureChecker()
        let coordinator = OperationCoordinator(store: store, checker: checker)

        await coordinator.check(id: id)

        #expect(store.accounts[0].status == .ready && store.accounts[0].accessToken == checker.token)
        #expect(store.accounts[0].planLabel == "plus" && store.accounts[0].lastCheckedAt != nil)
        #expect(try persistedMatches(store, store.accounts))
        #expect(hasTokenWarning(coordinator, account: store.accounts[0]))
        #expect(!(coordinator.message ?? "").contains(try #require(checker.token)))
    }

    @Test(arguments: ["stop", "task", "stopAfterEdit", "taskAfterEdit"])
    func cancellationDuringTokenReadDoesNotPersistTokenOrCheckResult(method: String) async throws {
        let store = try store()
        defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
        let original = store.accounts[0]
        let checker = CheckTokenFixtureChecker()
        checker.holdToken = true
        let coordinator = OperationCoordinator(store: store, checker: checker)
        let task = Task { await coordinator.check(id: original.id) }
        for _ in 0..<200 where checker.tokenContinuation == nil { try await Task.sleep(for: .milliseconds(1)) }
        #expect(checker.tokenContinuation != nil)

        if method.hasSuffix("AfterEdit") {
            try store.mutate(id: original.id) {
                $0.status = .needsRecovery
                $0.lastError = "Fixture newer recovery state"
                $0.browserStoreID = UUID()
            }
        }
        var expected = store.accounts[0]
        if !method.hasSuffix("AfterEdit") { expected = original }
        if method.hasPrefix("stop") { coordinator.stop() } else { task.cancel() }
        checker.releaseToken()
        await task.value

        #expect(store.accounts[0] == expected)
        #expect(try persistedMatches(store, [expected]))
        #expect(!FileManager.default.fileExists(atPath: exportURL(store).path))
        #expect(!coordinator.isRunning)
    }

    @Test(arguments: ["email", "password", "totp", "browserStore", "proxy", "pendingPassword", "pendingAccess", "pendingEmail", "pendingRegistration", "pendingTOTP", "rotation"])
    func accountChangedDuringTokenReadRejectsStaleToken(change: String) async throws {
        let store = try store()
        defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
        let id = store.accounts[0].id
        let checker = CheckTokenFixtureChecker()
        checker.holdToken = true
        let coordinator = OperationCoordinator(store: store, checker: checker)
        let task = Task { await coordinator.check(id: id) }
        for _ in 0..<200 where checker.tokenContinuation == nil { try await Task.sleep(for: .milliseconds(1)) }
        #expect(checker.tokenContinuation != nil)
        try store.mutate(id: id) {
            switch change {
            case "email": $0.email = "replacement@example.com"
            case "password": $0.password = "replacement-password"
            case "totp": $0.totpSecret = "KRUGS4ZANFZSAYJA"
            case "browserStore": $0.browserStoreID = UUID()
            case "proxy": $0.proxy = .init(scheme: .http, host: "127.0.0.1", port: 8080)
            case "pendingPassword": $0.pendingPassword = "replacement-password"
            case "pendingAccess": $0.pendingAccessChange = .password
            case "pendingEmail": $0.pendingEmailChange = .init(aliasID: UUID(), originalEmail: $0.email, newEmail: "replacement@icloud.com")
            case "pendingRegistration": $0.pendingRegistration = .init(fullName: "Fixture Person", age: 28)
            case "pendingTOTP": $0.pendingTOTPSecret = "KRUGS4ZANFZSAYJA"
            default: $0.rotationStage = .awaitingCleanLogin
            }
        }
        let changed = store.accounts[0]
        checker.releaseToken()
        await task.value

        #expect(store.accounts[0] == changed)
        #expect(store.accounts[0].accessToken == nil && store.accounts[0].lastCheckedAt == nil)
        #expect(try persistedMatches(store, [changed]))
        #expect(!FileManager.default.fileExists(atPath: exportURL(store).path))
    }
}
