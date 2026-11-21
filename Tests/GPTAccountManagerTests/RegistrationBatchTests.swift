import AppKit
import Foundation
import Testing
import WebKit
@testable import GPTAccountManager

private actor RegistrationBatchProxyChecks {
    private var count = 0

    func check() -> ProxyCheckResult {
        count += 1
        return .init(status: count == 2 ? .unavailable : .available,
                     checkedAt: Date(), message: "fixture")
    }
}

@MainActor
private final class RegistrationBatchCompletionGate {
    var isOpen = false
}

@MainActor
@Suite(.serialized)
struct RegistrationBatchTests {
    private let configuredPassword = "registration-fixture-password"

    private func store() -> AccountStore {
        AccountStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathComponent("accounts.json"))
    }

    private func coordinator(
        store: AccountStore, proxies: ProxyStore? = nil,
        passwordConfigured: Bool = true,
        advance: @escaping @MainActor (UUID) async throws -> Void
    ) -> RegistrationCoordinator {
        _ = NSApplication.shared
        let browser = ChatGPTAutomation(sessionManager: WebSessionManager(
            accountSessionFactory: { _ in BrowserSession(dataStore: .nonPersistent()) }))
        return RegistrationCoordinator(store: store, browser: browser, mailbox: MailRuMailbox(),
                                       proxyStore: proxies, configuredPassword: passwordConfigured ? configuredPassword : nil,
                                       advanceRegistration: advance)
    }

    @Test func missingPasswordLeavesNewBatchUntouchedAndAllowsResumingSavedDraft() async throws {
        let store = store()
        defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
        var advanced: [UUID] = []
        let coordinator = coordinator(store: store, passwordConfigured: false) { id in
            advanced.append(id)
            try complete(id, in: store)
        }
        #expect(throws: RegistrationBatchError.passwordNotConfigured) {
            try coordinator.start(email: "new@example.com")
        }
        #expect(store.accounts.isEmpty)
        #expect(!coordinator.hasPendingBatch)
        #expect(!FileManager.default.fileExists(atPath: RegistrationBatchState.fileURL(for: store.fileURL).path))

        let draft = try store.beginRegistration(email: "existing@example.com", fullName: "Fixture Person", age: 25,
                                                password: configuredPassword)
        coordinator.resume(id: draft.id)
        try await waitUntil { !coordinator.isRunning }
        #expect(advanced == [draft.id])
        #expect(store.accounts.first?.password == configuredPassword)
        #expect(store.accounts.first?.status == .ready)
    }

    private func complete(_ id: UUID, in store: AccountStore) throws {
        let account = try #require(store.accounts.first(where: { $0.id == id }))
        var pending = try #require(account.pendingRegistration)
        let secret = "JBSWY3DPEHPK3PXP"
        pending.phase = .verifyingLogin
        pending.passwordWasSubmitted = true
        pending.pendingSecret = secret
        try store.checkpointRegistration(id: id, registration: pending)
        try store.completeRegistration(
            id: id, verifiedEmail: account.email, secret: secret,
            proof: .init(passwordSubmitted: true, pendingOTPSubmitted: true,
                         authenticatedImmediatelyAfterPendingOTP: true),
            snapshot: .init(signedInEmail: account.email, planLabel: "free", activeUntil: nil, willRenew: nil))
    }

    private func waitUntil(_ predicate: () -> Bool) async throws {
        for _ in 0..<200 where !predicate() { try await Task.sleep(for: .milliseconds(10)) }
        try #require(predicate())
    }

    @Test func planningUsesSelectedEmailThenAvailablePoolOrderAndRejectsInvalidCountsAtomically() throws {
        let store = store()
        defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
        try store.importEmailAliases("first@icloud.com second@icloud.com third@icloud.com")
        let coordinator = coordinator(store: store) { _ in }
        #expect(try coordinator.registrationEmails(startingWith: " SECOND@ICLOUD.COM ", count: 3) == [
            "second@icloud.com", "first@icloud.com", "third@icloud.com",
        ])
        #expect(try coordinator.registrationEmails(startingWith: "outside@example.com", count: 2) == [
            "outside@example.com", "first@icloud.com",
        ])
        for count in [-1, 0] {
            #expect(throws: RegistrationBatchError.invalidCount) {
                try coordinator.start(email: "second@icloud.com", count: count)
            }
        }
        #expect(throws: RegistrationBatchError.insufficientEmails(available: 3)) {
            try coordinator.start(email: "second@icloud.com", count: 4)
        }
        #expect(store.accounts.isEmpty && store.groups.isEmpty)
        #expect(store.emailAliases.allSatisfy { $0.status == .available })
        #expect(!coordinator.isRunning && !coordinator.hasPendingBatch && coordinator.totalCount == 0)
    }

    @Test func successfulBatchRunsStrictlySeriallyAndCreatesOnlyCurrentDraft() async throws {
        let store = store()
        try store.importEmailAliases("first@icloud.com second@icloud.com third@icloud.com")
        var started: [String] = []
        var active = 0
        var maximumActive = 0
        let coordinator = coordinator(store: store) { id in
            active += 1
            maximumActive = max(maximumActive, active)
            defer { active -= 1 }
            let account = try #require(store.accounts.first(where: { $0.id == id }))
            started.append(account.email)
            #expect(store.accounts.count == started.count)
            #expect(store.accounts.filter { $0.pendingRegistration != nil }.count == 1)
            #expect(store.emailAliases.filter { $0.status == .used }.count == started.count)
            try await Task.sleep(for: .milliseconds(10))
            try complete(id, in: store)
        }
        defer { coordinator.stop(); try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
        try coordinator.start(email: "second@icloud.com", count: 3)
        try await waitUntil { !coordinator.isRunning }
        #expect(started == ["second@icloud.com", "first@icloud.com", "third@icloud.com"])
        #expect(maximumActive == 1 && coordinator.completedCount == 3 && coordinator.totalCount == 3)
        #expect(!coordinator.hasPendingBatch)
        #expect(store.accounts.allSatisfy { $0.status == .ready && $0.pendingRegistration == nil })
        let allUseConfiguredPassword = store.accounts.allSatisfy { $0.password == configuredPassword }
        #expect(allUseConfiguredPassword)
        #expect(Set(store.accounts.map(\.browserStoreID)).count == 3)
        #expect(store.groups.map(\.name) == ["new-novoreg"])
    }

    @Test func manualReturnPausesWholeBatchUntilCurrentDraftCompletes() async throws {
        let store = store()
        try store.importEmailAliases("first@icloud.com second@icloud.com")
        var started: [UUID] = []
        let completion = RegistrationBatchCompletionGate()
        let coordinator = coordinator(store: store) { id in
            started.append(id)
            if completion.isOpen { try complete(id, in: store) }
        }
        defer { coordinator.stop(); try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
        try coordinator.start(email: "first@icloud.com", count: 2)
        try await waitUntil { !coordinator.isRunning }
        let original = try #require(store.accounts.first)
        #expect(started == [original.id] && store.accounts.count == 1)
        #expect(original.status == .needsRecovery && original.pendingRegistration != nil)
        #expect(store.groups.isEmpty && store.emailAliases[1].status == .available)
        #expect(coordinator.completedCount == 0 && coordinator.hasPendingBatch)
        completion.isOpen = true
        coordinator.resume(id: original.id)
        try await waitUntil { !coordinator.isRunning }
        #expect(started == [original.id, original.id, store.accounts[1].id])
        #expect(store.accounts[0].browserStoreID == original.browserStoreID)
        #expect(coordinator.completedCount == 2 && !coordinator.hasPendingBatch)
    }

    @Test func stopAndResumePreserveCurrentDraftAndUnstartedTail() async throws {
        let store = store()
        try store.importEmailAliases("first@icloud.com second@icloud.com")
        var started: [UUID] = []
        let coordinator = coordinator(store: store) { id in
            started.append(id)
            if started.count == 1 { try await Task.sleep(for: .seconds(10)) }
            try complete(id, in: store)
        }
        defer { coordinator.stop(); try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
        try coordinator.start(email: "first@icloud.com", count: 2)
        try await waitUntil { !started.isEmpty }
        let original = try #require(store.accounts.first)
        try coordinator.start(email: "ignored@example.com", count: 1)
        coordinator.newRegistration()
        #expect(coordinator.totalCount == 2 && coordinator.accountID == original.id)
        coordinator.stop()
        try await waitUntil { !coordinator.isRunning }
        #expect(store.accounts == [original] && started == [original.id])
        #expect(store.emailAliases[1].status == .available && coordinator.hasPendingBatch)
        coordinator.resume(id: original.id)
        try await waitUntil { !coordinator.isRunning }
        #expect(started == [original.id, original.id, store.accounts[1].id])
        #expect(store.accounts[0].browserStoreID == original.browserStoreID)
        #expect(coordinator.completedCount == 2 && !coordinator.hasPendingBatch)
    }

    @Test func nextProxyFailureKeepsNextAliasAvailableAndBatchCanResume() async throws {
        let store = store()
        try store.importEmailAliases("first@icloud.com second@icloud.com")
        let checks = RegistrationBatchProxyChecks()
        let proxies = ProxyStore(fileURL: store.fileURL.deletingLastPathComponent().appendingPathComponent("proxies.json"),
                                 checker: { _ in await checks.check() })
        try proxies.add(text: "socks5://127.0.0.1:18081")
        try proxies.setEnabled(true)
        var started: [String] = []
        let coordinator = coordinator(store: store, proxies: proxies) { id in
            started.append(try #require(store.accounts.first(where: { $0.id == id })).email)
            try complete(id, in: store)
        }
        defer { coordinator.stop(); try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
        try coordinator.start(email: "first@icloud.com", count: 2)
        try await waitUntil { !coordinator.isRunning }
        #expect(started == ["first@icloud.com"] && store.accounts.count == 1)
        #expect(coordinator.completedCount == 1 && coordinator.hasPendingBatch)
        #expect(store.emailAliases[1].status == .available)
        #expect(store.accounts[0].proxy == proxies.proxies.first?.proxy)
        coordinator.resumeBatch()
        try await waitUntil { !coordinator.isRunning }
        #expect(started == ["first@icloud.com", "second@icloud.com"])
        #expect(coordinator.completedCount == 2 && !coordinator.hasPendingBatch)
        #expect(store.accounts.allSatisfy { $0.proxy == proxies.proxies.first?.proxy && $0.status == .ready })
    }

    @Test func newRegistrationDropsOnlyUnstartedQueueAndKeepsSavedDraft() async throws {
        let store = store()
        try store.importEmailAliases("first@icloud.com second@icloud.com")
        let coordinator = coordinator(store: store) { _ in }
        defer { coordinator.stop(); try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
        try coordinator.start(email: "first@icloud.com", count: 2)
        try await waitUntil { !coordinator.isRunning }
        let original = try #require(store.accounts.first)
        coordinator.newRegistration()
        coordinator.resumeBatch()
        #expect(!coordinator.isRunning && !coordinator.hasPendingBatch)
        #expect(coordinator.totalCount == 0 && coordinator.completedCount == 0)
        #expect(coordinator.accountID == nil && coordinator.activeSession == nil)
        #expect(store.accounts == [original] && store.emailAliases[1].status == .available)
        coordinator.resume(id: original.id)
        try await waitUntil { !coordinator.isRunning }
        #expect(coordinator.totalCount == 1 && store.accounts == [original])
    }

    @Test(arguments: ["consumed", "removed"])
    func unavailableQueuedAliasPausesWithoutCreatingAnotherDraft(reason: String) async throws {
        let store = store()
        try store.importEmailAliases("first@icloud.com second@icloud.com")
        var started: [UUID] = []
        let completion = RegistrationBatchCompletionGate()
        let coordinator = coordinator(store: store) { id in
            started.append(id)
            if completion.isOpen { try complete(id, in: store) }
        }
        defer { coordinator.stop(); try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
        try coordinator.start(email: "first@icloud.com", count: 2)
        try await waitUntil { !coordinator.isRunning }
        let original = try #require(store.accounts.first)
        var external: AccountRecord?
        if reason == "consumed" {
            try store.merge([.init(email: "second@icloud.com", password: "external", totpSecret: "JBSWY3DPEHPK3PXP")])
            let account: AccountRecord = try #require(store.accounts.last)
            external = account
        } else {
            try store.deleteAvailableEmailAlias(id: store.emailAliases[1].id)
        }
        completion.isOpen = true
        coordinator.resume(id: original.id)
        try await waitUntil { !coordinator.isRunning }
        #expect(started == [original.id, original.id])
        #expect(store.accounts.count == (external == nil ? 1 : 2))
        if let external { #expect(store.accounts.last == external) }
        #expect(coordinator.completedCount == 1 && coordinator.hasPendingBatch)
        #expect(store.accounts.filter { $0.email == "second@icloud.com" }.count == (external == nil ? 0 : 1))
    }

    @Test func restartBeforeStoreLoadRestoresDraftAndTailWithoutStarting() async throws {
        let store = store()
        defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
        try store.importEmailAliases("first@icloud.com second@icloud.com third@icloud.com")
        var calls = 0
        let original = coordinator(store: store) { id in
            calls += 1
            if calls == 1 { try complete(id, in: store) }
        }
        try original.start(email: "first@icloud.com", count: 3)
        try await waitUntil { !original.isRunning }
        let draftID = try #require(original.accountID)
        let reloadedStore = AccountStore(fileURL: store.fileURL)
        var resumed: [UUID] = []
        let restored = coordinator(store: reloadedStore) { id in
            resumed.append(id)
            try complete(id, in: reloadedStore)
        }
        try reloadedStore.load()
        #expect(restored.accountID == draftID && restored.completedCount == 1 && restored.totalCount == 3)
        #expect(restored.hasPendingBatch && !restored.isRunning && resumed.isEmpty)
        restored.show(id: draftID)
        #expect(restored.completedCount == 1 && restored.totalCount == 3)
        restored.resume(id: draftID)
        try await waitUntil { !restored.isRunning }
        #expect(resumed.first == draftID && resumed.count == 2)
        #expect(restored.completedCount == 3 && reloadedStore.accounts.count == 3)
        let sidecar = RegistrationBatchState.fileURL(for: store.fileURL)
        let text = try String(contentsOf: sidecar, encoding: .utf8)
        #expect(!text.contains("password") && !text.contains("pendingSecret") && !text.contains("proof"))
        #expect((try FileManager.default.attributesOfItem(atPath: sidecar.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test func restartAfterUserRemovedDraftContinuesOnlyOriginalTailWithoutCountingRemovalReady() async throws {
        let store = store()
        defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
        try store.importEmailAliases("first@icloud.com second@icloud.com third@icloud.com")
        var calls = 0
        let original = coordinator(store: store) { id in
            calls += 1
            if calls == 1 { try complete(id, in: store) }
        }
        try original.start(email: "first@icloud.com", count: 3)
        try await waitUntil { !original.isRunning }
        let removedID = try #require(original.accountID)
        let removed = try #require(store.accounts.first { $0.id == removedID })
        let sidecar = RegistrationBatchState.fileURL(for: store.fileURL)
        var queue = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: sidecar)) as? [String: Any])
        queue["remainingEmails"] = ["third@icloud.com"]
        queue.removeValue(forKey: "batchAccountID")
        queue["skippedAccountIDs"] = [removedID.uuidString]
        var database = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: store.fileURL)) as? [String: Any])
        let records = try #require(database["accounts"] as? [[String: Any]])
        database["accounts"] = records.filter { ($0["id"] as? String) != removedID.uuidString }
        try JSONSerialization.data(withJSONObject: database).write(to: store.fileURL, options: .atomic)
        try JSONSerialization.data(withJSONObject: queue).write(to: sidecar, options: .atomic)

        let reloadedStore = AccountStore(fileURL: store.fileURL)
        try reloadedStore.load()
        var resumed: [String] = []
        let restored = coordinator(store: reloadedStore) { id in
            resumed.append(try #require(reloadedStore.accounts.first { $0.id == id }).email)
            try complete(id, in: reloadedStore)
        }
        #expect(restored.totalCount == 3 && restored.completedCount == 1 && restored.hasPendingBatch)
        restored.resumeBatch()
        try await waitUntil { !restored.isRunning }
        #expect(resumed == ["third@icloud.com"])
        #expect(restored.totalCount == 3 && restored.completedCount == 2 && !restored.hasPendingBatch)
        #expect(!reloadedStore.accounts.contains { $0.id == removedID || $0.email == removed.email })
        #expect(reloadedStore.emailAliases.first { $0.email == removed.email }?.status == .used)
        #expect(restored.message.contains("пропущено пользователем: 1"))
        let saved = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: sidecar)) as? [String: Any])
        #expect(saved["skippedAccountIDs"] as? [String] == [removedID.uuidString])
    }

    @Test func savedBatchRejectsSkippedIdentityOverlaps() throws {
        let id = UUID().uuidString
        for changes: [String: Any] in [
            ["skippedAccountIDs": [id, id]],
            ["skippedAccountIDs": [id], "blockedAccountIDs": [id]],
            ["skippedAccountIDs": [id], "batchAccountID": id, "remainingEmails": ["tail@icloud.com"]],
        ] {
            var json: [String: Any] = ["version": 1, "totalCount": 2, "completedCount": 0,
                                       "remainingEmails": [], "skippedAccountIDs": [id]]
            json.merge(changes) { _, new in new }
            let state = try JSONDecoder().decode(RegistrationBatchState.self,
                                                from: JSONSerialization.data(withJSONObject: json))
            #expect(throws: RegistrationBatchError.invalidSavedBatch) { try state.validate() }
        }
    }

    @Test(arguments: ["liveDraft", "missingTailAlias"])
    func incompleteUserRemovalNeverStartsTail(reason: String) async throws {
        let store = store()
        defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
        try store.importEmailAliases("first@icloud.com second@icloud.com")
        let original = coordinator(store: store) { _ in }
        try original.start(email: "first@icloud.com", count: 2)
        try await waitUntil { !original.isRunning }
        let removedID = try #require(original.accountID)
        if reason == "missingTailAlias" {
            try store.deleteAvailableEmailAlias(id: #require(store.emailAliases.first { $0.email == "second@icloud.com" }).id)
            var database = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: store.fileURL)) as? [String: Any])
            database["accounts"] = []
            try JSONSerialization.data(withJSONObject: database).write(to: store.fileURL, options: .atomic)
        }
        let sidecar = RegistrationBatchState.fileURL(for: store.fileURL)
        let queue: [String: Any] = ["version": 1, "totalCount": 2, "completedCount": 0,
                                   "remainingEmails": ["second@icloud.com"], "skippedAccountIDs": [removedID.uuidString]]
        try JSONSerialization.data(withJSONObject: queue).write(to: sidecar, options: .atomic)
        let before = try Data(contentsOf: store.fileURL)
        let reloaded = AccountStore(fileURL: store.fileURL)
        try reloaded.load()
        var requests = 0
        let restored = coordinator(store: reloaded) { _ in requests += 1 }
        restored.resumeBatch()
        #expect(!restored.isRunning && requests == 0 && restored.completedCount == 0)
        #expect(restored.message == RegistrationBatchError.invalidSavedBatch.localizedDescription)
        #expect(try Data(contentsOf: store.fileURL) == before)
        #expect(try JSONSerialization.jsonObject(with: Data(contentsOf: sidecar)) as? NSDictionary == queue as NSDictionary)
    }

    @Test func restartReconcilesReadyCurrentAccountExactlyOnce() async throws {
        let store = store()
        defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
        try store.importEmailAliases("first@icloud.com second@icloud.com")
        let original = coordinator(store: store) { _ in }
        try original.start(email: "first@icloud.com", count: 2)
        try await waitUntil { !original.isRunning }
        let id = try #require(original.accountID)
        try complete(id, in: store) // Simulate crash before queue completion checkpoint.
        var resumed: [UUID] = []
        let restored = coordinator(store: store) { next in
            resumed.append(next)
            try complete(next, in: store)
        }
        restored.resumeBatch()
        try await waitUntil { !restored.isRunning }
        #expect(resumed.count == 1 && !resumed.contains(id))
        #expect(restored.completedCount == 2 && store.accounts.count == 2)
        let again = coordinator(store: store) { _ in Issue.record("Completed queue must not restart") }
        again.resumeBatch()
        #expect(again.completedCount == 2 && !again.hasPendingBatch && !again.isRunning)
    }

    @Test func restartReattachesDraftCommittedBeforeQueueUUID() async throws {
        let store = store()
        defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
        try store.importEmailAliases("first@icloud.com second@icloud.com")
        try RegistrationBatchState(totalCount: 2, completedCount: 0,
                                   remainingEmails: ["first@icloud.com", "second@icloud.com"])
            .save(to: RegistrationBatchState.fileURL(for: store.fileURL))
        let draft = try store.beginRegistration(email: "first@icloud.com", fullName: "Test User", age: 27, password: "fixture")
        var resumed: [UUID] = []
        let restored = coordinator(store: store) { id in
            resumed.append(id)
            try complete(id, in: store)
        }
        restored.resumeBatch()
        try await waitUntil { !restored.isRunning }
        #expect(resumed.first == draft.id && resumed.count == 2)
        #expect(store.accounts.count == 2 && restored.completedCount == 2)
    }

    @Test func invalidRestoredCurrentUUIDNeverStartsAnotherAccount() throws {
        let store = store()
        defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
        try store.importEmailAliases("first@icloud.com second@icloud.com")
        try RegistrationBatchState(totalCount: 2, completedCount: 0,
                                   remainingEmails: ["first@icloud.com", "second@icloud.com"], batchAccountID: UUID())
            .save(to: RegistrationBatchState.fileURL(for: store.fileURL))
        let restored = coordinator(store: store) { _ in Issue.record("Invalid plan must not register") }
        restored.resumeBatch()
        #expect(!restored.isRunning && store.accounts.isEmpty)
        #expect(restored.message == RegistrationBatchError.invalidSavedBatch.localizedDescription)
    }

    @Test func queueWriteFailureStopsBeforeDraftOrNetwork() throws {
        let store = store()
        defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
        try store.importEmailAliases("first@icloud.com")
        let coordinator = coordinator(store: store) { _ in Issue.record("Unsaved queue must not register") }
        let sidecar = RegistrationBatchState.fileURL(for: store.fileURL)
        try FileManager.default.createDirectory(at: sidecar, withIntermediateDirectories: false)
        // Nonempty directory cannot be atomically replaced by a queue file.
        try Data().write(to: sidecar.appendingPathComponent("blocker"))
        #expect(throws: RegistrationBatchError.persistenceFailed) {
            try coordinator.start(email: "first@icloud.com")
        }
        #expect(store.accounts.isEmpty && !coordinator.isRunning && !coordinator.hasPendingBatch)
    }

    @Test func completionCheckpointFailurePausesBeforeNextRequestAndCanReconcile() async throws {
        let store = store()
        defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
        try store.importEmailAliases("first@icloud.com second@icloud.com")
        let sidecar = RegistrationBatchState.fileURL(for: store.fileURL)
        var calls = 0
        let coordinator = coordinator(store: store) { id in
            calls += 1
            try complete(id, in: store)
            if calls == 1 {
                try FileManager.default.removeItem(at: sidecar)
                try FileManager.default.createDirectory(at: sidecar, withIntermediateDirectories: false)
            }
        }
        try coordinator.start(email: "first@icloud.com", count: 2)
        try await waitUntil { !coordinator.isRunning }
        #expect(calls == 1 && store.accounts.count == 1 && coordinator.completedCount == 0)
        #expect(coordinator.hasPendingBatch && coordinator.message.contains(RegistrationBatchError.persistenceFailed.localizedDescription))
        try FileManager.default.removeItem(at: sidecar)
        coordinator.resumeBatch()
        try await waitUntil { !coordinator.isRunning }
        #expect(calls == 2 && store.accounts.count == 2 && coordinator.completedCount == 2)
    }

    @Test func unrelatedDraftCannotReplacePausedQueue() async throws {
        let store = store()
        defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
        try store.importEmailAliases("first@icloud.com second@icloud.com")
        let unrelated = try store.beginRegistration(email: "unrelated@example.com", fullName: "Test User", age: 27, password: "fixture")
        let coordinator = coordinator(store: store) { _ in }
        try coordinator.start(email: "first@icloud.com", count: 2)
        try await waitUntil { !coordinator.isRunning }
        let current = coordinator.accountID
        let sidecar = RegistrationBatchState.fileURL(for: store.fileURL)
        let saved = try Data(contentsOf: sidecar)
        coordinator.show(id: unrelated.id)
        coordinator.resume(id: unrelated.id)
        #expect(throws: RegistrationBatchError.pendingBatchExists) {
            try coordinator.start(email: "another@example.com")
        }
        #expect(coordinator.accountID == current && coordinator.totalCount == 2 && coordinator.completedCount == 0)
        #expect(coordinator.hasPendingBatch && !coordinator.isRunning)
        #expect(try Data(contentsOf: sidecar) == saved)
    }

    @Test func explicitDeactivationPreservesFailedDraftAndContinuesOriginalTail() async throws {
        let store = store()
        defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
        try store.importEmailAliases("first@icloud.com second@icloud.com third@icloud.com unused@icloud.com")
        var started: [String] = []
        var failed: AccountRecord?
        let coordinator = coordinator(store: store) { id in
            let account = try #require(store.accounts.first(where: { $0.id == id }))
            started.append(account.email)
            if started.count == 1 {
                try store.mutate(id: id) { $0.lastError = RegistrationCoordinator.deactivatedAccountMessage }
                failed = store.accounts.first(where: { $0.id == id })
            } else { try complete(id, in: store) }
        }
        try coordinator.start(email: "first@icloud.com", count: 3)
        try await waitUntil { !coordinator.isRunning }
        let blocked = try #require(failed)
        #expect(started == ["first@icloud.com", "second@icloud.com", "third@icloud.com"])
        #expect(store.accounts.first == blocked && blocked.pendingRegistration != nil && blocked.status != .ready)
        #expect(store.emailAliases[0].status == .used && store.emailAliases[3].status == .available)
        #expect(coordinator.completedCount == 2 && coordinator.totalCount == 3 && coordinator.blockedAccountIDs == [blocked.id])
        #expect(!coordinator.hasPendingBatch && coordinator.message.contains("готово 2 из 3") && coordinator.message.contains("заблокировано OpenAI: 1"))
        let saved = try JSONDecoder().decode(RegistrationBatchState.self,
                                            from: Data(contentsOf: RegistrationBatchState.fileURL(for: store.fileURL)))
        try saved.validate()
        #expect(saved.blockedAccountIDs == [blocked.id] && saved.remainingEmails.isEmpty)
        let restored = self.coordinator(store: store) { _ in Issue.record("Blocked identity must not retry") }
        restored.resume(id: blocked.id)
        #expect(restored.completedCount == 2 && restored.blockedCount == 1 && !restored.isRunning)
        #expect(store.accounts.first == blocked)
    }

    @Test func restartSkipsPersistedDeactivationWithoutRequestAndReports149Of150() async throws {
        let store = store()
        defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
        try store.importEmailAliases("blocked@icloud.com next@icloud.com unused@icloud.com")
        let blocked = try store.beginRegistration(email: "blocked@icloud.com", fullName: "Test User", age: 27, password: "fixture")
        try store.mutate(id: blocked.id) { $0.lastError = RegistrationCoordinator.deactivatedAccountMessage }
        try RegistrationBatchState(totalCount: 150, completedCount: 148,
                                   remainingEmails: [blocked.email, "next@icloud.com"], batchAccountID: blocked.id)
            .save(to: RegistrationBatchState.fileURL(for: store.fileURL))
        var started: [String] = []
        let coordinator = coordinator(store: store) { id in
            started.append(try #require(store.accounts.first(where: { $0.id == id })).email)
            try complete(id, in: store)
        }
        coordinator.resumeBatch()
        try await waitUntil { !coordinator.isRunning }
        #expect(started == ["next@icloud.com"] && store.accounts.count == 2)
        #expect(coordinator.completedCount == 149 && coordinator.blockedCount == 1 && coordinator.totalCount == 150)
        #expect(coordinator.message.contains("готово 149 из 150") && coordinator.message.contains("заблокировано OpenAI: 1"))
        #expect(store.accounts[0].browserStoreID == blocked.browserStoreID && store.accounts[0].password == blocked.password)
        #expect(store.accounts[0].pendingRegistration == blocked.pendingRegistration && store.accounts[0].status != .ready)
    }

    @Test func restoredBlockedMetadataRequiresExactFailedDraftBeforeContinuing() async throws {
        let store = store()
        defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
        try store.importEmailAliases("blocked@icloud.com next@icloud.com")
        let blocked = try store.beginRegistration(email: "blocked@icloud.com", fullName: "Test User", age: 27, password: "fixture")
        let state = RegistrationBatchState(totalCount: 2, completedCount: 0,
                                           remainingEmails: ["next@icloud.com"], blockedAccountIDs: [blocked.id])
        try state.save(to: RegistrationBatchState.fileURL(for: store.fileURL))
        let invalid = coordinator(store: store) { _ in Issue.record("Unproven block must not continue") }
        invalid.resumeBatch()
        #expect(!invalid.isRunning && store.accounts.count == 1)
        #expect(invalid.message == RegistrationBatchError.invalidSavedBatch.localizedDescription)
        try store.mutate(id: blocked.id) { $0.lastError = RegistrationCoordinator.deactivatedAccountMessage }
        let valid = coordinator(store: store) { id in try complete(id, in: store) }
        valid.resumeBatch()
        try await waitUntil { !valid.isRunning }
        #expect(valid.completedCount == 1 && valid.blockedAccountIDs == [blocked.id] && store.accounts.count == 2)
        var duplicates = state
        duplicates.totalCount = 3
        duplicates.blockedAccountIDs = [blocked.id, blocked.id]
        #expect(throws: RegistrationBatchError.invalidSavedBatch) { try duplicates.validate() }
    }

    @Test func blockedDraftDoesNotRemainTheDisplayedResumeTarget() async throws {
        let store = store()
        defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
        try store.importEmailAliases("blocked@icloud.com")
        let blocked = try store.beginRegistration(email: "blocked@icloud.com", fullName: "Test User", age: 27, password: "fixture")
        try store.mutate(id: blocked.id) { $0.lastError = RegistrationCoordinator.deactivatedAccountMessage }
        try RegistrationBatchState(totalCount: 1, completedCount: 0,
                                   remainingEmails: [blocked.email], batchAccountID: blocked.id)
            .save(to: RegistrationBatchState.fileURL(for: store.fileURL))
        let coordinator = coordinator(store: store) { _ in Issue.record("Blocked identity must not be retried") }
        coordinator.resumeBatch()
        try await waitUntil { !coordinator.isRunning }
        #expect(coordinator.accountID == nil && coordinator.activeSession == nil)
        #expect(coordinator.blockedCount == 1 && coordinator.completedCount == 0)
        #expect(store.accounts[0].pendingRegistration != nil)
    }

    @Test func deletingTwoBlockedDraftsDuringOriginalQueuePreserves150LedgerAndTail() async throws {
        let store = store()
        defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
        let tail = (1...127).map { "tail\($0)@icloud.com" }
        try store.importEmailAliases((["blocked1@icloud.com", "blocked2@icloud.com"] + tail).joined(separator: " "))
        var blocked: [AccountRecord] = []
        for email in ["blocked1@icloud.com", "blocked2@icloud.com"] {
            let draft = try store.beginRegistration(email: email, fullName: "Test User", age: 27, password: "fixture")
            try store.mutate(id: draft.id) { $0.lastError = RegistrationCoordinator.deactivatedAccountMessage }
            blocked.append(try #require(store.accounts.first { $0.id == draft.id }))
        }
        let current = try store.beginRegistration(email: tail[0], fullName: "Test User", age: 27, password: "current")
        let skippedID = UUID()
        let sidecar = RegistrationBatchState.fileURL(for: store.fileURL)
        try RegistrationBatchState(totalCount: 150, completedCount: 20, remainingEmails: tail,
                                   batchAccountID: current.id, blockedAccountIDs: blocked.map(\.id),
                                   skippedAccountIDs: [skippedID]).save(to: sidecar)
        let gate = RegistrationBatchCompletionGate()
        var started: [UUID] = []
        let running = coordinator(store: store) { id in
            started.append(id)
            while !gate.isOpen { try await Task.sleep(for: .milliseconds(10)) }
        }
        running.resumeBatch()
        try await waitUntil { started == [current.id] }
        let session = running.activeSession
        let currentBefore = try #require(store.accounts.first { $0.id == current.id })
        for account in blocked {
            #expect(running.canDeleteBlockedAccount(id: account.id, protectedIDs: [current.id]))
            try running.deleteBlockedAccount(id: account.id, protectedIDs: [current.id])
        }
        #expect(running.isRunning && running.accountID == current.id && running.activeSession === session)
        #expect(store.accounts == [currentBefore])
        let saved = try JSONDecoder().decode(RegistrationBatchState.self, from: Data(contentsOf: sidecar))
        try saved.validate()
        #expect(saved.totalCount == 150 && saved.completedCount == 20 && saved.remainingEmails == tail)
        #expect(saved.batchAccountID == current.id && saved.blockedAccountIDs == blocked.map(\.id))
        #expect(saved.skippedAccountIDs == [skippedID] && saved.removedBlockedAccountIDs == blocked.map(\.id))
        #expect(store.emailAliases.prefix(2).allSatisfy { $0.status == .used })
        gate.isOpen = true
        try await waitUntil { !running.isRunning }

        let reloaded = AccountStore(fileURL: store.fileURL)
        try reloaded.load()
        var resumed: [String] = []
        let restored = coordinator(store: reloaded) { id in
            resumed.append(try #require(reloaded.accounts.first { $0.id == id }).email)
            if resumed.count < 3 { try complete(id, in: reloaded) }
        }
        restored.resumeBatch()
        try await waitUntil { !restored.isRunning }
        #expect(resumed == Array(tail.prefix(3)))
        #expect(restored.totalCount == 150 && restored.completedCount == 22 && restored.blockedCount == 2 && restored.skippedCount == 1)
        #expect(restored.removedBlockedAccountIDs == blocked.map(\.id))
        #expect(!reloaded.accounts.contains { blocked.map(\.id).contains($0.id) })
        let resumedState = try JSONDecoder().decode(RegistrationBatchState.self, from: Data(contentsOf: sidecar))
        #expect(resumedState.remainingEmails == Array(tail.dropFirst(2)))
        #expect(resumedState.remainingEmails.count + restored.completedCount + restored.blockedCount + restored.skippedCount == 150)
    }

    @Test(arguments: ["protected", "unledgered", "wrongError", "current", "pendingEmail", "pendingPassword", "pendingAccess", "rotation", "pendingTOTP"])
    func blockedDeletionRejectsUnprovenOrBusyIdentity(reason: String) throws {
        let store = store()
        defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
        try store.importEmailAliases("blocked@icloud.com tail@icloud.com")
        let blocked = try store.beginRegistration(email: "blocked@icloud.com", fullName: "Test User", age: 27, password: "fixture")
        try store.mutate(id: blocked.id) {
            $0.lastError = reason == "wrongError" ? "other failure" : RegistrationCoordinator.deactivatedAccountMessage
        }
        var state = RegistrationBatchState(totalCount: 2, completedCount: 0, remainingEmails: ["tail@icloud.com"],
                                           blockedAccountIDs: [blocked.id])
        if reason == "unledgered" { state.blockedAccountIDs = nil; state.totalCount = 1 }
        if reason == "current" {
            state.blockedAccountIDs = nil
            state.remainingEmails = [blocked.email, "tail@icloud.com"]
            state.batchAccountID = blocked.id
        }
        try state.save(to: RegistrationBatchState.fileURL(for: store.fileURL))
        let coordinator = coordinator(store: store) { _ in Issue.record("Deletion must not start registration") }
        // Generic mutation rejects registration credential changes; fixture edits stay in temporary persisted data.
        if ["pendingEmail", "pendingPassword", "pendingAccess", "rotation", "pendingTOTP"].contains(reason) {
            var root = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: store.fileURL)) as? [String: Any])
            var accounts = try #require(root["accounts"] as? [[String: Any]])
            if reason == "pendingEmail" {
                let pending = PendingEmailChange(aliasID: UUID(), originalEmail: blocked.email, newEmail: "other@icloud.com")
                accounts[0]["pendingEmailChange"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(pending))
            } else {
                let key = ["pendingPassword": "pendingPassword", "pendingAccess": "pendingAccessChange",
                           "rotation": "rotationStage", "pendingTOTP": "pendingTOTPSecret"][reason]!
                accounts[0][key] = ["pendingAccess": "password", "rotation": "removingOldMethod"][reason] ?? "fixture"
            }
            root["accounts"] = accounts
            try JSONSerialization.data(withJSONObject: root).write(to: store.fileURL, options: .atomic)
            try store.load()
        }
        let before = try Data(contentsOf: store.fileURL)
        let protectedIDs: Set<UUID> = reason == "protected" ? [blocked.id] : []
        #expect(!coordinator.canDeleteBlockedAccount(id: blocked.id, protectedIDs: protectedIDs))
        #expect(throws: (any Error).self) { try coordinator.deleteBlockedAccount(id: blocked.id, protectedIDs: protectedIDs) }
        #expect(try Data(contentsOf: store.fileURL) == before)
        #expect(store.accounts.count == 1 && coordinator.removedBlockedAccountIDs.isEmpty && !coordinator.isRunning)
    }

    @Test func removedBlockedMarkersRejectDuplicatesAndIDsOutsideBlockedLedger() throws {
        let id = UUID()
        var state = RegistrationBatchState(totalCount: 1, completedCount: 0, remainingEmails: [],
                                           blockedAccountIDs: [id], removedBlockedAccountIDs: [id])
        try state.validate()
        state.removedBlockedAccountIDs = [id, id]
        #expect(throws: RegistrationBatchError.invalidSavedBatch) { try state.validate() }
        state.removedBlockedAccountIDs = [UUID()]
        #expect(throws: RegistrationBatchError.invalidSavedBatch) { try state.validate() }
    }

    @Test(arguments: [false, true])
    func missingBlockedRecordRequiresPersistedRemovalMarker(marked: Bool) async throws {
        let store = store()
        defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
        try store.importEmailAliases("tail@icloud.com")
        let id = UUID()
        try RegistrationBatchState(totalCount: 2, completedCount: 0, remainingEmails: ["tail@icloud.com"],
                                   blockedAccountIDs: [id], removedBlockedAccountIDs: marked ? [id] : nil)
            .save(to: RegistrationBatchState.fileURL(for: store.fileURL))
        var requests = 0
        let restored = coordinator(store: store) { _ in requests += 1 }
        restored.resumeBatch()
        try await waitUntil { !restored.isRunning }
        #expect(requests == (marked ? 1 : 0))
        #expect(restored.completedCount == 0 && restored.blockedCount == 1 && restored.totalCount == 2)
        if !marked { #expect(restored.message == RegistrationBatchError.invalidSavedBatch.localizedDescription) }
    }

    @Test func failedBlockedDeletionKeepsMarkerAndExactDraftRecoverable() async throws {
        let store = store()
        defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
        try store.importEmailAliases("blocked@icloud.com tail@icloud.com")
        let blocked = try store.beginRegistration(email: "blocked@icloud.com", fullName: "Test User", age: 27, password: "fixture")
        try store.mutate(id: blocked.id) { $0.lastError = RegistrationCoordinator.deactivatedAccountMessage }
        let original = try Data(contentsOf: store.fileURL)
        let sidecar = RegistrationBatchState.fileURL(for: store.fileURL)
        try RegistrationBatchState(totalCount: 2, completedCount: 0, remainingEmails: ["tail@icloud.com"],
                                   blockedAccountIDs: [blocked.id]).save(to: sidecar)
        let coordinator = coordinator(store: store) { _ in }
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: store.fileURL.path)
        defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: store.fileURL.path) }
        #expect(throws: (any Error).self) { try coordinator.deleteBlockedAccount(id: blocked.id, protectedIDs: []) }
        #expect(store.accounts.count == 1 && coordinator.removedBlockedAccountIDs == [blocked.id])
        #expect(try Data(contentsOf: store.fileURL) == original)
        try FileManager.default.setAttributes([.immutable: false], ofItemAtPath: store.fileURL.path)
        let reloaded = AccountStore(fileURL: store.fileURL)
        try reloaded.load()
        var requests = 0
        let restored = self.coordinator(store: reloaded) { _ in requests += 1 }
        restored.resumeBatch()
        try await waitUntil { !restored.isRunning }
        #expect(requests == 1 && restored.blockedCount == 1 && restored.completedCount == 0)
        #expect(reloaded.accounts.contains { $0.id == blocked.id })
        try restored.deleteBlockedAccount(id: blocked.id, protectedIDs: [])
        #expect(!reloaded.accounts.contains { $0.id == blocked.id })
        let saved = try JSONDecoder().decode(RegistrationBatchState.self, from: Data(contentsOf: sidecar))
        #expect(saved.removedBlockedAccountIDs == [blocked.id] && saved.blockedAccountIDs == [blocked.id])
    }

    @Test func blockedDeletionQueueWriteFailurePreservesAccountAndLedger() async throws {
        let store = store()
        defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
        try store.importEmailAliases("blocked@icloud.com tail@icloud.com")
        let blocked = try store.beginRegistration(email: "blocked@icloud.com", fullName: "Test User", age: 27, password: "fixture")
        try store.mutate(id: blocked.id) { $0.lastError = RegistrationCoordinator.deactivatedAccountMessage }
        let sidecar = RegistrationBatchState.fileURL(for: store.fileURL)
        try RegistrationBatchState(totalCount: 2, completedCount: 0, remainingEmails: ["tail@icloud.com"],
                                   blockedAccountIDs: [blocked.id]).save(to: sidecar)
        let coordinator = coordinator(store: store) { _ in }
        coordinator.resumeBatch()
        try await waitUntil { !coordinator.isRunning }
        let before = try Data(contentsOf: store.fileURL)
        #expect(coordinator.canDeleteBlockedAccount(id: blocked.id, protectedIDs: []))
        try FileManager.default.removeItem(at: sidecar)
        try FileManager.default.createDirectory(at: sidecar, withIntermediateDirectories: false)
        #expect(throws: RegistrationBatchError.persistenceFailed) {
            try coordinator.deleteBlockedAccount(id: blocked.id, protectedIDs: [])
        }
        #expect(try Data(contentsOf: store.fileURL) == before)
        #expect(coordinator.blockedAccountIDs == [blocked.id] && coordinator.removedBlockedAccountIDs.isEmpty)
        #expect(coordinator.totalCount == 2 && coordinator.completedCount == 0)
    }
}
