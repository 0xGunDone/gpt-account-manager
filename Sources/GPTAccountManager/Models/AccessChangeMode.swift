import Foundation

enum AccessChangeMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case password, twoFA, passwordAndTwoFA

    var id: Self { self }
    var changesPassword: Bool { self != .twoFA }
    var changesTwoFA: Bool { self != .password }
    var title: String {
        switch self {
        case .password: "Пароль"
        case .twoFA: "2FA"
        case .passwordAndTwoFA: "Пароль и 2FA"
        }
    }
}

enum NewPasswordConfiguration {
    static let environmentKey = "GPTAM_NEW_PASSWORD"
    static let unavailableMessage = "Задайте непустой пароль без управляющих символов и переносов строк в GPTAM_NEW_PASSWORD и перезапустите приложение."

    static var configuredPassword: String? {
        validated(ProcessInfo.processInfo.environment[environmentKey])
    }

    static func validated(_ value: String?) -> String? {
        guard let value, !value.allSatisfy(\.isWhitespace), !value.contains(where: \.isNewline),
              value.rangeOfCharacter(from: .controlCharacters) == nil else { return nil }
        return value
    }
}

enum PasswordChangeOutcome {
    case success(signedInEmail: String)
    case manualActionRequired(String)
    case failure(String)
}

@MainActor
protocol PasswordChanging: AnyObject {
    func resetPasswordChange(for id: UUID)
    func retryPasswordChange(for id: UUID)
    func changePassword(
        account: AccountRecord,
        newPassword: String,
        onSubmission: @escaping @MainActor () throws -> Void
    ) async -> PasswordChangeOutcome
}

extension PasswordChanging {
    func resetPasswordChange(for id: UUID) {}
    func retryPasswordChange(for id: UUID) {}
}
