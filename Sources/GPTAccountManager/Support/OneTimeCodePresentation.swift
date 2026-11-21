import Foundation

struct OneTimeCodeSnapshot: Equatable, Sendable {
    let code: String
    let usesPendingSecret: Bool
    let secondsRemaining: Int
}

enum OneTimeCodePresentation {
    static func snapshot(
        for account: AccountRecord,
        date: Date = Date()
    ) -> OneTimeCodeSnapshot? {
        let pendingSecret = account.pendingTOTPSecret ?? account.pendingRegistration?.pendingSecret
        let usesPendingSecret = pendingSecret != nil
        let secret = pendingSecret ?? account.totpSecret
        guard let code = try? TOTPService.code(secret: secret, date: date) else {
            return nil
        }
        let period: TimeInterval = 30
        let elapsed = date.timeIntervalSince1970
            .truncatingRemainder(dividingBy: period)
        let normalizedElapsed = elapsed >= 0 ? elapsed : elapsed + period
        let secondsRemaining = max(1, Int(ceil(period - normalizedElapsed)))
        return OneTimeCodeSnapshot(
            code: code,
            usesPendingSecret: usesPendingSecret,
            secondsRemaining: secondsRemaining)
    }
}
