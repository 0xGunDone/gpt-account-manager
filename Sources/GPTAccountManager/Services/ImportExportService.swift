import Foundation

enum CredentialLineError: Error, Equatable {
    case invalidFormat
    case missingField
    case invalidSecret
    case invalidSeparator
    case ambiguousFormat
    case invalidMailboxBlock
}

enum CredentialImportSeparator: Equatable, Sendable {
    case automatic
    case literal(String)
}

enum ImportExportService {
    private enum BlockField: String {
        case email, password
        case twoFA = "2fa"
        case mailbox = "mailbox email"
        case codeURL = "ссылка для кода с почты"
    }

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

        let lines = text.components(separatedBy: .newlines)
        var nextLine = 0
        while nextLine < lines.count {
            let offset = nextLine
            let rawLine = lines[offset]
            nextLine += 1
            if rawLine.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
            var credential: ImportedCredential
            do {
                if let (field, email) = blockField(in: rawLine), field == .email,
                   let result = try parseMailboxBlock(email: email, lines: lines, nextLine: &nextLine) {
                    credential = result
                } else {
                    switch separator {
                    case .automatic:
                        credential = try automaticallyParseCredentialLine(rawLine)
                    case let .literal(value):
                        credential = try parseCredentialLine(rawLine, separator: value)
                    }
                }
            } catch {
                issues.append(.init(
                    lineNumber: offset + 1,
                    message: issueMessage(for: error, separator: separator)))
                continue
            }

            let key = credential.email.lowercased()
            if let previous = values[key] {
                if !duplicates.contains(key) { duplicates.append(key) }
                if credential.externalMailbox == nil {
                    credential.externalMailbox = previous.externalMailbox
                }
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

    private static func blockField(in line: String) -> (BlockField, String)? {
        guard let colon = line.firstIndex(of: ":"),
              let field = BlockField(rawValue: line[..<colon].trimmingCharacters(in: .whitespaces).lowercased())
        else { return nil }
        let value = line[line.index(after: colon)...]
        return (field, String(value.first == " " ? value.dropFirst() : value))
    }

    private static func parseMailboxBlock(
        email: String, lines: [String], nextLine: inout Int
    ) throws -> ImportedCredential? {
        var fields: [BlockField: String] = [:]
        var duplicateField = false
        var offset = nextLine
        while offset < lines.count {
            let line = lines[offset]
            if !line.allSatisfy(\.isWhitespace) {
                guard let (field, value) = blockField(in: line), field != .email else { break }
                if fields.updateValue(value, forKey: field) != nil { duplicateField = true }
            }
            offset += 1
        }
        guard !fields.isEmpty else { return nil }
        nextLine = offset

        let login = email.trimmingCharacters(in: .whitespaces)
        guard !duplicateField, MailVerificationMatcher.normalizedAddress(login) != nil,
              let password = fields[.password], !password.isEmpty,
              let totpSecret = fields[.twoFA]?.trimmingCharacters(in: .whitespaces),
              TOTPService.isValidSecret(totpSecret),
              let mailbox = fields[.mailbox], let endpoint = fields[.codeURL],
              let configuration = try? ExternalMailboxConfiguration(address: mailbox, codeURL: codeURL(in: endpoint))
        else { throw CredentialLineError.invalidMailboxBlock }
        return ImportedCredential(email: login, password: password, totpSecret: totpSecret,
                                  externalMailbox: configuration)
    }

    private static func codeURL(in value: String) throws -> String {
        let text = value.trimmingCharacters(in: .whitespaces)
        guard text.hasPrefix("[") else { return text }
        let link = try AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnly))
        guard let url = link.runs.first?.link, link.runs.allSatisfy({ $0.link == url })
        else { throw CredentialLineError.invalidMailboxBlock }
        let label = String(link.characters)
        if let displayedURL = URL(string: label), displayedURL.scheme != nil, displayedURL != url {
            throw CredentialLineError.invalidMailboxBlock
        }
        return url.absoluteString
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
        case .invalidMailboxBlock:
            "Expected Email, Password, 2FA, Mailbox email, and valid HTTPS code URL"
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
