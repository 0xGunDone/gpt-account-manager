import Foundation
import Testing
@testable import GPTAccountManager

@MainActor
struct PasswordGroupLaunchTests {
    @Test func requiresExplicitUniqueGroupID() throws {
        let id = UUID()
        #expect(try PasswordGroupLaunch.groupID(arguments: ["app"]) == nil)
        #expect(try PasswordGroupLaunch.groupID(arguments: ["app", PasswordGroupLaunch.flag, id.uuidString]) == id)
        for arguments in [["app", PasswordGroupLaunch.flag],
                          ["app", PasswordGroupLaunch.flag, "test"],
                          ["app", PasswordGroupLaunch.flag, id.uuidString, PasswordGroupLaunch.flag, id.uuidString]] {
            #expect(throws: PasswordGroupLaunch.LaunchError.invalidArguments) {
                try PasswordGroupLaunch.groupID(arguments: arguments)
            }
        }
    }

    @Test func snapshotContainsOnlyRequestedGroupAndAllowsPasswordRecovery() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = AccountStore(fileURL: dir.appendingPathComponent("accounts.json"))
        try store.merge([.init(email: "one@example.com", password: "fixture", totpSecret: "JBSWY3DPEHPK3PXP"),
                         .init(email: "other@example.com", password: "fixture", totpSecret: "JBSWY3DPEHPK3PXP")])
        let group = try store.createGroup(name: "test", tag: nil)
        let id = try #require(store.accounts.first?.id)
        try store.moveAccounts(ids: [id], to: group.id, protectedIDs: [])
        try store.mutate(id: id) { $0.pendingAccessChange = .password }
        #expect(try PasswordGroupLaunch.accountIDs(groupID: group.id, store: store) == [id])
        try store.mutate(id: id) { $0.pendingAccessChange = .passwordAndTwoFA }
        #expect(throws: PasswordGroupLaunch.LaunchError.conflictingOperation) {
            try PasswordGroupLaunch.accountIDs(groupID: group.id, store: store)
        }
        #expect(throws: PasswordGroupLaunch.LaunchError.missingGroup) {
            try PasswordGroupLaunch.accountIDs(groupID: UUID(), store: store)
        }
    }
}
