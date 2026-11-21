import Foundation
import Testing
@testable import GPTAccountManager

@MainActor
@Suite struct AccountTrashTests {
    private let date = Date(timeIntervalSince1970: 1_800_000_000)

    private func temporaryFile() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("accounts.json")
    }

    private func write<T: Encodable>(_ value: T, to file: URL) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(value).write(to: file)
    }

    private func account(_ email: String = "saved@icloud.com", groupID: UUID? = nil) -> AccountRecord {
        var value = AccountRecord(credential: .init(email: email, password: "fixture-password", totpSecret: "JBSWY3DPEHPK3PXP"))
        value.groupID = groupID
        return value
    }

    private func richAccount(groupID: UUID) -> AccountRecord {
        var value = account(groupID: groupID)
        value.planLabel = "Plus"
        value.subscriptionDate = date
        value.subscriptionDateKind = .renews
        value.lastCheckedAt = date.addingTimeInterval(-60)
        value.status = .needsRecovery
        value.lastError = "fixture-recovery"
        value.pendingTOTPSecret = "KRUGS4ZANFZSAYJA"
        value.rotationStage = .pendingSecretCaptured
        value.tag = "saved-tag"
        value.pendingPassword = "fixture-pending-password"
        value.pendingAccessChange = .passwordAndTwoFA
        value.abandonedEmailChange = .init(aliasID: UUID(), originalEmail: value.email,
                                          newEmail: "abandoned@icloud.com", phase: .requested,
                                          baselineMessageIDs: ["fixture-message"], requestedAt: date,
                                          originalUserID: "fixture-user", requestAttemptID: UUID())
        value.proxy = .init(scheme: .socks5, host: "proxy.example.com", port: 1080,
                            username: "fixture-user", password: "fixture-proxy-password")
        value.accessToken = "fixture-access-token"
        return value
    }

    @Test(arguments: [false, true])
    func legacyArrayAndEnvelopeWithoutTrashLoadWithEmptyTrash(envelope: Bool) throws {
        let file = temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let original = account("legacy@example.com")
        if envelope {
            try write(PersistedAccountData(groups: [], accounts: [original]), to: file)
            var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
            object.removeValue(forKey: "deletedAccounts")
            object.removeValue(forKey: "emailAliases")
            try JSONSerialization.data(withJSONObject: object).write(to: file)
        } else {
            try write([original], to: file)
        }
        let store = AccountStore(fileURL: file)

        try store.load()

        #expect(store.accounts == [original])
        #expect(store.deletedAccounts.isEmpty && store.emailAliases.isEmpty)
    }

    @Test func deletionPersistsFullSnapshotAndLaterCommitsKeepTrash() throws {
        let file = temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let group = AccountGroup(name: "Saved group", tag: "group-tag")
        let original = richAccount(groupID: group.id)
        let remaining = account("remaining@example.com")
        let alias = EmailAlias(email: original.email, status: .used, accountID: original.id)
        try write(PersistedAccountData(groups: [group], accounts: [original, remaining], emailAliases: [alias]), to: file)
        let store = AccountStore(fileURL: file)
        try store.load()
        store.selectedID = original.id
        let before = Date()

        try store.deleteAccount(id: original.id, protectedIDs: [])
        let snapshot = try #require(store.deletedAccounts.first)
        try store.setAccountTag(id: remaining.id, tag: "kept")
        let reloaded = AccountStore(fileURL: file)
        try reloaded.load()
        let persisted = try #require(reloaded.deletedAccounts.first)

        #expect(store.accounts.map(\.id) == [remaining.id] && store.selectedID == remaining.id)
        #expect(snapshot.account == original && snapshot.group == group)
        #expect(snapshot.id != original.id && snapshot.deletedAt >= before && snapshot.deletedAt <= Date())
        #expect(persisted.id == snapshot.id && persisted.account == original && persisted.group == group)
        #expect(abs(persisted.deletedAt.timeIntervalSince(snapshot.deletedAt)) < 1)
        #expect(reloaded.emailAliases == [alias] && reloaded.groups == [group])
        #expect((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect((try FileManager.default.attributesOfItem(atPath: file.deletingLastPathComponent().path)[.posixPermissions] as? NSNumber)?.intValue == 0o700)
    }

    @Test func singleAndGroupDeletionArchiveEveryRemovedRecordOnce() throws {
        let file = temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let group = AccountGroup(name: "Deleted group", tag: "saved")
        let first = account("single@example.com")
        let members = [account("one@example.com", groupID: group.id), account("two@example.com", groupID: group.id)]
        let remaining = account("remaining@example.com")
        try write(PersistedAccountData(groups: [group], accounts: [first] + members + [remaining]), to: file)
        let store = AccountStore(fileURL: file)
        try store.load()
        store.selectedID = remaining.id

        try store.deleteAccount(id: first.id, protectedIDs: [])
        try store.deleteAccount(id: first.id, protectedIDs: [])
        try store.deleteGroup(id: group.id, protectedIDs: [])

        #expect(store.accounts == [remaining] && store.groups.isEmpty && store.selectedID == remaining.id)
        #expect(store.deletedAccounts.map(\.account) == [first] + members)
        #expect(Set(store.deletedAccounts.map(\.id)).count == 3)
        #expect(store.deletedAccounts.first?.group == nil)
        #expect(store.deletedAccounts.dropFirst().allSatisfy { $0.group == group })
        let reloaded = AccountStore(fileURL: file)
        try reloaded.load()
        #expect(reloaded.deletedAccounts.map(\.account) == [first] + members)
    }

    @Test(arguments: [false, true])
    func restorePreservesFieldsAndRestoresOrReusesMissingGroup(nameCollision: Bool) throws {
        let file = temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let group = AccountGroup(name: "Saved group", tag: "original-tag")
        var expected = richAccount(groupID: group.id)
        let alias = EmailAlias(email: expected.email, status: .used, accountID: expected.id)
        try write(PersistedAccountData(groups: [group], accounts: [expected], emailAliases: [alias]), to: file)
        let store = AccountStore(fileURL: file)
        try store.load()
        try store.deleteGroup(id: group.id, protectedIDs: [])
        let snapshotID = try #require(store.deletedAccounts.first?.id)
        let expectedGroup: AccountGroup
        if nameCollision {
            expectedGroup = try store.createGroup(name: "SAVED GROUP", tag: "current-tag")
            expected.groupID = expectedGroup.id
        } else {
            expectedGroup = group
        }

        try store.restoreDeletedAccount(id: snapshotID, protectedIDs: [])

        #expect(store.accounts == [expected] && store.selectedID == expected.id)
        #expect(store.groups == [expectedGroup] && store.deletedAccounts.isEmpty)
        #expect(store.emailAliases == [alias])
        let reloaded = AccountStore(fileURL: file)
        try reloaded.load()
        #expect(reloaded.accounts == [expected] && reloaded.groups == [expectedGroup] && reloaded.deletedAccounts.isEmpty)
    }

    @Test func restoreKeepsExistingGroupAndSelectedAccount() throws {
        let file = temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let group = AccountGroup(name: "Original", tag: "original")
        let original = account(groupID: group.id)
        let remaining = account("remaining@example.com")
        try write(PersistedAccountData(groups: [group], accounts: [original, remaining]), to: file)
        let store = AccountStore(fileURL: file)
        try store.load()
        store.selectedID = remaining.id
        try store.deleteAccount(id: original.id, protectedIDs: [])
        let snapshotID = try #require(store.deletedAccounts.first?.id)
        try store.updateGroup(id: group.id, name: "Renamed", tag: "current")
        let currentGroups = store.groups

        try store.restoreDeletedAccount(id: snapshotID, protectedIDs: [])

        #expect(store.groups == currentGroups && store.accounts == [remaining, original])
        #expect(store.selectedID == remaining.id)
    }

    @Test(arguments: ["id", "email", "livePendingEmail", "restoredPendingEmail"])
    func duplicateRestoreLeavesSnapshotAndFileUntouched(conflict: String) throws {
        let file = temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        var original = account()
        var existing = account("existing@example.com")
        var aliases: [EmailAlias] = []
        if conflict == "id" { existing.id = original.id }
        if conflict == "email" { existing.email = original.email.uppercased() }
        if conflict == "livePendingEmail" {
            existing.pendingEmailChange = .init(aliasID: UUID(), originalEmail: existing.email, newEmail: original.email.uppercased())
        }
        if conflict == "restoredPendingEmail" {
            original.pendingEmailChange = .init(aliasID: UUID(), originalEmail: original.email, newEmail: existing.email.uppercased())
            let pending = try #require(original.pendingEmailChange)
            aliases = [.init(id: pending.aliasID, email: pending.newEmail, status: .reserved, accountID: original.id)]
        }
        let snapshot = DeletedAccountSnapshot(account: original, deletedAt: date)
        try write(PersistedAccountData(groups: [], accounts: [existing], emailAliases: aliases, deletedAccounts: [snapshot]), to: file)
        let store = AccountStore(fileURL: file)
        try store.load()
        let before = store.accounts
        let bytes = try Data(contentsOf: file)

        #expect(throws: AccountStoreError.duplicateAccountEmail) {
            try store.restoreDeletedAccount(id: snapshot.id, protectedIDs: [])
        }

        #expect(store.accounts == before && store.deletedAccounts == [snapshot])
        #expect(store.emailAliases == aliases)
        #expect(try Data(contentsOf: file) == bytes)
    }

    @Test(arguments: ["usedOther", "usedNone", "reservedOther", "reservedNone"])
    func restoreDoesNotClaimConsumedAliasWithoutExactOwner(conflict: String) throws {
        let file = temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let original = account()
        let snapshot = DeletedAccountSnapshot(account: original, deletedAt: date)
        let alias = EmailAlias(email: original.email.uppercased(),
                               status: conflict.hasPrefix("used") ? .used : .reserved,
                               accountID: conflict.hasSuffix("Other") ? UUID() : nil)
        try write(PersistedAccountData(groups: [], accounts: [], emailAliases: [alias], deletedAccounts: [snapshot]), to: file)
        let store = AccountStore(fileURL: file)
        try store.load()

        #expect(throws: AccountStoreError.emailAliasUnavailable) {
            try store.restoreDeletedAccount(id: snapshot.id, protectedIDs: [])
        }

        #expect(store.accounts.isEmpty && store.deletedAccounts == [snapshot] && store.emailAliases == [alias])
    }

    @Test func pendingEmailSnapshotNeedsExactReservationAndPreservesRecoveryState() throws {
        let file = temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        var original = account()
        original.pendingEmailChange = .init(aliasID: UUID(), originalEmail: original.email, newEmail: "reserved@icloud.com",
                                            phase: .requested, baselineMessageIDs: ["fixture"], requestedAt: date,
                                            originalUserID: "fixture-user", requestAttemptID: UUID())
        original.status = .needsRecovery
        let pending = try #require(original.pendingEmailChange)
        let snapshot = DeletedAccountSnapshot(account: original, deletedAt: date)
        let alias = EmailAlias(id: pending.aliasID, email: pending.newEmail, status: .reserved, accountID: original.id)
        try write(PersistedAccountData(groups: [], accounts: [], emailAliases: [alias], deletedAccounts: [snapshot]), to: file)
        let store = AccountStore(fileURL: file)
        try store.load()

        try store.restoreDeletedAccount(id: snapshot.id, protectedIDs: [])

        #expect(store.accounts == [original] && store.emailAliases == [alias] && store.deletedAccounts.isEmpty)
        #expect(throws: AccountStoreError.accountBusy) { try store.deleteAccount(id: original.id, protectedIDs: []) }
    }

    @Test(arguments: ["missing", "available", "wrongID", "wrongEmail"])
    func pendingEmailSnapshotCannotRestoreWithoutExactReservation(conflict: String) throws {
        let file = temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        var original = account()
        original.pendingEmailChange = .init(aliasID: UUID(), originalEmail: original.email, newEmail: "reserved@icloud.com")
        original.status = .needsRecovery
        let pending = try #require(original.pendingEmailChange)
        let snapshot = DeletedAccountSnapshot(account: original, deletedAt: date)
        let alias = EmailAlias(id: conflict == "wrongID" ? UUID() : pending.aliasID,
                               email: conflict == "wrongEmail" ? "other@icloud.com" : pending.newEmail,
                               status: conflict == "available" ? .available : .reserved, accountID: original.id)
        let aliases = conflict == "missing" ? [] : [alias]
        try write(PersistedAccountData(groups: [], accounts: [], emailAliases: aliases, deletedAccounts: [snapshot]), to: file)
        let store = AccountStore(fileURL: file)
        try store.load()

        #expect(throws: AccountStoreError.emailAliasUnavailable) {
            try store.restoreDeletedAccount(id: snapshot.id, protectedIDs: [])
        }

        #expect(store.accounts.isEmpty && store.deletedAccounts == [snapshot] && store.emailAliases == aliases)
    }

    @Test func blockedRegistrationRestoresExactDraftWithoutChangingQueueOrAliasLedger() throws {
        let file = temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let store = AccountStore(fileURL: file)
        try store.importEmailAliases("saved@icloud.com tail@icloud.com")
        let draft = try store.beginRegistration(email: "saved@icloud.com", fullName: "Fixture User", age: 25,
                                                password: "fixture-password")
        try store.mutate(id: draft.id) { $0.lastError = RegistrationCoordinator.deactivatedAccountMessage }
        let original = try #require(store.accounts.first)
        let aliases = store.emailAliases
        let sidecar = RegistrationBatchState.fileURL(for: file)
        try RegistrationBatchState(totalCount: 2, completedCount: 0, remainingEmails: ["tail@icloud.com"],
                                   blockedAccountIDs: [draft.id], removedBlockedAccountIDs: [draft.id]).save(to: sidecar)
        let queue = try Data(contentsOf: sidecar)
        #expect(throws: AccountStoreError.accountBusy) { try store.deleteAccount(id: draft.id, protectedIDs: []) }

        try store.deleteDeactivatedRegistration(id: draft.id, expectedError: RegistrationCoordinator.deactivatedAccountMessage, protectedIDs: [])
        let snapshotID = try #require(store.deletedAccounts.first?.id)
        #expect(store.deletedAccounts.first?.account == original && store.accounts.isEmpty)
        #expect(try Data(contentsOf: sidecar) == queue)
        #expect(store.emailAliases == aliases)
        try store.restoreDeletedAccount(id: snapshotID, protectedIDs: [])

        #expect(store.accounts == [original] && store.deletedAccounts.isEmpty && store.emailAliases == aliases)
        #expect((try Data(contentsOf: sidecar)) == queue)
        let reloaded = AccountStore(fileURL: file)
        try reloaded.load()
        #expect(reloaded.accounts == [original] && reloaded.emailAliases == aliases)
    }

    @Test func protectedRestoreAndBusyDeletionDoNotChangeState() throws {
        let file = temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let group = AccountGroup(name: "Group")
        let original = account(groupID: group.id)
        try write(PersistedAccountData(groups: [group], accounts: [original]), to: file)
        let store = AccountStore(fileURL: file)
        try store.load()
        #expect(throws: AccountStoreError.accountBusy) { try store.deleteAccount(id: original.id, protectedIDs: [original.id]) }
        #expect(throws: AccountStoreError.accountBusy) { try store.deleteGroup(id: group.id, protectedIDs: [original.id]) }
        #expect(store.accounts == [original] && store.deletedAccounts.isEmpty)
        try store.deleteAccount(id: original.id, protectedIDs: [])
        let snapshot = try #require(store.deletedAccounts.first)

        #expect(throws: AccountStoreError.accountBusy) {
            try store.restoreDeletedAccount(id: snapshot.id, protectedIDs: [original.id])
        }

        #expect(store.accounts.isEmpty && store.deletedAccounts == [snapshot] && store.groups == [group])
    }

    @Test(arguments: ["accountDelete", "groupDelete", "blockedDelete", "restore", "permanentDelete"])
    func failedWritesDoNotPublishAccountsGroupsTrashAliasesOrSelection(action: String) throws {
        let file = temporaryFile()
        let directory = file.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }
        let group = AccountGroup(name: "Group", tag: "keep")
        var original = account(groupID: group.id)
        if action == "blockedDelete" {
            original.groupID = nil
            original.pendingRegistration = .init(fullName: "Fixture User", age: 25)
            original.status = .needsRecovery
            original.lastError = RegistrationCoordinator.deactivatedAccountMessage
        }
        let alias = EmailAlias(email: original.email, status: .used, accountID: original.id)
        try write(PersistedAccountData(groups: [group], accounts: [original], emailAliases: [alias]), to: file)
        let store = AccountStore(fileURL: file)
        try store.load()
        if action == "restore" || action == "permanentDelete" {
            try store.deleteAccount(id: original.id, protectedIDs: [])
        }
        let accounts = store.accounts
        let groups = store.groups
        let aliases = store.emailAliases
        let trash = store.deletedAccounts
        let selectedID = store.selectedID
        try FileManager.default.removeItem(at: directory)
        try Data("blocked-directory".utf8).write(to: directory)

        #expect(throws: (any Error).self) {
            switch action {
            case "accountDelete": try store.deleteAccount(id: original.id, protectedIDs: [])
            case "groupDelete": try store.deleteGroup(id: group.id, protectedIDs: [])
            case "blockedDelete": try store.deleteDeactivatedRegistration(id: original.id, expectedError: RegistrationCoordinator.deactivatedAccountMessage, protectedIDs: [])
            case "restore": try store.restoreDeletedAccount(id: #require(trash.first?.id), protectedIDs: [])
            default: try store.removeDeletedAccountPermanently(id: #require(trash.first?.id))
            }
        }

        #expect(store.accounts == accounts && store.groups == groups && store.emailAliases == aliases)
        #expect(store.deletedAccounts == trash && store.selectedID == selectedID)
    }

    @Test func permanentDeletionOnlyRemovesSnapshotAndKeepsConsumedAliasAndLiveAccount() throws {
        let file = temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let group = AccountGroup(name: "Keep", tag: "keep")
        let live = account(groupID: group.id)
        let removed = account("removed@icloud.com")
        let snapshots = [DeletedAccountSnapshot(account: live, group: group, deletedAt: date),
                         DeletedAccountSnapshot(account: removed, deletedAt: date)]
        let aliases = [EmailAlias(email: live.email, status: .used, accountID: live.id),
                       EmailAlias(email: removed.email, status: .used, accountID: removed.id)]
        try write(PersistedAccountData(groups: [group], accounts: [live], emailAliases: aliases, deletedAccounts: snapshots), to: file)
        let store = AccountStore(fileURL: file)
        try store.load()

        try store.removeDeletedAccountPermanently(id: snapshots[0].id)
        try store.removeDeletedAccountPermanently(id: snapshots[0].id)

        #expect(store.accounts == [live] && store.groups == [group] && store.emailAliases == aliases)
        #expect(store.selectedID == live.id && store.deletedAccounts == [snapshots[1]])
        let reloaded = AccountStore(fileURL: file)
        try reloaded.load()
        #expect(reloaded.accounts == [live] && reloaded.deletedAccounts == [snapshots[1]])
        #expect(reloaded.emailAliases == aliases)
    }
}
