import Foundation

enum AccountSearch {
    static func filter(
        _ accounts: [AccountRecord],
        query: String
    ) -> [AccountRecord] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return accounts }
        return accounts.filter { account in
            account.email.localizedCaseInsensitiveContains(query) ||
                account.tag?.localizedCaseInsensitiveContains(query) == true
        }
    }
}
