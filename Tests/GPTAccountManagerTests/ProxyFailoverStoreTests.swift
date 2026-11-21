import Foundation
import Testing
@testable import GPTAccountManager

@MainActor
@Suite struct ProxyFailoverStoreTests {
    private let old = AccountProxy(scheme: .http, host: "old.example", port: 80)
    private let replacement = AccountProxy(scheme: .socks5, host: "replacement.example", port: 1080)

    private func directory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    @Test(arguments: [true, false])
    func healthyAssignmentSurvivesRemovalOrDisableInPool(removed: Bool) async throws {
        let directory = directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = ProbeRecorder(working: [old])
        let store = ProxyStore(fileURL: directory.appendingPathComponent("proxies.json"),
                               checker: { await recorder.probe($0) }, shuffled: { Array($0.reversed()) })
        try store.add(text: "\(old.urlString)\n\(replacement.urlString)")
        let entry = try #require(store.proxies.first)
        if removed {
            try store.remove(id: entry.id)
        } else {
            try store.update(id: entry.id, text: old.urlString, label: "", isEnabled: false)
        }
        try store.setEnabled(true)
        #expect(try await store.checkedProxy(replacing: old) == old)
        #expect(await recorder.seen == [old])
        #expect(!store.isChecking)
    }

    @Test func deadAssignmentRechecksCachedSuccessThenUsesShuffledAlternative() async throws {
        let directory = directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let stale = AccountProxy(scheme: .https, host: "stale.example", port: 443)
        let recorder = ProbeRecorder(working: [stale])
        let store = ProxyStore(fileURL: directory.appendingPathComponent("proxies.json"),
                               checker: { await recorder.probe($0) }, shuffled: { Array($0.reversed()) })
        try store.add(text: "\(old.urlString)\n\(stale.urlString)\nunused.example:80\n\(replacement.urlString)")
        let staleID = try #require(store.proxies.first(where: { $0.proxy == stale })?.id)
        await store.check(id: staleID)
        await recorder.reset(working: [replacement])
        try store.setEnabled(true)
        #expect(try await store.checkedProxy(replacing: old) == replacement)
        #expect(await recorder.seen == [old, stale, replacement])
        #expect(store.proxies.first(where: { $0.proxy == stale })?.check?.status == .unavailable)
        #expect(store.proxies.first(where: { $0.proxy == replacement })?.check?.status == .available)
    }

    @Test func disabledModeDoesNotProbeAndExplicitSelectionExcludesAssignment() async throws {
        let directory = directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = ProbeRecorder(working: [old, replacement])
        let store = ProxyStore(fileURL: directory.appendingPathComponent("proxies.json"),
                               checker: { await recorder.probe($0) }, shuffled: { $0 })
        try store.add(text: "\(old.urlString)\n\(replacement.urlString)")
        #expect(try await store.checkedProxy(replacing: old) == nil)
        #expect(await recorder.seen.isEmpty)
        try store.setEnabled(true)
        #expect(try await store.chooseForNewAccount(excluding: [old]) == replacement)
        #expect(await recorder.seen == [replacement])
    }

    @Test func exhaustedFailoverIsBoundedAndKeepsAccountAssignment() async throws {
        let directory = directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = ProbeRecorder()
        let store = ProxyStore(fileURL: directory.appendingPathComponent("proxies.json"),
                               checker: { await recorder.probe($0) }, shuffled: { $0 })
        try store.add(text: ([old.urlString] + (1...20).map { "proxy\($0).example:80" }).joined(separator: "\n"))
        try store.setEnabled(true)
        let accounts = AccountStore(fileURL: directory.appendingPathComponent("accounts.json"))
        let draft = try accounts.beginRegistration(
            email: "new@icloud.com", fullName: "Test Person", age: 28, password: "fixture", proxy: old)
        let originalData = try Data(contentsOf: accounts.fileURL)
        await #expect(throws: ProxyStoreError.noAvailableProxy) {
            if let proxy = try await store.checkedProxy(replacing: old) {
                try accounts.replaceAccountProxy(id: draft.id, expectedProxy: old, proxy: proxy)
            }
        }
        #expect(await recorder.seen.count == 12)
        #expect(await recorder.seen.filter { $0 == old }.count == 1)
        #expect(accounts.accounts == [draft])
        #expect(try Data(contentsOf: accounts.fileURL) == originalData)
    }

    @Test func cancelledProbeDoesNotPersistResultOrTryReplacement() async throws {
        let directory = directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = ProbeRecorder(working: [replacement], cancel: true)
        let store = ProxyStore(fileURL: directory.appendingPathComponent("proxies.json"),
                               checker: { await recorder.probe($0) }, shuffled: { $0 })
        try store.add(text: "\(old.urlString)\n\(replacement.urlString)")
        try store.setEnabled(true)
        let original = store.proxies
        let task = Task { try await store.checkedProxy(replacing: old) }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await recorder.seen == [old])
        #expect(store.proxies == original)
        #expect(!store.isChecking)
    }

    @Test(arguments: [true, false])
    func replacementPreservesEveryOtherFieldAndRoundTrips(assigned: Bool) throws {
        let directory = directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AccountStore(fileURL: directory.appendingPathComponent("accounts.json"))
        try store.merge([.init(email: "fixture@example.com", password: "fixture", totpSecret: "JBSWY3DPEHPK3PXP")])
        let id = try #require(store.accounts.first?.id)
        let group = try store.createGroup(name: "Saved group", tag: "keep")
        try store.mutate(id: id) {
            $0.proxy = assigned ? old : nil
            $0.groupID = group.id
            $0.tag = "original"
            $0.status = .ready
            $0.planLabel = "plus"
            $0.subscriptionDate = Date(timeIntervalSince1970: 1_800_000_000)
            $0.subscriptionDateKind = .renews
            $0.lastCheckedAt = Date(timeIntervalSince1970: 1_700_000_000)
            $0.lastError = "preserved"
        }
        var expected = try #require(store.accounts.first)
        let expectedProxy = expected.proxy
        expected.proxy = replacement
        let result = try store.replaceAccountProxy(id: id, expectedProxy: expectedProxy, proxy: replacement)
        #expect(result == expected)
        #expect(store.accounts == [expected])
        #expect(store.groups == [group])
        #expect(store.selectedID == id)
        let reopened = AccountStore(fileURL: store.fileURL)
        try reopened.load()
        #expect(reopened.accounts == [expected])
    }

    @Test func staleAssignmentProtectedAccountAndCredentialChangesRejectReplacement() throws {
        let directory = directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AccountStore(fileURL: directory.appendingPathComponent("accounts.json"))
        try store.merge([.init(email: "fixture@example.com", password: "fixture", totpSecret: "JBSWY3DPEHPK3PXP")])
        let id = try #require(store.accounts.first?.id)
        try store.mutate(id: id) { $0.proxy = old }
        let original = store.accounts
        for (expected, protected) in [(nil, Set<UUID>()), (Optional(old), Set([id]))] {
            #expect(throws: AccountStoreError.accountBusy) {
                try store.replaceAccountProxy(id: id, expectedProxy: expected, proxy: replacement, protectedIDs: protected)
            }
            #expect(store.accounts == original)
        }
        try store.replaceAccountProxy(id: id, expectedProxy: old, proxy: replacement)
        #expect(throws: AccountStoreError.accountBusy) {
            try store.replaceAccountProxy(id: id, expectedProxy: old, proxy: old)
        }
        try store.mutate(id: id) { $0.status = .checking }
        #expect(try store.replaceAccountProxy(id: id, expectedProxy: replacement, proxy: old).status == .checking)
        try store.replaceAccountProxy(id: id, expectedProxy: old, proxy: replacement)
        for change in 0..<4 {
            try store.mutate(id: id) {
                $0.rotationStage = change == 0 ? .removingOldMethod : nil
                $0.pendingTOTPSecret = change == 1 ? "KRUGS4ZANFZSAYJA" : nil
                $0.pendingPassword = change == 2 ? "next-password" : nil
                $0.pendingAccessChange = change == 3 ? .password : nil
            }
            let unchanged = store.accounts
            #expect(throws: AccountStoreError.accountBusy) {
                try store.replaceAccountProxy(id: id, expectedProxy: replacement, proxy: old)
            }
            #expect(store.accounts == unchanged)
        }
    }

    @Test func registrationDraftUsesDedicatedReplacementWhileGenericMutationAndEmailChangeStayGuarded() throws {
        let directory = directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AccountStore(fileURL: directory.appendingPathComponent("accounts.json"))
        let draft = try store.beginRegistration(
            email: "new@icloud.com", fullName: "Test Person", age: 28, password: "fixture", proxy: old)
        #expect(throws: AccountStoreError.accountBusy) { try store.mutate(id: draft.id) { $0.proxy = replacement } }
        var expected = draft
        expected.proxy = replacement
        #expect(try store.replaceAccountProxy(id: draft.id, expectedProxy: old, proxy: replacement) == expected)
        #expect(throws: AccountStoreError.accountBusy) {
            try store.replaceAccountProxy(id: draft.id, expectedProxy: replacement, proxy: old, protectedIDs: [draft.id])
        }
        try store.merge([.init(email: "existing@example.com", password: "fixture", totpSecret: "JBSWY3DPEHPK3PXP")])
        let id = try #require(store.accounts.last?.id)
        try store.importEmailAliases("next@icloud.com")
        try store.reserveEmailChange(id: id)
        let unchanged = store.accounts
        #expect(throws: AccountStoreError.accountBusy) {
            try store.replaceAccountProxy(id: id, expectedProxy: nil, proxy: replacement)
        }
        #expect(store.accounts == unchanged)
    }

    private actor ProbeRecorder {
        var seen: [AccountProxy] = []
        private var working: Set<AccountProxy>
        private let cancel: Bool

        init(working: Set<AccountProxy> = [], cancel: Bool = false) {
            self.working = working
            self.cancel = cancel
        }

        func reset(working: Set<AccountProxy>) {
            self.working = working
            seen = []
        }

        func probe(_ proxy: AccountProxy) -> ProxyCheckResult {
            seen.append(proxy)
            if cancel { withUnsafeCurrentTask { $0?.cancel() } }
            return .init(status: working.contains(proxy) ? .available : .unavailable,
                         checkedAt: Date(), message: "fixture")
        }
    }
}
