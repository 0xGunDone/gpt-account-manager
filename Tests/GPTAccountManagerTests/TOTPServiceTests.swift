import Foundation
import Testing
@testable import GPTAccountManager

@Suite struct TOTPServiceTests {
    @Test func rfc6238SHA1Vector() throws {
        let secret = "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ"
        let code = try TOTPService.code(
            secret: secret,
            date: Date(timeIntervalSince1970: 59),
            period: 30,
            digits: 8)
        #expect(code == "94287082")
    }

    @Test func normalizesSpacesAndLowercase() throws {
        #expect(TOTPService.normalizedSecret("jbsw y3dp ehpk 3pxp") ==
            "JBSWY3DPEHPK3PXP")
        #expect(try TOTPService.code(
            secret: "jbsw y3dp ehpk 3pxp",
            date: Date(timeIntervalSince1970: 0)).count == 6)
    }

    @Test func rejectsInvalidBase32() {
        #expect(!TOTPService.isValidSecret("NOT_VALID_1"))
    }

    @Test func delaysSubmissionNearTheEndOfATOTPWindow() {
        #expect(TOTPService.safeSubmissionDelay(
            date: Date(timeIntervalSince1970: 28),
            period: 30,
            minimumRemaining: 5) == 2)
        #expect(TOTPService.safeSubmissionDelay(
            date: Date(timeIntervalSince1970: 20),
            period: 30,
            minimumRemaining: 5) == 0)
    }
}
