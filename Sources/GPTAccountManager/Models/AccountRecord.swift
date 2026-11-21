import Foundation

enum AccountStatus: String, Codable, Equatable, Sendable {
    case unchecked, checking, ready, failed, needsRecovery
}

enum SubscriptionDateKind: String, Codable, Equatable, Sendable {
    case renews, expires
}

enum RotationStage: String, Codable, Equatable, Sendable {
    case removingOldMethod
    case oldMethodDisabled
    case pendingSecretCaptured
    case awaitingCleanLogin
}

struct ImportedCredential: Equatable, Sendable {
    let email: String
    let password: String
    let totpSecret: String
    var externalMailbox: ExternalMailboxConfiguration? = nil
}

struct AccountRecord: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var email: String
    var password: String
    var totpSecret: String
    var browserStoreID: UUID
    var planLabel: String?
    var subscriptionDate: Date?
    var subscriptionDateKind: SubscriptionDateKind?
    var lastCheckedAt: Date?
    var status: AccountStatus
    var lastError: String?
    var pendingTOTPSecret: String?
    var rotationStage: RotationStage?
    var groupID: UUID? = nil
    var tag: String? = nil
    var pendingPassword: String? = nil
    var pendingAccessChange: AccessChangeMode? = nil
    var accessChangePasswordVerified: Bool? = nil
    var pendingEmailChange: PendingEmailChange? = nil
    var abandonedEmailChange: PendingEmailChange? = nil
    var pendingRegistration: PendingRegistration? = nil
    var proxy: AccountProxy? = nil
    var accessToken: String? = nil
    var externalMailbox: ExternalMailboxConfiguration? = nil

    var pendingAccessChangeMode: AccessChangeMode? { pendingAccessChange ?? pendingPassword.map { _ in .password } }
    var hasPendingAccessChange: Bool { pendingAccessChangeMode != nil }
    var hasPendingEmailChange: Bool { pendingEmailChange != nil }
    var hasPendingCredentialChange: Bool {
        hasPendingAccessChange || hasPendingEmailChange || pendingRegistration != nil
    }

    init(credential: ImportedCredential) {
        id = UUID()
        email = credential.email
        password = credential.password
        totpSecret = credential.totpSecret
        externalMailbox = credential.externalMailbox
        browserStoreID = UUID()
        status = .unchecked
    }

    var credentialLine: String {
        "\(email)|\(password)|\(totpSecret)"
    }

    var accessTokenLine: String? {
        guard let accessToken, AccessTokenExport.isValidField(email),
              AccessTokenExport.isValidField(accessToken) else { return nil }
        return "\(email)|\(accessToken)"
    }
}

struct ImportIssue: Equatable, Sendable {
    let lineNumber: Int
    let message: String
}

struct ImportResult: Equatable, Sendable {
    let records: [ImportedCredential]
    let issues: [ImportIssue]
    let duplicateEmails: [String]
}
