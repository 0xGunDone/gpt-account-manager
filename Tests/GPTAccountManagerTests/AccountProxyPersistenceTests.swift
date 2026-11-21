import Foundation
import Testing
@testable import GPTAccountManager

@MainActor
@Suite struct AccountProxyPersistenceTests {
    @Test func existingAccountWithoutProxyDecodesAndAssignedProxyRoundTrips() throws {
        var account = AccountRecord(credential: .init(
            email: "fixture@example.com", password: "fixture", totpSecret: "JBSWY3DPEHPK3PXP"))
        let original = try JSONEncoder().encode(account)
        let json = try #require(JSONSerialization.jsonObject(with: original) as? [String: Any])
        #expect(json["proxy"] == nil)
        #expect(try JSONDecoder().decode(AccountRecord.self, from: original).proxy == nil)

        account.proxy = AccountProxy(scheme: .socks5, host: "127.0.0.1", port: 1080,
                                     username: "fixture-user", password: "fixture-pass")
        #expect(try JSONDecoder().decode(AccountRecord.self, from: JSONEncoder().encode(account)) == account)
    }

    @Test func registrationPersistsChosenProxyAndRejectsChangingDraftAssignment() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AccountStore(fileURL: directory.appendingPathComponent("accounts.json"))
        let proxy = AccountProxy(scheme: .https, host: "proxy.example.com", port: 443,
                                 username: "fixture-user", password: "fixture-pass")
        let draft = try store.beginRegistration(
            email: "new@icloud.com", fullName: "Test Person", age: 28, password: "fixture", proxy: proxy)
        #expect(draft.proxy == proxy)
        let reloaded = AccountStore(fileURL: store.fileURL)
        try reloaded.load()
        #expect(reloaded.accounts.first?.proxy == proxy)
        #expect(throws: AccountStoreError.accountBusy) {
            try store.mutate(id: draft.id) { $0.proxy = nil }
        }
        #expect(store.accounts.first?.proxy == proxy)
    }
}
