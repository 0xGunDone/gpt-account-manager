import Foundation

enum AccessTokenExport {
    static func text(for accounts: [AccountRecord]) -> String {
        accounts.compactMap(\.accessTokenLine).joined(separator: "\n")
    }

    static func count(for accounts: [AccountRecord]) -> Int {
        accounts.count { $0.accessTokenLine != nil }
    }

    static func isValidField(_ value: String) -> Bool {
        !value.allSatisfy(\.isWhitespace) && !value.contains("|") &&
            !value.contains(where: \.isNewline) &&
            value.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
    }
}
