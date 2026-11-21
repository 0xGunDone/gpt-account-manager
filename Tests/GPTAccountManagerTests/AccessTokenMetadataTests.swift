import Foundation
import Testing
@testable import GPTAccountManager

@Suite struct AccessTokenMetadataTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func decodesOpenAIHintsWithoutTreatingThemAsVerifiedIdentity() throws {
        let metadata = AccessTokenMetadata(token: try jwt([
            "exp": 1_800_003_600,
            "https://api.openai.com/auth": [
                "chatgpt_account_id": "external-account-fixture",
                "chatgpt_user_id": "external-user-fixture",
                "chatgpt_plan_type": "plus",
            ],
            "https://api.openai.com/profile": ["email": "owner@example.com"],
        ]))

        #expect(metadata.expiresAt == Date(timeIntervalSince1970: 1_800_003_600))
        #expect(metadata.accountID == "external-account-fixture")
        #expect(metadata.userID == "external-user-fixture")
        #expect(metadata.email == "owner@example.com" && metadata.plan == "plus")
        #expect(metadata.validity(at: now) == .valid)
    }

    @Test func distinguishesMissingOpaqueAndMalformedTokens() {
        for token in [nil, "", " \n\t"] as [String?] {
            #expect(AccessTokenMetadata(token: token).validity(at: now) == .missing)
        }
        for token in ["opaque-fixture-token", "a.b.c", "a.b.c.d", "eyJhbGciOiJub25lIn0.%%%.fixture"] {
            let metadata = AccessTokenMetadata(token: token)
            #expect(metadata.validity(at: now) == .unknown)
            #expect(metadata.expiresAt == nil && metadata.accountID == nil)
        }
    }

    @Test(arguments: [
        (offset: -1.0, expected: TokenValidity.expired),
        (offset: 0.0, expected: .expired),
        (offset: 0.001, expected: .expiringSoon),
        (offset: 300.0, expected: .expiringSoon),
        (offset: 300.001, expected: .valid),
    ])
    func fiveMinuteWindowKeepsExpiryBoundaryExact(offset: Double, expected: TokenValidity) throws {
        let metadata = AccessTokenMetadata(token: try jwt(["exp": now.timeIntervalSince1970 + offset]))
        #expect(metadata.validity(at: now) == expected)
    }

    @Test func rejectsNonNumericNonPositiveAndNonFiniteExpiry() throws {
        for value in ["1800003600", true, false, NSNull(), 0, -1, [1_800_003_600]] as [Any] {
            let metadata = AccessTokenMetadata(token: try jwt(["exp": value]))
            #expect(metadata.expiresAt == nil && metadata.validity(at: now) == .unknown)
        }
        let overflow = rawJWT(payload: "{\"exp\":1e309}")
        #expect(AccessTokenMetadata(token: overflow).expiresAt == nil)
        let nan = rawJWT(payload: "{\"exp\":NaN}")
        #expect(AccessTokenMetadata(token: nan).validity(at: now) == .unknown)
    }

    @Test func limitsExpiryToRepresentableCalendarRange() throws {
        let lastSecond = AccessTokenMetadata(token: try jwt(["exp": 253_402_300_799]))
        #expect(lastSecond.expiresAt == Date(timeIntervalSince1970: 253_402_300_799))
        for seconds in [253_402_300_800.0, 1e308] {
            let metadata = AccessTokenMetadata(token: try jwt(["exp": seconds]))
            #expect(metadata.expiresAt == nil && metadata.validity(at: now) == .unknown)
        }
    }

    @Test func acceptsNumericSecondsWithoutGuessingMillisecondsOrSubscriptionDates() throws {
        let metadata = AccessTokenMetadata(token: try jwt(["exp": 1_800_000_000.5]))
        #expect(metadata.expiresAt == Date(timeIntervalSince1970: 1_800_000_000.5))
        #expect(AccessTokenMetadata(token: try jwt(["expires_at": 1_800_003_600])).expiresAt == nil)
    }

    @Test func boundsJWTDecodingBeforeReadingClaims() throws {
        let oversized = try jwt([
            "exp": 1_800_003_600,
            "https://api.openai.com/auth": ["chatgpt_account_id": "external-account-fixture"],
            "padding": String(repeating: "x", count: 128 * 1024),
        ])
        let metadata = AccessTokenMetadata(token: oversized)
        #expect(metadata.expiresAt == nil && metadata.accountID == nil)
        #expect(metadata.validity(at: now) == .unknown)
    }

    @Test func doesNotInventAccountIDFromSubjectOrUnrelatedLocalID() throws {
        let metadata = AccessTokenMetadata(token: try jwt([
            "sub": "subject-fixture",
            "id": "local-id-fixture",
            "email": "owner@example.com",
            "https://api.openai.com/auth": ["user_id": "external-user-fixture"],
        ]))
        #expect(metadata.accountID == nil && metadata.userID == "external-user-fixture")
        #expect(metadata.email == "owner@example.com" && metadata.expiresAt == nil)
    }

    private func jwt(_ payload: [String: Any]) throws -> String {
        rawJWT(payload: String(decoding: try JSONSerialization.data(withJSONObject: payload), as: UTF8.self))
    }

    private func rawJWT(payload: String) -> String {
        let header = Data("{\"alg\":\"none\",\"typ\":\"JWT\"}".utf8)
        return "\(base64URL(header)).\(base64URL(Data(payload.utf8))).fixture-signature"
    }

    private func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}
