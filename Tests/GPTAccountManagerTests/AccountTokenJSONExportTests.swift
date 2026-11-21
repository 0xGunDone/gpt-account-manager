import Foundation
import Testing
@testable import GPTAccountManager

@Suite struct AccountTokenJSONExportTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func cpaUsesExternalAccountIDAndGenuineAccessTokenOnly() throws {
        let original = try account()
        let result = try AccountTokenExport.make(accounts: [original], format: .cpa, now: now)
        let row = try #require(JSONSerialization.jsonObject(with: result.data) as? [String: Any])

        #expect(result.documents == [result.data] && result.exportedCount == 1 && result.skippedCount == 0)
        #expect(row["type"] as? String == "codex")
        #expect(row["account_id"] as? String == "external-account-fixture")
        #expect(row["chatgpt_account_id"] as? String == "external-account-fixture")
        #expect(row["account_id"] as? String != original.id.uuidString)
        #expect(row["email"] as? String == "owner@example.com")
        #expect(row["access_token"] as? String == original.accessToken)
        #expect(row["plan_type"] as? String == "plus")
        #expect(row["expired"] as? String == "2027-01-15T09:00:00.000Z")
        try expectNoInventedOrPrivateCredentials(result, original: original)
    }

    @Test func cpaBatchProvidesSeparateNativeObjectsWithoutUnimportableArray() throws {
        let first = try account()
        let second = try account(email: "second@example.com", externalID: "second-external-fixture")
        let result = try AccountTokenExport.make(accounts: [first, second], format: .cpa, now: now)

        #expect(result.exportedCount == 2 && result.documents.count == 2 && result.data.isEmpty)
        let firstData = try #require(result.documents.first)
        let secondData = try #require(result.documents.dropFirst().first)
        let firstDocument = try #require(JSONSerialization.jsonObject(with: firstData) as? [String: Any])
        let secondDocument = try #require(JSONSerialization.jsonObject(with: secondData) as? [String: Any])
        #expect(firstDocument["email"] as? String == "owner@example.com")
        #expect(secondDocument["email"] as? String == "second@example.com")
        #expect(secondDocument["account_id"] as? String == "second-external-fixture")
        #expect(result.warning?.contains("OAuth") == true)
    }

    @Test func emptyCPASelectionDoesNotProduceAnAuthFile() throws {
        let result = try AccountTokenExport.make(accounts: [], format: .cpa, now: now)
        #expect(result.exportedCount == 0 && result.documents.isEmpty && result.data.isEmpty)
    }

    @Test func cockpitUsesFlatArrayForSingleAndMultipleAccounts() throws {
        let first = try account()
        let second = try account(email: "second@example.com", externalID: "second-external-fixture")
        for accounts in [[first], [first, second]] {
            let result = try AccountTokenExport.make(accounts: accounts, format: .cockpit, now: now)
            let rows = try #require(JSONSerialization.jsonObject(with: result.data) as? [[String: Any]])
            #expect(rows.count == accounts.count)
            #expect(rows.first?["type"] as? String == "codex")
            #expect(rows.first?["email"] as? String == first.email)
            #expect(rows.first?["account_id"] as? String == "external-account-fixture")
            #expect(rows.first?["expired"] as? String == "2027-01-15T09:00:00.000Z")
            #expect(result.documents.isEmpty)
            try expectNoInventedOrPrivateCredentials(result, original: first)
        }
    }

    @Test func sub2apiUsesImportEnvelopeAndActualJWTExpiry() throws {
        let original = try account()
        let result = try AccountTokenExport.make(accounts: [original], format: .sub2api, now: now)
        let root = try #require(JSONSerialization.jsonObject(with: result.data) as? [String: Any])
        let rows = try #require(root["accounts"] as? [[String: Any]])
        let row = try #require(rows.first)
        let credentials = try #require(row["credentials"] as? [String: Any])

        #expect(root["exported_at"] as? String == "2027-01-15T08:00:00.000Z")
        #expect((root["proxies"] as? [Any])?.isEmpty == true)
        #expect(row["platform"] as? String == "openai" && row["type"] as? String == "oauth")
        #expect((row["expires_at"] as? NSNumber)?.doubleValue == 1_800_003_600)
        #expect(row["auto_pause_on_expired"] as? Bool == true)
        #expect(credentials["access_token"] as? String == original.accessToken)
        #expect(credentials["chatgpt_account_id"] as? String == "external-account-fixture")
        #expect(credentials["chatgpt_user_id"] as? String == "external-user-fixture")
        #expect(credentials["email"] as? String == original.email)
        #expect(credentials["plan_type"] as? String == "plus")
        #expect(credentials["expires_at"] as? String == "2027-01-15T09:00:00.000Z")
        #expect(result.documents.isEmpty)
        try expectNoInventedOrPrivateCredentials(result, original: original)
    }

    @Test func textKeepsLegacyLinesAndSnapshotOrderWhileDeduplicatingIDs() throws {
        var first = try account()
        first.accessToken = "opaque-first-fixture-token"
        var second = try account(email: "second@example.com")
        second.accessToken = "opaque-second-fixture-token"
        let result = try AccountTokenExport.make(accounts: [first, second, first], format: .text, now: now)

        #expect(String(decoding: result.data, as: UTF8.self) == "owner@example.com|opaque-first-fixture-token\nsecond@example.com|opaque-second-fixture-token")
        #expect(result.exportedCount == 2 && result.skippedCount == 1 && result.expiredCount == 0)
    }

    @Test(arguments: [AccountTokenExportFormat.cpa, .cockpit, .sub2api])
    func skipsExpiredAndMissingExternalIDWithoutAbortingValidRows(format: AccountTokenExportFormat) throws {
        let valid = try account()
        let expired = try account(email: "expired@example.com", expiry: now.timeIntervalSince1970)
        var opaque = try account(email: "opaque@example.com")
        opaque.accessToken = "opaque-fixture-token"
        let result = try AccountTokenExport.make(accounts: [valid, expired, opaque, valid], format: format, now: now)

        #expect(result.exportedCount == 1 && result.skippedCount == 3 && result.expiredCount == 1)
        #expect(result.warning?.contains("account_id") == true)
        #expect(result.warning?.contains("OAuth") == true)
        let output = String(decoding: result.data, as: UTF8.self)
        #expect(!output.contains("expired@example.com") && !output.contains("opaque-fixture-token"))
    }

    @Test(arguments: [AccountTokenExportFormat.cpa, .cockpit, .sub2api])
    func knownAccountWithUnknownExpiryDoesNotReceiveFakeExpiry(format: AccountTokenExportFormat) throws {
        let original = try account(expiry: nil)
        let result = try AccountTokenExport.make(accounts: [original], format: format, now: now)
        #expect(result.exportedCount == 1 && result.expiredCount == 0)
        let output = String(decoding: result.data, as: UTF8.self)
        #expect(!output.contains("\"expired\"") && !output.contains("\"expires_at\""))
        #expect(!output.contains("auto_pause_on_expired"))
        #expect(result.warning?.contains("OAuth") == true)
    }

    @Test func rejectsAnyConflictingTokenEmailAndKeepsVerifiedRecordUnchanged() throws {
        let matching = try account(email: "OWNER@example.com", tokenEmail: "owner@example.com")
        let mismatched = try account(email: "stored@example.com", tokenEmail: "other@example.com")
        var conflicting = try account(email: "stored@example.com")
        conflicting.accessToken = try jwt([
            "exp": 1_800_003_600,
            "email": "other@example.com",
            "https://api.openai.com/profile": ["email": "stored@example.com"],
            "https://api.openai.com/auth": ["chatgpt_account_id": "external-account-fixture"],
        ])
        let result = try AccountTokenExport.make(accounts: [matching, mismatched, conflicting], format: .cpa, now: now)
        let row = try #require(JSONSerialization.jsonObject(with: result.data) as? [String: Any])

        #expect(result.exportedCount == 1 && result.skippedCount == 2)
        #expect(row["email"] as? String == "OWNER@example.com")
        #expect(mismatched.email == "stored@example.com" && conflicting.email == "stored@example.com")
    }

    @Test func textSkipsKnownForeignTokenEmailWhileKeepingOpaqueLegacyToken() throws {
        let mismatched = try account(email: "stored@example.com", tokenEmail: "other@example.com")
        var opaque = try account(email: "opaque@example.com")
        opaque.accessToken = "opaque-fixture-token"
        let result = try AccountTokenExport.make(accounts: [mismatched, opaque], format: .text, now: now)

        #expect(String(decoding: result.data, as: UTF8.self) == "opaque@example.com|opaque-fixture-token")
        #expect(result.exportedCount == 1 && result.skippedCount == 1)
        #expect(result.warning != nil)
    }

    @Test func everyFormatExcludesUnverifiedAndPendingAccounts() throws {
        let ready = try account()
        let changes: [(inout AccountRecord) -> Void] = [
            { $0.status = .unchecked },
            { $0.status = .failed },
            { $0.status = .checking },
            { $0.status = .needsRecovery },
            { $0.pendingPassword = "pending-fixture-password" },
            { $0.pendingAccessChange = .password },
            { $0.pendingTOTPSecret = "MZXW6YTBOI======" },
            { $0.rotationStage = .awaitingCleanLogin },
            { $0.pendingEmailChange = .init(aliasID: UUID(), originalEmail: $0.email, newEmail: "new@example.com") },
            { $0.pendingRegistration = .init(fullName: "Fixture Person", age: 28) },
        ]
        for format in AccountTokenExportFormat.allCases {
            for change in changes {
                var pending = ready
                pending.id = UUID()
                change(&pending)
                let result = try AccountTokenExport.make(accounts: [ready, pending], format: format, now: now)
                #expect(result.exportedCount == 1 && result.skippedCount == 1)
            }
        }
    }

    @Test func unsafeFieldsAreSkippedWithoutLeakingCredentials() throws {
        let ready = try account()
        for invalidValue in ["", " ", "bad|field", "bad\nfield", "bad\tfield", "bad\u{0000}field", "bad\u{2028}field"] {
            var invalidToken = ready
            invalidToken.id = UUID()
            invalidToken.accessToken = invalidValue
            var invalidEmail = ready
            invalidEmail.id = UUID()
            invalidEmail.email = invalidValue
            let invalidExternalID = try account(email: "unsafe-id@example.com", externalID: invalidValue)
            let result = try AccountTokenExport.make(accounts: [ready, invalidToken, invalidEmail, invalidExternalID], format: .cpa, now: now)
            #expect(result.exportedCount == 1 && result.skippedCount == 3)
            try expectNoInventedOrPrivateCredentials(result, original: ready)
        }
    }

    @Test func textRetainsKnownExpiredTokenAndReportsIt() throws {
        let expired = try account(expiry: now.timeIntervalSince1970 - 1)
        let result = try AccountTokenExport.make(accounts: [expired], format: .text, now: now)
        #expect(result.exportedCount == 1 && result.expiredCount == 1 && result.skippedCount == 0)
        #expect(String(decoding: result.data, as: UTF8.self) == expired.accessTokenLine)
        #expect(result.warning != nil)
    }

    private func account(
        email: String = "owner@example.com", externalID: String = "external-account-fixture",
        tokenEmail: String? = nil, expiry: Double? = 1_800_003_600
    ) throws -> AccountRecord {
        var result = AccountRecord(credential: .init(
            email: email, password: "private-password-fixture", totpSecret: "JBSWY3DPEHPK3PXP"))
        result.status = .ready
        result.planLabel = "unrelated-subscription-label"
        result.subscriptionDate = Date(timeIntervalSince1970: 1_900_000_000)
        var payload: [String: Any] = [
            "https://api.openai.com/auth": [
                "chatgpt_account_id": externalID,
                "chatgpt_user_id": "external-user-fixture",
                "chatgpt_plan_type": "plus",
            ],
            "https://api.openai.com/profile": ["email": tokenEmail ?? email],
        ]
        if let expiry { payload["exp"] = expiry }
        result.accessToken = try jwt(payload)
        return result
    }

    private func jwt(_ payload: [String: Any]) throws -> String {
        let header = Data("{\"alg\":\"none\",\"typ\":\"JWT\"}".utf8)
        let body = try JSONSerialization.data(withJSONObject: payload)
        func encode(_ data: Data) -> String {
            data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        }
        return "\(encode(header)).\(encode(body)).fixture-signature"
    }

    private func expectNoInventedOrPrivateCredentials(_ result: AccountTokenExportResult, original: AccountRecord) throws {
        let output = String(decoding: result.data, as: UTF8.self)
        for prohibited in ["\"id_token\"", "\"refresh_token\"", "\"session_token\"", "\"cookies\"", "\"last_refresh\"", original.password, original.totpSecret] {
            #expect(!output.contains(prohibited))
        }
        #expect(result.warning?.contains("OAuth") == true)
    }
}
