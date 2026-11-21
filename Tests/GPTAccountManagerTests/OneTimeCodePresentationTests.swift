import Foundation
import Testing
@testable import GPTAccountManager

@Suite struct OneTimeCodePresentationTests {
    @Test func currentSecretProducesTheVisibleSixDigitCode() throws {
        let account = AccountRecord(credential: .init(
            email: "owner@example.com",
            password: "pw",
            totpSecret: "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ"))

        let snapshot = try #require(OneTimeCodePresentation.snapshot(
            for: account,
            date: Date(timeIntervalSince1970: 59)))

        #expect(snapshot.code == "287082")
        #expect(!snapshot.usesPendingSecret)
        #expect(snapshot.secondsRemaining == 1)
    }

    @Test func pendingSecretTakesPriorityDuringRotation() throws {
        var account = AccountRecord(credential: .init(
            email: "owner@example.com",
            password: "pw",
            totpSecret: "JBSWY3DPEHPK3PXP"))
        account.pendingTOTPSecret = "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ"

        let snapshot = try #require(OneTimeCodePresentation.snapshot(
            for: account,
            date: Date(timeIntervalSince1970: 59)))

        #expect(snapshot.code == "287082")
        #expect(snapshot.usesPendingSecret)
    }

    @Test func registrationSecretProvidesCodeBeforeAccountIsReady() throws {
        var account = AccountRecord(credential: .init(
            email: "new@example.com", password: "pw", totpSecret: ""))
        var pending = PendingRegistration(fullName: "Fixture Person", age: 24)
        pending.phase = .verifyingLogin
        pending.pendingSecret = "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ"
        account.pendingRegistration = pending
        let original = account

        let snapshot = try #require(OneTimeCodePresentation.snapshot(
            for: account, date: Date(timeIntervalSince1970: 59)))
        #expect(snapshot.code == "287082" && snapshot.secondsRemaining == 1)
        #expect(snapshot.usesPendingSecret)
        #expect(account == original && account.totpSecret.isEmpty)
    }

    @Test func missingOrInvalidRegistrationKeyDoesNotDisplayCodeFromAnotherKey() {
        var account = AccountRecord(credential: .init(
            email: "new@example.com", password: "pw", totpSecret: ""))
        account.pendingRegistration = PendingRegistration(fullName: "Fixture Person", age: 24)
        #expect(OneTimeCodePresentation.snapshot(for: account) == nil)
        account.totpSecret = "JBSWY3DPEHPK3PXP"
        account.pendingRegistration?.pendingSecret = "invalid!"
        #expect(OneTimeCodePresentation.snapshot(for: account) == nil)
    }
}
