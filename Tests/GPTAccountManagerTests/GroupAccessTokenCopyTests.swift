import Foundation
import Testing
@testable import GPTAccountManager

@Suite struct GroupAccessTokenCopyTests {
    @Test func copyKeepsSnapshotOrderAndRejectsChangedIdentityOrPendingCredentials() {
        var first = AccountRecord(credential: .init(
            email: "first@example.com", password: "fixture-password", totpSecret: "JBSWY3DPEHPK3PXP"))
        first.status = .ready
        first.accessToken = "cached-fixture-token"
        var second = first
        second.id = UUID()
        second.email = "second@example.com"
        let snapshot = [first, second]

        var refreshed = first
        refreshed.accessToken = "refreshed-fixture-token"
        #expect(GroupAccessTokenCopy.currentAccounts(from: snapshot, in: [second, refreshed]) == [refreshed, second])

        let changes: [(inout AccountRecord) -> Void] = [
            { $0.email = "other@example.com" },
            { $0.browserStoreID = UUID() },
            { $0.password = "changed-fixture-password" },
            { $0.totpSecret = "MZXW6YTBOI======" },
            { $0.proxy = AccountProxy(scheme: .http, host: "127.0.0.1", port: 8080) },
            { $0.groupID = UUID() },
            { $0.status = .failed },
            { $0.pendingPassword = "pending-fixture-password" },
            { $0.pendingAccessChange = .password },
            { $0.pendingRegistration = .init(fullName: "Fixture Person", age: 28) },
            { $0.rotationStage = .awaitingCleanLogin },
            { $0.pendingTOTPSecret = "MZXW6YTBOI======" }
        ]
        for change in changes {
            var changed = first
            change(&changed)
            #expect(GroupAccessTokenCopy.currentAccounts(from: [first], in: [changed]).isEmpty)
        }
        #expect(GroupAccessTokenCopy.currentAccounts(from: [first], in: []).isEmpty)
    }
}
