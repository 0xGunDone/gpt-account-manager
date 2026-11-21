import AppKit
import Foundation
import Testing
import WebKit
@testable import GPTAccountManager

@MainActor
@Suite(.serialized)
struct ManualEmailAliasUsageTests {
    private let ownerID = UUID()

    private func makeStore(aliases: [EmailAlias]? = nil) throws -> AccountStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let file = directory.appendingPathComponent("accounts.json")
        let group = AccountGroup(name: "Fixture group", tag: "keep")
        var owner = AccountRecord(credential: .init(email: "existing@icloud.com", password: "fixture", totpSecret: ""))
        owner.id = ownerID
        owner.groupID = group.id
        let other = AccountRecord(credential: .init(email: "other@example.com", password: "fixture", totpSecret: ""))
        let removed = AccountRecord(credential: .init(email: "removed@example.com", password: "fixture", totpSecret: ""))
        let snapshot = DeletedAccountSnapshot(account: removed, group: group,
                                              deletedAt: Date(timeIntervalSince1970: 1_800_000_000))
        let payload = PersistedAccountData(
            groups: [group], accounts: [owner, other],
            emailAliases: aliases ?? [EmailAlias(email: "manual@icloud.com"), EmailAlias(email: "free@icloud.com"),
                                      EmailAlias(email: owner.email, status: .used, accountID: owner.id)],
            deletedAccounts: [snapshot])
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(payload).write(to: file)
        let store = AccountStore(fileURL: file)
        try store.load()
        store.selectedID = other.id
        return store
    }

    @Test func markingAvailableAliasPersistsWithoutChangingOtherRecords() throws {
        let store = try makeStore()
        defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
        let accounts = store.accounts
        let groups = store.groups
        let trash = store.deletedAccounts
        let selectedID = store.selectedID
        var aliases = store.emailAliases
        aliases[0].status = .used

        try store.markEmailAliasUsed(id: aliases[0].id)

        #expect(store.emailAliases == aliases)
        #expect(store.accounts == accounts && store.groups == groups && store.deletedAccounts == trash)
        #expect(store.selectedID == selectedID)
        let reloaded = AccountStore(fileURL: store.fileURL)
        try reloaded.load()
        #expect(reloaded.emailAliases == aliases)
        #expect(reloaded.accounts == accounts && reloaded.groups == groups && reloaded.deletedAccounts == trash)
    }

    @Test func markedAliasCannotBeReservedOrSelectedForRegistration() throws {
        let store = try makeStore()
        defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
        let alias = store.emailAliases[0]
        let free = store.emailAliases[1]
        try store.markEmailAliasUsed(id: alias.id)
        let bytes = try Data(contentsOf: store.fileURL)
        let accounts = store.accounts
        let aliases = store.emailAliases

        #expect(throws: AccountStoreError.emailAliasUnavailable) {
            try store.reserveEmailChange(id: ownerID, alias: alias.email)
        }
        _ = NSApplication.shared
        let mailbox = MailRuMailbox(expectedMailbox: "fixture@mail.ru", webViewFactory: { configuration in
            configuration.websiteDataStore = .nonPersistent()
            return WKWebView(frame: .zero, configuration: configuration)
        })
        let coordinator = RegistrationCoordinator(
            store: store, browser: ChatGPTAutomation(sessionManager: WebSessionManager()), mailbox: mailbox)
        #expect(throws: AccountStoreError.emailAliasUnavailable) {
            try coordinator.registrationEmails(startingWith: alias.email, count: 1)
        }
        #expect(try coordinator.registrationEmails(startingWith: free.email, count: 1) == [free.email])
        #expect(throws: RegistrationBatchError.insufficientEmails(available: 1)) {
            try coordinator.registrationEmails(startingWith: free.email, count: 2)
        }
        #expect(mailbox.webView.url == nil && !coordinator.isRunning)
        #expect(store.accounts == accounts && store.emailAliases == aliases)
        #expect(try Data(contentsOf: store.fileURL) == bytes)
    }

    @Test func reservedAndMissingAliasesAreRejectedWithoutChangingStateOrFile() throws {
        let store = try makeStore()
        defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
        let pending = try store.reserveEmailChange(id: ownerID, alias: store.emailAliases[0].email)
        let accounts = store.accounts
        let groups = store.groups
        let aliases = store.emailAliases
        let trash = store.deletedAccounts
        let selectedID = store.selectedID
        let bytes = try Data(contentsOf: store.fileURL)

        for id in [pending.aliasID, UUID()] {
            #expect(throws: AccountStoreError.emailAliasUnavailable) { try store.markEmailAliasUsed(id: id) }
            #expect(store.accounts == accounts && store.groups == groups && store.emailAliases == aliases)
            #expect(store.deletedAccounts == trash && store.selectedID == selectedID)
            #expect(try Data(contentsOf: store.fileURL) == bytes)
        }
    }

    @Test func failedSaveDoesNotPublishAliasMutation() throws {
        let store = try makeStore()
        let directory = store.fileURL.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }
        let accounts = store.accounts
        let groups = store.groups
        let aliases = store.emailAliases
        let trash = store.deletedAccounts
        let selectedID = store.selectedID
        let blocker = Data("blocked-directory".utf8)
        try FileManager.default.removeItem(at: directory)
        try blocker.write(to: directory)

        #expect(throws: (any Error).self) { try store.markEmailAliasUsed(id: aliases[0].id) }

        #expect(store.accounts == accounts && store.groups == groups && store.emailAliases == aliases)
        #expect(store.deletedAccounts == trash && store.selectedID == selectedID)
        #expect(try Data(contentsOf: directory) == blocker)
    }

    @Test func usedAliasesAreIdempotentAndPreserveOwnersWithoutWriting() throws {
        let aliases = [EmailAlias(email: "existing@icloud.com", status: .used, accountID: ownerID),
                       EmailAlias(email: "manual@icloud.com", status: .used)]
        let store = try makeStore(aliases: aliases)
        let directory = store.fileURL.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }
        let accounts = store.accounts
        let groups = store.groups
        let trash = store.deletedAccounts
        let selectedID = store.selectedID
        let bytes = try Data(contentsOf: store.fileURL)

        for alias in aliases {
            try store.markEmailAliasUsed(id: alias.id)
            try store.markEmailAliasUsed(id: alias.id)
        }
        #expect(try Data(contentsOf: store.fileURL) == bytes)
        try FileManager.default.removeItem(at: directory)
        let blocker = Data("blocked-directory".utf8)
        try blocker.write(to: directory)
        for alias in aliases { try store.markEmailAliasUsed(id: alias.id) }

        #expect(store.emailAliases == aliases && store.accounts == accounts && store.groups == groups)
        #expect(store.deletedAccounts == trash && store.selectedID == selectedID)
        #expect(try Data(contentsOf: directory) == blocker)
    }
}
