import CoreFoundation
import Foundation

enum TokenValidity: Equatable, Sendable {
    case missing, unknown, expired, expiringSoon, valid
}

/// JWT claims are unverified hints. They never establish or replace an account's identity.
struct AccessTokenMetadata: Sendable {
    let expiresAt: Date?
    let accountID: String?
    let userID: String?
    let email: String?
    let plan: String?
    let emailClaims: [String]
    private let isMissing: Bool

    init(token: String?) {
        isMissing = token == nil || token?.allSatisfy(\.isWhitespace) == true
        let payload = token.flatMap(Self.payload)
        let auth = payload?["https://api.openai.com/auth"] as? [String: Any]
        let profile = payload?["https://api.openai.com/profile"] as? [String: Any]
        accountID = auth?["chatgpt_account_id"] as? String
        userID = (auth?["chatgpt_user_id"] as? String) ?? (auth?["user_id"] as? String)
        emailClaims = [profile?["email"] as? String, payload?["email"] as? String].compactMap { $0 }
        email = emailClaims.first
        plan = auth?["chatgpt_plan_type"] as? String
        if let number = payload?["exp"] as? NSNumber,
           CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite,
           number.doubleValue > 0, number.doubleValue <= 253_402_300_799 {
            expiresAt = Date(timeIntervalSince1970: number.doubleValue)
        } else {
            expiresAt = nil
        }
    }

    func validity(at now: Date = Date()) -> TokenValidity {
        guard !isMissing else { return .missing }
        guard let expiresAt else { return .unknown }
        let remaining = expiresAt.timeIntervalSince(now)
        if remaining <= 0 { return .expired }
        return remaining <= 5 * 60 ? .expiringSoon : .valid
    }

    private static func payload(_ token: String) -> [String: Any]? {
        guard token.utf8.count <= 128 * 1024 else { return nil }
        let segments = token.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count == 3, jsonObject(segments[0]) != nil else { return nil }
        return jsonObject(segments[1])
    }

    private static func jsonObject(_ segment: Substring) -> [String: Any]? {
        guard !segment.isEmpty, segment.utf8.allSatisfy({
            (65...90).contains($0) || (97...122).contains($0) ||
                (48...57).contains($0) || $0 == 45 || $0 == 95
        }) else { return nil }
        var encoded = segment.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        encoded += String(repeating: "=", count: (4 - encoded.utf8.count % 4) % 4)
        guard let data = Data(base64Encoded: encoded),
              let object = try? JSONSerialization.jsonObject(with: data) else { return nil }
        return object as? [String: Any]
    }
}
