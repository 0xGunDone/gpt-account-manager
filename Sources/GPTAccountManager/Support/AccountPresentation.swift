import Foundation

enum AccountPresentation {
    static func sidebarSubtitle(
        account: AccountRecord,
        locale: Locale = .current,
        timeZone: TimeZone = .current
    ) -> String {
        var parts = [account.tag, account.planLabel].compactMap {
            $0?.isEmpty == false ? $0 : nil
        }
        if let date = account.subscriptionDate {
            let formatter = DateFormatter()
            formatter.locale = locale
            formatter.timeZone = timeZone
            formatter.dateFormat = "dd.MM.yy"
            parts.append(formatter.string(from: date))
        }
        return parts.isEmpty ? "Не проверен" : parts.joined(separator: " · ")
    }
}
