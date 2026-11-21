import Foundation

struct AccountImportSummary: Equatable, Sendable {
    let imported: Int
    let duplicates: Int
    let rejected: Int
    var preservedTwoFA: Int = 0

    var message: String {
        let summary = "Импортировано: \(imported). Дубликаты: \(duplicates). Отклонено: \(rejected)."
        return preservedTwoFA == 0 ? summary :
            summary + " Сохранён текущий 2FA у \(preservedTwoFA) существующих аккаунтов."
    }
}

@MainActor
enum AccountImportService {
    static func importText(
        _ text: String,
        into store: AccountStore,
        separator: CredentialImportSeparator = .literal("|")
    ) throws -> AccountImportSummary {
        let result = ImportExportService.parse(text, separator: separator)
        let existingEmails = Set(store.accounts.map { $0.email.lowercased() })
        let preserved = result.records.filter { existingEmails.contains($0.email.lowercased()) }.count
        try store.merge(result.records)
        return AccountImportSummary(
            imported: result.records.count,
            duplicates: result.duplicateEmails.count,
            rejected: result.issues.count,
            preservedTwoFA: preserved)
    }
}
