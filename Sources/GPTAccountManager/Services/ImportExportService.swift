import Foundation

enum CredentialLineError: Error, Equatable {
    case invalidFormat
    case missingField
    case invalidSecret
    case invalidSeparator
    case ambiguousFormat
}

enum CredentialImportSeparator: Equatable, Sendable {
    case automatic
    case literal(String)
}

enum ImportExportService {
    static func parseCredentialLine(_ rawLine: String) throws -> ImportedCredential {
        try parseCredentialLine(rawLine, separator: "|")
    }

    private static func parseCredentialLine(
        _ rawLine: String,
        separator: String
    ) throws -> ImportedCredential {
        guard !separator.isEmpty, !separator.contains(where: \Character.isNewline) else {
            throw CredentialLineError.invalidSeparator
        }
        guard !rawLine.contains(where: \Character.isNewline),
              let first = rawLine.range(of: separator, options: .literal),
              let last = rawLine.range(of: separator, options: [.literal, .backwards]),
              first.upperBound <= last.lowerBound
        else { throw CredentialLineError.invalidFormat }

        let email = rawLine[..<first.lowerBound].trimmingCharacters(in: .whitespaces)
        let password = String(rawLine[first.upperBound..<last.lowerBound])
        let secret = rawLine[last.upperBound...]
            .trimmingCharacters(in: .whitespaces)
        guard !email.isEmpty, !password.isEmpty, !secret.isEmpty else {
            throw CredentialLineError.missingField
        }
        guard TOTPService.isValidSecret(secret) else {
            throw CredentialLineError.invalidSecret
        }
        return ImportedCredential(
            email: email,
            password: password,
            totpSecret: secret)
    }

    static func parse(
        _ text: String,
        separator: CredentialImportSeparator = .literal("|")
    ) -> ImportResult {
        var values: [String: ImportedCredential] = [:]
        var order: [String] = []
        var issues: [ImportIssue] = []
        var duplicates: [String] = []

        for (offset, rawLine) in text.components(separatedBy: .newlines).enumerated() {
            if rawLine.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
            let credential: ImportedCredential
            do {
                switch separator {
                case .automatic:
                    credential = try automaticallyParseCredentialLine(rawLine)
                case let .literal(value):
                    credential = try parseCredentialLine(rawLine, separator: value)
                }
            } catch {
                issues.append(.init(
                    lineNumber: offset + 1,
                    message: issueMessage(for: error, separator: separator)))
                continue
            }

            let key = credential.email.lowercased()
            if values[key] != nil {
                if !duplicates.contains(key) { duplicates.append(key) }
            } else {
                order.append(key)
            }
            values[key] = credential
        }

        return .init(
            records: order.compactMap { values[$0] },
            issues: issues,
            duplicateEmails: duplicates)
    }

    private static func automaticallyParseCredentialLine(_ rawLine: String) throws -> ImportedCredential {
        var match: ImportedCredential?
        for separator in ["|", ":", ";", ",", "\t"] {
            guard let candidate = try? parseCredentialLine(rawLine, separator: separator),
                  isAutomaticEmail(candidate.email)
            else { continue }
            if let match, match != candidate { throw CredentialLineError.ambiguousFormat }
            match = candidate
        }
        guard let match else { throw CredentialLineError.invalidFormat }
        return match
    }

    private static func isAutomaticEmail(_ email: String) -> Bool {
        let parts = email.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty,
              !email.contains(where: { $0.isWhitespace || "\"(),:;<>[\\]|".contains($0) })
        else { return false }
        let domain = parts[1].split(separator: ".", omittingEmptySubsequences: false)
        return domain.count > 1 && domain.allSatisfy { label in
            !label.isEmpty && label.first != "-" && label.last != "-" &&
                label.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" }
        }
    }

    private static func issueMessage(for error: Error, separator: CredentialImportSeparator) -> String {
        switch error as? CredentialLineError {
        case .missingField:
            "LOGIN, PASS and 2FA are required"
        case .invalidSecret:
            "2FA must be a valid Base32 secret"
        case .invalidSeparator:
            "Separator must not be empty or contain line breaks"
        case .ambiguousFormat:
            "Ambiguous separators; choose a separator manually"
        default:
            switch separator {
            case .literal("|"): "Expected LOGIN|PASS|2FA"
            case .literal: "Expected LOGIN, PASS and 2FA separated by the selected separator"
            case .automatic: "Could not detect separator; choose a separator manually"
            }
        }
    }

    static func serialize(_ accounts: [AccountRecord]) -> String {
        guard !accounts.isEmpty else { return "" }
        return accounts.map(\.credentialLine).joined(separator: "\n") + "\n"
    }

    static func serializeForClipboard(_ accounts: [AccountRecord]) -> String {
        accounts.map(\.credentialLine).joined(separator: "\n")
    }
}
