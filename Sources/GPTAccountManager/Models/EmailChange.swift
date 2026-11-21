import Foundation

enum EmailAliasStatus: String, Codable, Equatable, Sendable {
    case available, reserved, used
}

struct EmailAlias: Identifiable, Codable, Equatable, Sendable {
    var id: UUID = UUID()
    var email: String
    var status: EmailAliasStatus = .available
    var accountID: UUID? = nil
}

enum EmailChangePhase: String, Codable, Equatable, Sendable {
    case reserved, requested, confirming
}

struct PendingEmailChange: Codable, Equatable, Sendable {
    var aliasID: UUID
    var operationID: UUID = UUID()
    var originalEmail: String
    var newEmail: String
    var phase: EmailChangePhase = .reserved
    var baselineMessageIDs: Set<String> = []
    var requestedAt: Date? = nil
    var originalUserID: String? = nil
    var requestAttemptID: UUID? = nil
}

struct EmailChangeProof: Equatable, Sendable {
    let email: String
    let userID: String
}
