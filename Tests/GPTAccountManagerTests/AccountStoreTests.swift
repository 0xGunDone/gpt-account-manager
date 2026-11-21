import Foundation
import Testing
@testable import GPTAccountManager

@MainActor
@Suite struct AccountStoreTests {
    private func temporaryFile() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("accounts.json")
    }

    private func populatedStore(fileURL: URL? = nil) throws -> AccountStore {
        let resolvedURL: URL
        if let fileURL {
            resolvedURL = fileURL
        } else {
            resolvedURL = try temporaryFile()
        }
        let store = AccountStore(fileURL: resolvedURL)
        try store.merge([
            .init(email: "one@example.com", password: "p1", totpSecret: "JBSWY3DPEHPK3PXP"),
            .init(email: "two@example.com", password: "p2", totpSecret: "KRUGS4ZANFZSAYJA"),
        ])
        return store
    }

    @Test func groupNamesAreTrimmedAndUniqueIgnoringCase() throws {
        let store = AccountStore(fileURL: try temporaryFile())
        let group = try store.createGroup(name: "  Основные  ", tag: " paid ")
        #expect(group.name == "Основные")
        #expect(group.tag == "paid")
        #expect(throws: AccountStoreError.duplicateGroupName) {
            try store.createGroup(name: "основные", tag: nil)
        }
    }

    @Test func moveToGroupAndBackToUngroupedIsAtomic() throws {
        let store = try populatedStore()
        let group = try store.createGroup(name: "Пачка", tag: nil)
        let ids = Set(store.accounts.map(\.id))
        try store.moveAccounts(ids: ids, to: group.id, protectedIDs: [])
        #expect(store.accounts.allSatisfy { $0.groupID == group.id })
        try store.moveAccounts(ids: ids, to: nil, protectedIDs: [])
        #expect(store.accounts.allSatisfy { $0.groupID == nil })
    }

    @Test func deleteGroupDeletesMembersButKeepsUngroupedAccounts() throws {
        let store = try populatedStore()
        let group = try store.createGroup(name: "Удалить", tag: nil)
        let groupedID = try #require(store.accounts.first?.id)
        try store.moveAccounts(ids: [groupedID], to: group.id, protectedIDs: [])
        try store.deleteGroup(id: group.id, protectedIDs: [])
        #expect(!store.groups.contains(where: { $0.id == group.id }))
        #expect(!store.accounts.contains(where: { $0.id == groupedID }))
        #expect(store.accounts.count == 1)
    }

    @Test func deletingSelectedAccountSelectsFirstRemainingAccountOrNil() throws {
        let store = try populatedStore()
        let selectedID = try #require(store.accounts.first?.id)
        let remainingID = try #require(store.accounts.last?.id)
        store.selectedID = selectedID

        try store.deleteAccount(id: selectedID, protectedIDs: [])
        #expect(store.selectedID == remainingID)

        try store.deleteAccount(id: remainingID, protectedIDs: [])
        #expect(store.selectedID == nil)
    }

    @Test func deletingUnselectedAccountKeepsSelection() throws {
        let store = try populatedStore()
        let deletedID = try #require(store.accounts.first?.id)
        let selectedID = try #require(store.accounts.last?.id)
        store.selectedID = selectedID

        try store.deleteAccount(id: deletedID, protectedIDs: [])
        #expect(store.selectedID == selectedID)
    }

    @Test func deletingGroupContainingSelectedAccountSelectsFirstRemainingAccountOrNil() throws {
        let store = try populatedStore()
        let firstGroup = try store.createGroup(name: "Первая", tag: nil)
        let selectedID = try #require(store.accounts.first?.id)
        let remainingID = try #require(store.accounts.last?.id)
        try store.moveAccounts(ids: [selectedID], to: firstGroup.id, protectedIDs: [])
        store.selectedID = selectedID

        try store.deleteGroup(id: firstGroup.id, protectedIDs: [])
        #expect(store.selectedID == remainingID)

        let secondGroup = try store.createGroup(name: "Вторая", tag: nil)
        try store.moveAccounts(ids: [remainingID], to: secondGroup.id, protectedIDs: [])
        try store.deleteGroup(id: secondGroup.id, protectedIDs: [])
        #expect(store.selectedID == nil)
    }

    @Test func failedDeletionDoesNotPublishCandidateSelection() throws {
        let file = try temporaryFile()
        let store = try populatedStore(fileURL: file)
        let selectedID = try #require(store.accounts.first?.id)
        store.selectedID = selectedID
        let originalGroups = store.groups
        let originalAccounts = store.accounts

        let directory = file.deletingLastPathComponent()
        try FileManager.default.removeItem(at: directory)
        try Data("block".utf8).write(to: directory)

        #expect(throws: (any Error).self) {
            try store.deleteAccount(id: selectedID, protectedIDs: [])
        }
        #expect(store.groups == originalGroups)
        #expect(store.accounts.map(\.id) == originalAccounts.map(\.id))
        #expect(store.selectedID == selectedID)
    }

    @Test func busyAccountCannotMoveOrDelete() throws {
        let store = try populatedStore()
        let id = try #require(store.accounts.first?.id)
        #expect(throws: AccountStoreError.accountBusy) {
            try store.moveAccounts(ids: [id], to: nil, protectedIDs: [id])
        }
        #expect(throws: AccountStoreError.accountBusy) {
            try store.deleteAccount(id: id, protectedIDs: [id])
        }
    }

    @Test func externalMailboxRemainsLocalAcrossCredentialRefreshAndTrashRestore() throws {
        let original = try populatedStore()
        defer { try? FileManager.default.removeItem(at: original.fileURL.deletingLastPathComponent()) }
        let store = AccountStore(fileURL: original.fileURL)
        try store.load()
        let account = try #require(store.accounts.first)
        let otherAccount = try #require(store.accounts.last)
        #expect(account.externalMailbox == nil)

        let mailbox = try ExternalMailboxConfiguration(
            address: "inbox@example.com", codeURL: "https://mail.example.com/code?token=fixture")
        try store.updateExternalMailbox(id: account.id, configuration: mailbox, protectedIDs: [])
        #expect(ImportExportService.serialize(store.accounts) == ImportExportService.serialize(original.accounts))
        #expect(throws: AccountStoreError.accountBusy) {
            try store.updateExternalMailbox(id: account.id, configuration: nil, protectedIDs: [account.id])
        }
        try store.updateCredentials(id: account.id, credential: .init(
            email: "ONE@example.com", password: "refreshed", totpSecret: account.totpSecret), protectedIDs: [])
        try store.deleteAccount(id: account.id, protectedIDs: [])
        try store.load()
        let snapshotID = try #require(store.deletedAccounts.first?.id)
        try store.restoreDeletedAccount(id: snapshotID, protectedIDs: [])

        try store.load()
        #expect(store.accounts.first { $0.id == account.id }?.externalMailbox == mailbox)
        #expect(store.accounts.first { $0.id == otherAccount.id } == otherAccount)
        try store.updateExternalMailbox(id: account.id, configuration: nil, protectedIDs: [])
        try store.load()
        #expect(store.accounts.first { $0.id == account.id }?.externalMailbox == nil)

        try store.updateExternalMailbox(id: account.id, configuration: mailbox, protectedIDs: [])
        try store.updateCredentials(id: account.id, credential: .init(
            email: "changed@example.com", password: "refreshed", totpSecret: account.totpSecret), protectedIDs: [])
        try store.load()
        #expect(store.accounts.first { $0.id == account.id }?.externalMailbox == nil)
    }

    @Test func accountAndGroupTagsPersistAfterReload() throws {
        let file = try temporaryFile()
        let store = try populatedStore(fileURL: file)
        let group = try store.createGroup(name: "Пачка", tag: nil)
        let accountID = try #require(store.accounts.first?.id)

        try store.updateGroup(id: group.id, name: "Пачка", tag: " paid ")
        try store.setAccountTag(id: accountID, tag: " main ")

        let reloaded = AccountStore(fileURL: file)
        try reloaded.load()
        #expect(reloaded.groups[0].tag == "paid")
        #expect(reloaded.accounts.first(where: { $0.id == accountID })?.tag == "main")
    }

    @Test func deletingSingleAccountLeavesItsGroup() throws {
        let store = try populatedStore()
        let group = try store.createGroup(name: "Оставить", tag: nil)
        let id = try #require(store.accounts.first?.id)
        try store.moveAccounts(ids: [id], to: group.id, protectedIDs: [])

        try store.deleteAccount(id: id, protectedIDs: [])

        #expect(store.groups.contains(where: { $0.id == group.id }))
        #expect(!store.accounts.contains(where: { $0.id == id }))
    }

    @Test func mergeUpdatesCredentialsWithoutChangingIdentity() throws {
        let file = try temporaryFile()
        let store = AccountStore(fileURL: file)
        try store.merge([.init(email: "A@Example.com", password: "old", totpSecret: "JBSWY3DPEHPK3PXP")])
        let original = try #require(store.accounts.first)

        try store.merge([.init(email: "a@example.com", password: "new", totpSecret: "KRUGS4ZANFZSAYJA")])
        #expect(store.accounts.count == 1)
        #expect(store.accounts[0].id == original.id)
        #expect(store.accounts[0].browserStoreID == original.browserStoreID)
        #expect(store.accounts[0].password == "new")
    }

    @Test func mergeDuplicatePreservesExistingTwoFASecret() throws {
        let store = AccountStore(fileURL: try temporaryFile())
        try store.merge([
            .init(
                email: "one@example.com",
                password: "old-password",
                totpSecret: "KRUGS4ZANFZSAYJA")
        ])

        try store.merge([
            .init(
                email: "ONE@example.com",
                password: "new-password",
                totpSecret: "MFRGGZDFMZTWQ2LK")
        ])

        #expect(store.accounts.count == 1)
        #expect(store.accounts[0].password == "new-password")
        #expect(store.accounts[0].totpSecret == "KRUGS4ZANFZSAYJA")
    }

    @Test func credentialEditPreservesMetadataAndResetsOnlyChangedLoginSession() throws {
        let store = try populatedStore()
        let id = try #require(store.accounts.first?.id)
        let group = try store.createGroup(name: "Основные", tag: nil)
        try store.moveAccounts(ids: [id], to: group.id, protectedIDs: [])
        try store.setAccountTag(id: id, tag: "main")
        try store.mutate(id: id) {
            $0.planLabel = "plus"
            $0.lastCheckedAt = Date(timeIntervalSince1970: 1_700_000_000)
        }
        let original = try #require(store.accounts.first(where: { $0.id == id }))

        try store.updateCredentials(
            id: id,
            credential: .init(
                email: "one@example.com",
                password: "new-password",
                totpSecret: "MFRGGZDFMZTWQ2LK"),
            protectedIDs: [])
        #expect(store.accounts.first(where: { $0.id == id })?.browserStoreID ==
            original.browserStoreID)

        try store.updateCredentials(
            id: id,
            credential: .init(
                email: "changed@example.com",
                password: "new-password",
                totpSecret: "MFRGGZDFMZTWQ2LK"),
            protectedIDs: [])

        let changed = try #require(store.accounts.first(where: { $0.id == id }))
        #expect(changed.id == original.id)
        #expect(changed.groupID == group.id)
        #expect(changed.tag == "main")
        #expect(changed.planLabel == "plus")
        #expect(changed.lastCheckedAt == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(changed.browserStoreID != original.browserStoreID)
    }

    @Test func credentialEditRejectsDuplicateLogin() throws {
        let store = try populatedStore()
        let first = try #require(store.accounts.first)
        let second = try #require(store.accounts.last)

        #expect(throws: AccountStoreError.duplicateAccountEmail) {
            try store.updateCredentials(
                id: first.id,
                credential: .init(
                    email: second.email.uppercased(),
                    password: "password",
                    totpSecret: "JBSWY3DPEHPK3PXP"),
                protectedIDs: [])
        }
    }

    @Test func credentialEditRejectsRecoveryAndProtectedAccounts() throws {
        let store = try populatedStore()
        let id = try #require(store.accounts.first?.id)
        let credential = ImportedCredential(
            email: "changed@example.com",
            password: "password",
            totpSecret: "JBSWY3DPEHPK3PXP")

        #expect(throws: AccountStoreError.accountBusy) {
            try store.updateCredentials(
                id: id,
                credential: credential,
                protectedIDs: [id])
        }

        try store.mutate(id: id) {
            $0.pendingTOTPSecret = "MFRGGZDFMZTWQ2LK"
            $0.rotationStage = .awaitingCleanLogin
        }
        #expect(throws: AccountStoreError.rotationRecoveryActive) {
            try store.updateCredentials(
                id: id,
                credential: credential,
                protectedIDs: [])
        }
    }

    @Test func failedCredentialEditDoesNotPublishCandidateState() throws {
        let file = try temporaryFile()
        let store = try populatedStore(fileURL: file)
        let original = try #require(store.accounts.first)
        let directory = file.deletingLastPathComponent()
        try FileManager.default.removeItem(at: directory)
        try Data("block".utf8).write(to: directory)

        #expect(throws: (any Error).self) {
            try store.updateCredentials(
                id: original.id,
                credential: .init(
                    email: "changed@example.com",
                    password: "new-password",
                    totpSecret: "MFRGGZDFMZTWQ2LK"),
                protectedIDs: [])
        }
        #expect(store.accounts.first == original)
    }

    @Test func pendingRotationSurvivesReload() throws {
        let file = try temporaryFile()
        let store = AccountStore(fileURL: file)
        try store.merge([.init(email: "a@example.com", password: "pw", totpSecret: "JBSWY3DPEHPK3PXP")])
        let id = try #require(store.accounts.first?.id)
        try store.mutate(id: id) {
            $0.pendingTOTPSecret = "KRUGS4ZANFZSAYJA"
            $0.rotationStage = .pendingSecretCaptured
            $0.status = .needsRecovery
        }

        let reloaded = AccountStore(fileURL: file)
        try reloaded.load()
        #expect(reloaded.accounts[0].pendingTOTPSecret == "KRUGS4ZANFZSAYJA")
        #expect(reloaded.accounts[0].rotationStage == .pendingSecretCaptured)
    }

    @Test func interruptedCheckingStatusDoesNotSurviveReload() throws {
        let file = try temporaryFile()
        let store = AccountStore(fileURL: file)
        try store.merge([
            .init(
                email: "a@example.com",
                password: "password",
                totpSecret: "JBSWY3DPEHPK3PXP"),
        ])
        let id = try #require(store.accounts.first?.id)
        try store.mutate(id: id) { $0.status = .checking }

        let reloaded = AccountStore(fileURL: file)
        try reloaded.load()

        #expect(reloaded.accounts[0].status == .unchecked)
    }

    @Test func mergeRejectsCredentialReplacementDuringRotationRecovery() throws {
        let file = try temporaryFile()
        let store = AccountStore(fileURL: file)
        try store.merge([
            .init(
                email: "a@example.com",
                password: "old-password",
                totpSecret: "JBSWY3DPEHPK3PXP"),
        ])
        let id = try #require(store.accounts.first?.id)
        try store.mutate(id: id) {
            $0.pendingTOTPSecret = "KRUGS4ZANFZSAYJA"
            $0.rotationStage = .pendingSecretCaptured
            $0.status = .needsRecovery
        }

        #expect(throws: (any Error).self) {
            try store.merge([
                .init(
                    email: "A@example.com",
                    password: "replacement-password",
                    totpSecret: "MFRGGZDFMZTWQ2LK"),
            ])
        }
        #expect(store.accounts[0].password == "old-password")
        #expect(store.accounts[0].totpSecret == "JBSWY3DPEHPK3PXP")
        #expect(store.accounts[0].pendingTOTPSecret == "KRUGS4ZANFZSAYJA")
    }

    @Test func failedPersistenceDoesNotPublishCandidateState() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let blockingFile = directory.appendingPathComponent("not-a-directory")
        try Data("block".utf8).write(to: blockingFile)
        let store = AccountStore(
            fileURL: blockingFile.appendingPathComponent("accounts.json"))

        #expect(throws: (any Error).self) {
            try store.merge([
                .init(
                    email: "a@example.com",
                    password: "password",
                    totpSecret: "JBSWY3DPEHPK3PXP"),
            ])
        }
        #expect(store.accounts.isEmpty)
        #expect(store.selectedID == nil)
    }

    @Test func credentialFileAndContainingDirectoryAreOwnerOnly() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let file = directory.appendingPathComponent("accounts.json")
        let store = AccountStore(fileURL: file)

        try store.merge([
            .init(
                email: "a@example.com",
                password: "password",
                totpSecret: "JBSWY3DPEHPK3PXP"),
        ])

        let directoryAttributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        let fileAttributes = try FileManager.default.attributesOfItem(atPath: file.path)
        let directoryMode = try #require(
            directoryAttributes[.posixPermissions] as? NSNumber)
        let fileMode = try #require(fileAttributes[.posixPermissions] as? NSNumber)
        #expect(directoryMode.intValue == 0o700)
        #expect(fileMode.intValue == 0o600)
    }

    @Test func loadHardensPermissionsFromOlderAppVersions() throws {
        let file = try temporaryFile()
        let store = AccountStore(fileURL: file)
        try store.merge([
            .init(
                email: "a@example.com",
                password: "password",
                totpSecret: "JBSWY3DPEHPK3PXP"),
        ])
        let directory = file.deletingLastPathComponent()
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: directory.path)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644],
            ofItemAtPath: file.path)

        let reloaded = AccountStore(fileURL: file)
        try reloaded.load()

        let directoryAttributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        let fileAttributes = try FileManager.default.attributesOfItem(atPath: file.path)
        let directoryMode = try #require(
            directoryAttributes[.posixPermissions] as? NSNumber)
        let fileMode = try #require(fileAttributes[.posixPermissions] as? NSNumber)
        #expect(directoryMode.intValue == 0o700)
        #expect(fileMode.intValue == 0o600)
    }

    @Test func legacyArrayLoadsWithoutLosingRotationRecovery() throws {
        let file = try temporaryFile()
        var legacy = AccountRecord(credential: .init(
            email: "legacy@example.com",
            password: "password",
            totpSecret: "JBSWY3DPEHPK3PXP"))
        legacy.pendingTOTPSecret = "KRUGS4ZANFZSAYJA"
        legacy.rotationStage = .pendingSecretCaptured
        legacy.status = .needsRecovery
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode([legacy]).write(to: file)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: file.path)

        let store = AccountStore(fileURL: file)
        try store.load()

        #expect(store.groups.isEmpty)
        #expect(store.accounts == [legacy])
        #expect(store.accounts[0].groupID == nil)
        #expect(store.accounts[0].tag == nil)
    }

    @Test func versionedGroupsAndMembershipSurviveReload() throws {
        let file = try temporaryFile()
        let group = AccountGroup(name: "Основные", tag: "paid")
        var account = AccountRecord(credential: .init(
            email: "one@example.com",
            password: "password",
            totpSecret: "JBSWY3DPEHPK3PXP"))
        account.groupID = group.id
        account.tag = "priority"
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(PersistedAccountData(
            groups: [group], accounts: [account])).write(to: file)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: file.path)

        let store = AccountStore(fileURL: file)
        try store.load()

        #expect(store.groups == [group])
        #expect(store.accounts == [account])
    }

    @Test func unsupportedVersionedDataThrowsUnsupportedVersion() throws {
        let file = try temporaryFile()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(PersistedAccountData(
            version: PersistedAccountData.currentVersion + 1,
            groups: [],
            accounts: [])).write(to: file)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: file.path)

        let store = AccountStore(fileURL: file)

        #expect(throws: AccountStoreError.unsupportedVersion) {
            try store.load()
        }
    }

    @Test func failedReloadLeavesLoadedStateUnchanged() throws {
        let file = try temporaryFile()
        let group = AccountGroup(name: "Основные")
        var account = AccountRecord(credential: .init(
            email: "one@example.com",
            password: "password",
            totpSecret: "JBSWY3DPEHPK3PXP"))
        account.groupID = group.id
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(PersistedAccountData(
            groups: [group], accounts: [account])).write(to: file)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: file.path)

        let store = AccountStore(fileURL: file)
        try store.load()
        let selectedID = try #require(store.selectedID)
        let loadedGroups = store.groups
        let loadedAccounts = store.accounts

        try Data("{".utf8).write(to: file)

        #expect(throws: (any Error).self) {
            try store.load()
        }
        #expect(store.groups == loadedGroups)
        #expect(store.accounts == loadedAccounts)
        #expect(store.selectedID == selectedID)
    }
}
