import Foundation
import Testing
@testable import GPTAccountManager

@MainActor
@Suite struct AccessTokenExportTests {
    private let token = "fixture-access-token.not-a-live-secret"
    private let secret = "JBSWY3DPEHPK3PXP"

    private func store() -> AccountStore {
        AccountStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("accounts.json"))
    }

    private func account(_ email: String = "fixture@example.com") -> AccountRecord {
        AccountRecord(credential: .init(email: email, password: "fixture-password", totpSecret: secret))
    }

    @Test func legacyAccountWithoutTokenDecodesAndTokenRoundTrips() throws {
        let original = account()
        let encoded = try JSONEncoder().encode(original)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "accessToken")
        let decoded = try JSONDecoder().decode(AccountRecord.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded == original && decoded.accessToken == nil && decoded.accessTokenLine == nil)
        var withToken = original
        withToken.accessToken = token
        let reloaded = try JSONDecoder().decode(AccountRecord.self, from: JSONEncoder().encode(withToken))
        #expect(reloaded.accessToken == token && reloaded.accessTokenLine == "fixture@example.com|\(token)")
    }

    @Test func exportOmitsMissingAndUnsafeValuesWithoutUsingCredentialsAsTokens() {
        var valid = account()
        valid.accessToken = token
        let missing = account("missing@example.com")
        for value in ["", " \u{00A0}", "bad|token", "bad\ntoken", "bad\rtoken", "bad\ttoken", "bad\u{0000}token", "bad\u{0085}token", "bad\u{2028}token"] {
            var invalid = account("invalid@example.com")
            invalid.accessToken = value
            #expect(invalid.accessTokenLine == nil)
            #expect(AccessTokenExport.text(for: [valid, missing, invalid]) == "fixture@example.com|\(token)")
            #expect(AccessTokenExport.count(for: [valid, missing, invalid]) == 1)
        }
        var unsafeEmail = valid
        unsafeEmail.email = "injected|email@example.com"
        #expect(unsafeEmail.accessTokenLine == nil)
        #expect(AccessTokenExport.text(for: [missing, unsafeEmail]).isEmpty)
    }

    @Test func tokenSavePersistsAndRejectsInvalidInputWithoutPublishingState() throws {
        let store = store()
        defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
        try store.merge([.init(email: "fixture@example.com", password: "fixture-password", totpSecret: secret)])
        let id = try #require(store.accounts.first?.id)
        store.selectedID = nil
        try store.saveAccessToken(id: id, accessToken: token)
        #expect(store.selectedID == nil)
        let saved = store.accounts
        let reloaded = AccountStore(fileURL: store.fileURL)
        try reloaded.load()
        #expect(reloaded.accounts == saved && reloaded.accounts.first?.accessToken == token)
        #expect(throws: AccountStoreError.invalidAccessToken) { try store.saveAccessToken(id: id, accessToken: "bad|token") }
        #expect(store.accounts == saved)
        let directory = store.fileURL.deletingLastPathComponent()
        try FileManager.default.removeItem(at: directory)
        try Data("blocked-directory".utf8).write(to: directory)
        #expect(throws: (any Error).self) { try store.saveAccessToken(id: id, accessToken: "replacement-fixture-token") }
        #expect(store.accounts == saved)
    }

    @Test func completionSavesTokenInVerifiedAccountCommit() throws {
        let store = store()
        defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
        try store.importEmailAliases("fixture@icloud.com")
        let draft = try store.beginRegistration(email: "fixture@icloud.com", fullName: "Fixture Person", age: 28, password: "fixture-password")
        var registration = try #require(draft.pendingRegistration)
        registration.phase = .verifyingLogin
        registration.passwordWasSubmitted = true
        registration.pendingSecret = secret
        try store.checkpointRegistration(id: draft.id, registration: registration)
        let proof = CleanLoginProof(passwordSubmitted: true, pendingOTPSubmitted: true, authenticatedImmediatelyAfterPendingOTP: true)
        let snapshot = SubscriptionSnapshot(signedInEmail: draft.email, planLabel: "free", activeUntil: nil, willRenew: nil)
        #expect(throws: AccountStoreError.invalidAccessToken) {
            try store.completeRegistration(id: draft.id, verifiedEmail: draft.email, secret: secret, proof: proof, snapshot: snapshot, accessToken: "bad|token")
        }
        #expect(store.accounts.first?.pendingRegistration != nil && store.groups.isEmpty)
        try store.completeRegistration(id: draft.id, verifiedEmail: draft.email, secret: secret, proof: proof, snapshot: snapshot, accessToken: token)
        let reloaded = AccountStore(fileURL: store.fileURL)
        try reloaded.load()
        #expect(reloaded.accounts.first?.accessToken == token)
        #expect(reloaded.accounts.first?.status == .ready && reloaded.accounts.first?.pendingRegistration == nil)
        #expect(reloaded.emailAliases.first?.status == .used)
    }

    @Test func registrationExportFiltersMaintainsOrderOverwritesAndUsesOwnerOnlyPermissions() throws {
        let store = store()
        defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
        try store.merge(["first", "second", "wronggroup", "unverified", "missing"].map {
            .init(email: "\($0)@example.com", password: "fixture-password", totpSecret: secret)
        })
        let group = try store.createGroup(name: "NEW-NOVOREG", tag: nil)
        for record in store.accounts {
            if record.email != "wronggroup@example.com" {
                try store.moveAccounts(ids: [record.id], to: group.id, protectedIDs: [])
            }
            try store.mutate(id: record.id) { $0.status = record.email == "unverified@example.com" ? .failed : .ready }
            if record.email != "missing@example.com" { try store.saveAccessToken(id: record.id, accessToken: token) }
        }
        let url = try store.writeRegistrationAccessTokenExport()
        #expect(url == store.fileURL.deletingLastPathComponent().appendingPathComponent("new-novoreg-access-tokens.txt"))
        let expected = "first@example.com|\(token)\nsecond@example.com|\(token)\n"
        #expect(try String(contentsOf: url, encoding: .utf8) == expected)
        #expect(try permissions(url) == 0o600)
        #expect(try permissions(url.deletingLastPathComponent()) == 0o700)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        _ = try store.writeRegistrationAccessTokenExport()
        #expect(try String(contentsOf: url, encoding: .utf8) == expected)
        #expect(try permissions(url) == 0o600)
        let first = try #require(store.accounts.first)
        try store.deleteAccount(id: first.id, protectedIDs: [])
        _ = try store.writeRegistrationAccessTokenExport()
        #expect(try String(contentsOf: url, encoding: .utf8) == "second@example.com|\(token)\n")
        let second = try #require(store.accounts.first)
        try store.moveAccounts(ids: [second.id], to: nil, protectedIDs: [])
        _ = try store.writeRegistrationAccessTokenExport()
        #expect(try Data(contentsOf: url).isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path).sorted() == ["accounts.json", "new-novoreg-access-tokens.txt"])
    }

    @Test(arguments: ["registration", "password", "accessChange", "email", "totp", "rotation"])
    func registrationExportExcludesPendingChangesEvenWithStoredToken(change: String) throws {
        let store = store()
        defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
        try store.merge([.init(email: "fixture@example.com", password: "fixture-password", totpSecret: secret)])
        let id = try #require(store.accounts.first?.id)
        let group = try store.createGroup(name: "new-novoreg", tag: nil)
        try store.moveAccounts(ids: [id], to: group.id, protectedIDs: [])
        try store.mutate(id: id) {
            $0.status = .ready
            $0.accessToken = token
            switch change {
            case "registration": $0.pendingRegistration = .init(fullName: "Fixture Person", age: 28)
            case "password": $0.pendingPassword = "replacement-password"
            case "accessChange": $0.pendingAccessChange = .password
            case "email": $0.pendingEmailChange = .init(aliasID: UUID(), originalEmail: $0.email, newEmail: "replacement@icloud.com")
            case "totp": $0.pendingTOTPSecret = secret
            default: $0.rotationStage = .awaitingCleanLogin
            }
        }
        let url = try store.writeRegistrationAccessTokenExport()
        #expect(try Data(contentsOf: url).isEmpty)
    }

    @Test(arguments: ["manualEmail", "manualPassword", "manualSecret", "merge", "mutateEmail", "mutatePassword", "mutateSecret", "browserStore"])
    func credentialReplacementInvalidatesCachedToken(change: String) throws {
        let store = store()
        defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
        let original = account()
        try store.merge([.init(email: original.email, password: original.password, totpSecret: original.totpSecret)])
        let id = try #require(store.accounts.first?.id)
        try store.saveAccessToken(id: id, accessToken: token)
        switch change {
        case "manualEmail", "manualPassword", "manualSecret":
            try store.updateCredentials(id: id, credential: .init(
                email: change == "manualEmail" ? "replacement@example.com" : original.email,
                password: change == "manualPassword" ? "replacement-password" : original.password,
                totpSecret: change == "manualSecret" ? "MZXW6YTBOI======" : original.totpSecret), protectedIDs: [])
        case "merge":
            try store.merge([.init(email: original.email, password: "replacement-password", totpSecret: original.totpSecret)])
        default:
            try store.mutate(id: id) {
                switch change {
                case "mutateEmail": $0.email = "replacement@example.com"
                case "mutatePassword": $0.password = "replacement-password"
                case "mutateSecret": $0.totpSecret = "MZXW6YTBOI======"
                default: $0.browserStoreID = UUID()
                }
            }
        }
        #expect(store.accounts.first?.accessToken == nil)
        let reloaded = AccountStore(fileURL: store.fileURL)
        try reloaded.load()
        #expect(reloaded.accounts.first?.accessToken == nil)
    }

    @Test func metadataChangesAndSameCredentialsPreserveToken() throws {
        let store = store()
        defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
        let original = account()
        let credential = ImportedCredential(email: original.email, password: original.password, totpSecret: original.totpSecret)
        try store.merge([credential])
        let id = try #require(store.accounts.first?.id)
        try store.saveAccessToken(id: id, accessToken: token)
        try store.merge([credential])
        try store.updateCredentials(id: id, credential: credential, protectedIDs: [])
        try store.mutate(id: id) { $0.email = $0.email.uppercased(); $0.status = .ready; $0.planLabel = "free" }
        #expect(store.accounts.first?.accessToken == token)
    }

    @Test func verifiedEmailChangeInvalidatesOldIdentityToken() throws {
        let store = store()
        defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
        try store.merge([.init(email: "original@example.com", password: "fixture-password", totpSecret: secret)])
        let id = try #require(store.accounts.first?.id)
        try store.saveAccessToken(id: id, accessToken: token)
        try store.importEmailAliases("replacement@icloud.com")
        var pending = try store.reserveEmailChange(id: id)
        pending.phase = .requested
        pending.requestedAt = Date()
        pending.originalUserID = "fixture-user-id"
        try store.checkpointEmailChange(id: id, change: pending)
        pending.phase = .confirming
        try store.checkpointEmailChange(id: id, change: pending)
        try store.completeEmailChange(id: id, proof: .init(email: pending.newEmail, userID: "fixture-user-id"))
        #expect(store.accounts.first?.email == pending.newEmail)
        #expect(store.accounts.first?.accessToken == nil)
        #expect(AccessTokenExport.text(for: store.accounts).isEmpty)
    }

    @Test func failedExportReplacementPreservesExistingTargetAndCleansTemporaryFile() throws {
        let store = store()
        defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
        try store.save()
        let target = store.fileURL.deletingLastPathComponent().appendingPathComponent("new-novoreg-access-tokens.txt", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        let sentinel = target.appendingPathComponent("existing.txt")
        try Data("existing-data".utf8).write(to: sentinel)
        #expect(throws: (any Error).self) { try store.writeRegistrationAccessTokenExport() }
        #expect(try String(contentsOf: sentinel, encoding: .utf8) == "existing-data")
        #expect(try FileManager.default.contentsOfDirectory(atPath: target.deletingLastPathComponent().path).sorted() == ["accounts.json", "new-novoreg-access-tokens.txt"])
    }

    private func permissions(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try #require(attributes[.posixPermissions] as? NSNumber).intValue
    }
}
