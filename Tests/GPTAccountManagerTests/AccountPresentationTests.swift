import Foundation
import Testing
@testable import GPTAccountManager

@Suite struct AccountPresentationTests {
    @Test func subtitleShowsTagPlanAndShortDate() {
        var account = AccountRecord(credential: .init(
            email: "one@example.com",
            password: "password",
            totpSecret: "JBSWY3DPEHPK3PXP"))
        account.tag = "main"
        account.planLabel = "plus"
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        account.subscriptionDate = calendar.date(from: .init(
            year: 2026,
            month: 9,
            day: 30))

        #expect(AccountPresentation.sidebarSubtitle(
            account: account,
            locale: Locale(identifier: "ru-RU"),
            timeZone: TimeZone(secondsFromGMT: 0)!) == "main · plus · 30.09.26")
    }

    @Test func subtitleDoesNotInventMissingDate() {
        var account = AccountRecord(credential: .init(
            email: "one@example.com",
            password: "password",
            totpSecret: "JBSWY3DPEHPK3PXP"))
        account.planLabel = "plus"

        #expect(AccountPresentation.sidebarSubtitle(account: account) == "plus")
    }
}
