import Foundation
import Testing
@testable import GPTAccountManager

@Suite struct RegistrationBirthDateTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int) throws -> Date {
        try #require(calendar.date(from: DateComponents(year: year, month: month, day: day)))
    }

    @Test func legacyDraftDecodesWithoutInventingBirthDate() throws {
        let data = Data("""
        {"fullName":"Test Person","age":28,"passwordWasSubmitted":false,
         "phase":"signingUp","baselineMessageIDs":[],"termsAccepted":true}
        """.utf8)
        let pending = try JSONDecoder().decode(PendingRegistration.self, from: data)
        #expect(pending.birthDate == nil)
        #expect(PendingRegistration(fullName: "Test Person", age: 28).birthDate == nil)
    }

    @Test func birthDateMatchesSavedAgeAndStaysDeterministic() throws {
        let reference = try date(2026, 10, 19)
        for age in [18, 28, 100] {
            let value = PendingRegistration.birthDate(forAge: age, referenceDate: reference, calendar: calendar)
            #expect(value == "\(2026 - age)-10-19")
            #expect(value == PendingRegistration.birthDate(forAge: age, referenceDate: reference, calendar: calendar))
            let birth = try date(2026 - age, 10, 19)
            #expect(calendar.dateComponents([.year], from: birth, to: reference).year == age)
        }
        #expect(PendingRegistration.birthDate(forAge: 17, referenceDate: reference, calendar: calendar) == nil)
        #expect(PendingRegistration.birthDate(forAge: 101, referenceDate: reference, calendar: calendar) == nil)
    }

    @Test func leapDayClampsToRealDateWithCorrectAge() throws {
        let reference = try date(2024, 2, 29)
        #expect(PendingRegistration.birthDate(forAge: 19, referenceDate: reference, calendar: calendar) == "2005-02-28")
        #expect(PendingRegistration.birthDate(forAge: 20, referenceDate: reference, calendar: calendar) == "2004-02-29")
        #expect(calendar.dateComponents([.year], from: try date(2005, 2, 28), to: reference).year == 19)
    }

    @Test func localDayControlsGregorianISODate() throws {
        var local = Calendar(identifier: .buddhist)
        local.timeZone = try #require(TimeZone(secondsFromGMT: -8 * 60 * 60))
        let reference = try date(2026, 1, 1)
        #expect(PendingRegistration.birthDate(forAge: 28, referenceDate: reference, calendar: local) == "1997-12-31")
    }

    @Test func persistedBirthDateSurvivesRestartAndLaterReferenceDate() throws {
        var pending = PendingRegistration(fullName: "Test Person", age: 28)
        pending.birthDate = PendingRegistration.birthDate(forAge: pending.age,
                                                        referenceDate: try date(2026, 10, 19), calendar: calendar)
        let reloaded = try JSONDecoder().decode(PendingRegistration.self, from: JSONEncoder().encode(pending))
        #expect(reloaded == pending)
        #expect(reloaded.birthDate == "1998-10-19")
        #expect(reloaded.birthDate != PendingRegistration.birthDate(forAge: reloaded.age,
                                                                  referenceDate: try date(2026, 10, 20), calendar: calendar))
    }
}
