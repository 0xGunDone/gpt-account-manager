import Foundation

enum BrowserRecoveryResult: Equatable, Sendable {
    case readyToContinue(String)
    case manualAction(String)
    case failure(String)
}

@MainActor
protocol BrowserRecoveryHandling: AnyObject {
    func recoverySession(
        for account: AccountRecord,
        context: BrowserRecoveryContext
    ) -> BrowserSession?
    func hasCandidateSession(for accountID: UUID) -> Bool
    func reloadRecoveryPage(
        for account: AccountRecord,
        context: BrowserRecoveryContext
    ) async -> BrowserRecoveryResult
    func reopenExpectedPage(
        for account: AccountRecord,
        context: BrowserRecoveryContext
    ) async -> BrowserRecoveryResult
    func startFreshLogin(
        for account: AccountRecord,
        context: BrowserRecoveryContext
    ) async -> BrowserRecoveryResult
    func returnToOriginalSession(for account: AccountRecord)
}
