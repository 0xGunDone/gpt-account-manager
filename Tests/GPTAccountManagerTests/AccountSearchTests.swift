import Foundation
import Testing
@testable import GPTAccountManager

@Suite struct AccountSearchTests {
    private func account(
        email: String,
        password: String = "private-password",
        secret: String = "JBSWY3DPEHPK3PXP",
        tag: String? = nil
    ) -> AccountRecord {
        var account = AccountRecord(credential: .init(
            email: email,
            password: password,
            totpSecret: secret))
        account.tag = tag
        return account
    }

    @Test func blankQueryKeepsEveryAccount() {
        let accounts = [
            account(email: "alpha@example.com"),
            account(email: "beta@example.com", tag: "Work"),
        ]

        #expect(AccountSearch.filter(accounts, query: "   ") == accounts)
    }

    @Test func queryMatchesLoginOrTagCaseInsensitively() {
        let first = account(email: "Alpha@Example.com", tag: "Primary")
        let second = account(email: "beta@example.com", tag: "Reserve")

        #expect(AccountSearch.filter([first, second], query: "ALPHA") == [first])
        #expect(AccountSearch.filter([first, second], query: "reserve") == [second])
    }

    @Test func queryNeverSearchesPasswordsOrAuthenticatorSecrets() {
        let value = account(
            email: "owner@example.com",
            password: "needle-password",
            secret: "MFRGGZDFMZTWQ2LK")

        #expect(AccountSearch.filter([value], query: "needle-password").isEmpty)
        #expect(AccountSearch.filter([value], query: "MFRGGZDF").isEmpty)
    }
}
