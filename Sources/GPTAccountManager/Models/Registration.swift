import Foundation

enum RegistrationPhase: String, Codable, Equatable, Sendable {
    // verifyingLogin is retained on disk for old drafts; it now means saving the existing session after setup.
    case signingUp, awaitingEmailCode, profile, enablingTwoFA, verifyingLogin, complete
}

struct PendingRegistration: Codable, Equatable, Sendable {
    var fullName: String
    var age: Int
    var birthDate: String?
    var passwordWasSubmitted = false
    var phase: RegistrationPhase = .signingUp
    var requestedAt: Date?
    var baselineMessageIDs: Set<String> = []
    var pendingSecret: String?
    var termsAccepted = true
    // Optional for drafts saved before the bounded profile retry was added.
    var profileRetryUsed: Bool?
    // Resume an already requested security-confirmation email without reopening setup.
    var mfaEmailVerificationPending: Bool?

    init(fullName: String, age: Int) {
        self.fullName = fullName
        self.age = age
    }

    static func birthDate(forAge age: Int, referenceDate: Date = Date(),
                          calendar: Calendar = .current) -> String? {
        guard (18...100).contains(age) else { return nil }
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = calendar.timeZone
        guard let birthDate = gregorian.date(byAdding: .year, value: -age, to: referenceDate),
              gregorian.dateComponents([.year], from: birthDate, to: referenceDate).year == age else { return nil }
        let components = gregorian.dateComponents([.era, .year, .month, .day], from: birthDate)
        guard components.era == 1, let year = components.year, (1...9999).contains(year),
              let month = components.month, let day = components.day else { return nil }
        return String(format: "%04d-%02d-%02d", year, month, day)
    }
}
