import Foundation
import Observation
import WebKit

struct SubscriptionSnapshot: Equatable, Sendable {
    let signedInEmail: String
    let planLabel: String
    let activeUntil: Date?
    let willRenew: Bool?

    var dateKind: SubscriptionDateKind? {
        guard activeUntil != nil, let willRenew else { return nil }
        return willRenew ? .renews : .expires
    }

    init(
        signedInEmail: String,
        planLabel: String,
        activeUntil: Date?,
        willRenew: Bool?
    ) {
        self.signedInEmail = signedInEmail
        self.planLabel = planLabel
        self.activeUntil = activeUntil
        self.willRenew = willRenew
    }

    init(javaScriptValue value: Any) throws {
        guard let dictionary = value as? [String: Any],
              dictionary["state"] as? String == "success",
              let email = dictionary["email"] as? String,
              !email.isEmpty
        else { throw SubscriptionSnapshotError.invalidPayload }

        let rawDate = dictionary["activeUntil"] as? String
        let rawDateText = dictionary["activeUntilText"] as? String
        let renewal = dictionary["willRenew"] as? Bool
        guard let source = dictionary["source"] as? String,
              source == "subscription" || source == "session",
              source == "subscription" ||
                (rawDate == nil && rawDateText == nil && renewal == nil)
        else { throw SubscriptionSnapshotError.invalidPayload }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let parsedDate = rawDate.flatMap {
            fractional.date(from: $0) ?? ISO8601DateFormatter().date(from: $0)
        } ?? rawDateText.flatMap {
            Self.parseDisplayDate(
                $0,
                localeIdentifier: dictionary["activeUntilLocale"] as? String)
        }
        self.init(
            signedInEmail: email,
            planLabel: (dictionary["plan"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "unknown",
            activeUntil: parsedDate,
            willRenew: renewal)
    }

    func addingPricingDetails(_ details: PricingDetails) -> SubscriptionSnapshot {
        SubscriptionSnapshot(
            signedInEmail: signedInEmail,
            planLabel: planLabel,
            activeUntil: activeUntil ?? Self.parseDisplayDate(
                details.activeUntilText,
                localeIdentifier: details.localeIdentifier),
            willRenew: willRenew)
    }

    private static func parseDisplayDate(
        _ value: String,
        localeIdentifier: String?
    ) -> Date? {
        var text = value
            .replacingOccurrences(of: "\u{00a0}", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["до ", "until ", "through ", "expires on ", "renews on "] {
            if text.lowercased().hasPrefix(prefix) {
                text.removeFirst(prefix.count)
                break
            }
        }
        text = text.replacingOccurrences(
            of: #"\s+г\.?$"#,
            with: "",
            options: .regularExpression)

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: localeIdentifier ?? "en-US")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.isLenient = true
        for format in ["d MMM yyyy", "d MMMM yyyy", "MMM d, yyyy", "MMMM d, yyyy"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }
}

enum SubscriptionSnapshotError: Error {
    case invalidPayload
}

struct PricingDetails: Equatable, Sendable {
    let activeUntilText: String
    let localeIdentifier: String
}

enum SubscriptionCheckOutcome: Equatable, Sendable {
    case success(SubscriptionSnapshot)
    case manualActionRequired(String)
    case failure(String)
}

@MainActor
protocol SubscriptionChecking: AnyObject {
    var activeSession: BrowserSession? { get }
    func check(account: AccountRecord) async -> SubscriptionCheckOutcome
    func continueCheck(account: AccountRecord) async -> SubscriptionCheckOutcome
    func accessTokenAfterCheck(for account: AccountRecord) async throws -> String?
    func cancelActiveOperation()
}

extension SubscriptionChecking {
    func continueCheck(account: AccountRecord) async -> SubscriptionCheckOutcome {
        await check(account: account)
    }

    func cancelActiveOperation() {}

    func accessTokenAfterCheck(for account: AccountRecord) async throws -> String? { nil }
}

enum RotationCheckpointEvent: Equatable, Sendable {
    case removalStarted
    case oldMethodDisabled
    case secretCaptured(String)
    case setupConfirmed
}

enum RecoverySessionProbeResult: Equatable, Sendable {
    case authenticated
    case manual(String)
    case cancelled
}

struct CleanLoginProof: Equatable, Sendable {
    var passwordSubmitted: Bool
    var pendingOTPSubmitted: Bool
    var authenticatedImmediatelyAfterPendingOTP: Bool = false

    static let none = CleanLoginProof(
        passwordSubmitted: false,
        pendingOTPSubmitted: false,
        authenticatedImmediatelyAfterPendingOTP: false)

    var isSufficient: Bool {
        passwordSubmitted && pendingOTPSubmitted &&
            authenticatedImmediatelyAfterPendingOTP
    }
}

enum TwoFARotationOutcome: Equatable, Sendable {
    case success(snapshot: SubscriptionSnapshot, proof: CleanLoginProof)
    case manualActionRequired(stage: RotationStage?, message: String)
    case failure(stage: RotationStage?, message: String)
}

@MainActor
protocol TwoFARotating: AnyObject {
    var maximumConcurrentRotations: Int { get }
    func cancelActiveOperation()
    func prepareBrowserSession(for account: AccountRecord)
    func rotate2FA(
        account: AccountRecord,
        onCheckpoint: @escaping @MainActor (RotationCheckpointEvent) throws -> Void
    ) async -> TwoFARotationOutcome
    func browserSession(for account: AccountRecord) -> BrowserSession?
}

extension TwoFARotating {
    var maximumConcurrentRotations: Int { 1 }
    func cancelActiveOperation() {}
    func prepareBrowserSession(for account: AccountRecord) {}
    func browserSession(for account: AccountRecord) -> BrowserSession? { nil }
}

@MainActor
@Observable
final class ChatGPTAutomation: SubscriptionChecking, TwoFARotating, PasswordChanging, BrowserRecoveryHandling, AccountSessionProviding {
    enum ExplicitLoginDecision: Equatable {
        case continueLogin
        case acceptAuthenticated
        case restartFreshSession
    }

    static func explicitLoginDecision(
        authenticated: Bool,
        proof: CleanLoginProof
    ) -> ExplicitLoginDecision {
        guard authenticated else { return .continueLogin }
        return proof.isSufficient ? .acceptAuthenticated : .restartFreshSession
    }

    static func manualMFACompletionProof(
        proof: CleanLoginProof,
        challengeObserved: Bool,
        authenticated: Bool
    ) -> CleanLoginProof {
        guard proof.passwordSubmitted, challengeObserved, authenticated else {
            return proof
        }
        var completed = proof
        completed.pendingOTPSubmitted = true
        completed.authenticatedImmediatelyAfterPendingOTP = true
        return completed
    }

    static let cleanLoginAuthenticationWaitSeconds = 30

    static func needsKeyboardMFAFallback(
        url: URL?,
        formResult: FormResult
    ) -> Bool {
        formResult == .notFound &&
            url?.host?.lowercased() == "auth.openai.com" &&
            url?.path.lowercased().hasPrefix("/mfa-challenge/") == true
    }

    static func shouldKeepAuthenticationSessionVisible(
        isVisible: Bool,
        url: URL?
    ) -> Bool {
        isVisible &&
            TrustedChatGPTOrigin.allowsAuthentication(url)
    }

    static func detectsSecurityChallenge(url: URL?, text: String) -> Bool {
        let urlText = url?.absoluteString.lowercased() ?? ""
        let pageText = text.lowercased()
        return urlText.contains("challenges.cloudflare.com") ||
            urlText.contains("challenge-platform") ||
            pageText.contains("challenge-platform") ||
            pageText.contains("turnstile") ||
            pageText.contains("сервис безопасности") ||
            pageText.contains("вредоносных ботов") ||
            pageText.contains("verify you are human") ||
            pageText.contains("проверка безопасности")
    }

    static func detectsAuthenticationServerError(url: URL?, text: String) -> Bool {
        guard url?.host?.lowercased() == "auth.openai.com" else { return false }
        let pageText = text.lowercased()
        return pageText.contains("server error 500") ||
            pageText.contains("ошибка сервера 500")
    }

    static func detectsAuthenticationCallbackError(url: URL?) -> Bool {
        guard url?.host?.lowercased() == "chatgpt.com" else { return false }
        return url?.path.lowercased() == "/auth/error"
    }

    static func detectsDeactivatedAccount(url: URL?, text: String) -> Bool {
        guard url?.host?.lowercased() == "auth.openai.com" else { return false }
        let pageText = text.lowercased()
        return pageText.contains("account_deactivated") ||
            pageText.contains("deleted or deactivated") ||
            pageText.contains("удалён или деактивирован") ||
            pageText.contains("удален или деактивирован")
    }

    static func detectsRejectedAuthenticatorCode(url: URL?, text: String) -> Bool {
        guard url?.host?.lowercased() == "auth.openai.com",
              url?.path.lowercased().hasPrefix("/mfa-challenge/") == true
        else { return false }
        let pageText = text.lowercased()
        return pageText.contains("неверный код") ||
            pageText.contains("incorrect code") ||
            pageText.contains("invalid code")
    }

    static func isEmailLoginChallenge(_ text: String) -> Bool {
        text.range(of: #"check your (email|inbox)|email (?:verification|code)|code (?:we |that we )?sent|sent (?:a |an |the )?code|код[^\n]*(?:почт|email|письм)|проверьте[^\n]*почт"#,
                   options: [.regularExpression, .caseInsensitive]) != nil
    }

    static func displaySession(
        accountID: UUID,
        verificationSessions: [UUID: BrowserSession],
        persistent: @autoclosure () -> BrowserSession
    ) -> BrowserSession {
        verificationSessions[accountID] ?? persistent()
    }

    private enum MetadataResult {
        case success(SubscriptionSnapshot)
        case loginRequired
        case unavailable
    }

    enum SavedSessionError: Error, LocalizedError {
        case pendingChange, wrongAccount, unavailable, proxyChanged

        var errorDescription: String? {
            switch self {
            case .pendingChange: "Сначала завершите изменение доступов аккаунта."
            case .wrongAccount: "Сохранённая сессия принадлежит другому аккаунту."
            case .unavailable: "Не удалось проверить сохранённую сессию. Повторите попытку."
            case .proxyChanged: "Прокси аккаунта изменился. Повторно откройте его сессию."
            }
        }
    }

    enum FormResult: String {
        case notFound
        case ambiguous
        case submitted
        case noForm
    }

    private enum MFAFrameResult: String {
        case notFound
        case ambiguous
        case noForm
        case ready
        case submitted
    }

    enum ControlResult: String {
        case notFound
        case ambiguous
        case found
        case clicked
    }

    enum LogoutAllSessionsResult: String {
        case completed
        case notFound
        case ambiguous
    }

    enum AuthenticatorSwitchResult: String {
        case notFound
        case ambiguous
        case on
        case off
        case clicked
    }

    enum AutomationContext {
        case authentication
        case security
    }

    private enum AuthenticationResult {
        case success(SubscriptionSnapshot)
        case manual(String)
        case failure(String)
    }

    enum ReauthenticationResult {
        case ready
        case manual(String)
        case cancelled
    }

    enum SignInResult {
        case success(SubscriptionSnapshot, CleanLoginProof)
        case manual(String, CleanLoginProof)
        case restart(String)
        case failure(String)
    }

    private let sessionManager: WebSessionManager
    private let passwordMailbox: (any EmailCodeReceiving)?
    private let makeExternalMailbox: @MainActor (ExternalMailboxConfiguration) -> any EmailCodeReceiving
    private var subscriptionCheckSessions: [UUID: BrowserSession] = [:]
    private var rotationSessions: [UUID: BrowserSession] = [:]
    private var preparedRotationSessionIDs: Set<UUID> = []
    private var unprovenRecoverySessionIDs: Set<UUID> = []
    private var verificationSessions: [UUID: BrowserSession] = [:]
    private var recoveryCandidateSessions: [UUID: BrowserSession] = [:]
    private var verificationProofs: [UUID: CleanLoginProof] = [:]
    private var manualMFAChallenges: [UUID: ObjectIdentifier] = [:]
    private var cancellationRequested = false
    private var passwordChangeStarted: Set<UUID> = []
    private var passwordFormOpened: Set<UUID> = []
    private var passwordChangeRetries: Set<UUID> = []
    private var passwordVerificationSessions: [UUID: BrowserSession] = [:]
    private var passwordEmailRequests: [ObjectIdentifier: PasswordEmailRequest] = [:]
    private var passwordReauthenticationStages: [UUID: Set<String>] = [:]
    private struct PasswordReauthenticationState {
        var originalIdentity: EmailChangeProof?
        var authenticationObserved = false
        var reopened = false
    }
    private var passwordReauthentication: [UUID: PasswordReauthenticationState] = [:]
    private var passwordMailboxGeneration = 0

    private var operationIsCancelled: Bool {
        cancellationRequested || Task.isCancelled
    }
    private let emailSelectors = ["input[type='email']", "input[name='username']"]
    private let passwordSelectors = ["input[type='password']"]
    private let otpSelectors = [
        "input[autocomplete='one-time-code']",
        "input[name*='otp' i]",
        "input[name='code']",
        "input[id='code']",
        "input[inputmode='numeric']",
    ]
    private let authenticatorLabels = [
        "Authenticator app", "Приложение-аутентификатор", "Приложение для аутентификации",
    ]
    private let setupDialogLabels = [
        "Connect your authenticator app",
        "Подключите приложение для аутентификации",
        "Добавьте свою учетную запись в приложение",
    ]
    private let removalDialogLabels = [
        "Remove authenticator app",
        "Удалить приложение для аутентификации",
    ]
    private let manageLabels = ["Manage", "Управлять"]
    private let disableLabels = ["Disable", "Turn off", "Отключить"]
    private let enableLabels = ["Enable", "Set up", "Включить", "Настроить"]
    private let confirmLabels = ["Continue", "Confirm", "Продолжить", "Подтвердить"]
    private let removalConfirmLabels = ["Remove", "Delete", "Удалить"]
    private let retryLabels = ["Try again", "Попробовать еще раз", "Попробовать ещё раз"]
    private let problemsScanningLabels = ["Problems scanning?", "Проблемы со сканированием?"]
    private let loginLabels = ["Log in", "Войти"]
    private let activeSessionsLabels = ["Active sessions", "Активные сеансы"]
    private let logoutAllSessionsLabels = [
        "Log out all devices",
        "Log out all",
        "Sign out all devices",
        "Sign out all",
        "Выйти из всех",
        "Выйти из всех сеансов",
        "Выйти со всех устройств",
        "Выйти на всех устройствах",
        "Завершить все сеансы",
    ]
    private let logoutAllConfirmationLabels = [
        "Log out",
        "Log out all",
        "Log out all devices",
        "Sign out",
        "Sign out all",
        "Sign out all devices",
        "Выйти",
        "Выйти из всех",
        "Выйти из всех сеансов",
        "Выйти со всех устройств",
        "Подтвердить",
    ]
    private let cookieConsentLabels = [
        "Сохранять только обязательные",
        "Сохранить только обязательные",
        "Сохранять только необходимые",
        "Только необходимые",
        "Only necessary",
        "Only required",
        "Reject optional cookies",
    ]

    private(set) var activeSession: BrowserSession?
    var maximumConcurrentRotations: Int { 1 }

    init(sessionManager: WebSessionManager, passwordMailbox: (any EmailCodeReceiving)? = nil,
         makeExternalMailbox: @escaping @MainActor (ExternalMailboxConfiguration) -> any EmailCodeReceiving = {
             ExternalMailboxCodeClient(configuration: $0)
         }) {
        self.sessionManager = sessionManager
        self.passwordMailbox = passwordMailbox
        self.makeExternalMailbox = makeExternalMailbox
    }

    func externalLoginMail(for account: AccountRecord, in session: BrowserSession) -> ExternalLoginMailRequest? {
        account.externalMailbox.map { ExternalLoginMailRequest(mailbox: makeExternalMailbox($0), email: account.email, in: session) }
    }

    func hasCandidateSession(for accountID: UUID) -> Bool {
        recoveryCandidateSessions[accountID] != nil
    }

    func recoverySession(
        for account: AccountRecord,
        context: BrowserRecoveryContext
    ) -> BrowserSession? {
        if account.rotationStage != .awaitingCleanLogin,
           let candidate = recoveryCandidateSessions[account.id] { return candidate }
        switch context {
        case .subscriptionCheck:
            return sessionManager.existingSession(for: account)
        case .rotation(stage: .awaitingCleanLogin):
            return verificationSessions[account.id] ?? rotationSessions[account.id]
        case .rotation:
            return rotationSessions[account.id]
        }
    }

    static func recoveryCandidateMatches(
        signedInEmail: String,
        accountEmail: String
    ) -> Bool {
        signedInEmail.caseInsensitiveCompare(accountEmail) == .orderedSame
    }

    private func replaceSubscriptionCheckSession(for account: AccountRecord) async {
        subscriptionCheckSessions[account.id]?.cancelLoading()
        subscriptionCheckSessions[account.id]?.setVisible(false)
        let session = await sessionManager.resetSession(for: account)
        subscriptionCheckSessions[account.id] = session
        activeSession = session
    }

    private func replaceRotationSession(for account: AccountRecord) {
        rotationSessions[account.id]?.cancelLoading()
        rotationSessions[account.id]?.setVisible(false)
        recoveryCandidateSessions[account.id]?.cancelLoading()
        recoveryCandidateSessions[account.id]?.setVisible(false)
        recoveryCandidateSessions.removeValue(forKey: account.id)
        let session = sessionManager.verificationSession(for: account)
        rotationSessions[account.id] = session
        preparedRotationSessionIDs.insert(account.id)
        unprovenRecoverySessionIDs.remove(account.id)
        activeSession = session
    }

    private func replaceCleanLoginSession(for account: AccountRecord) {
        verificationSessions[account.id]?.cancelLoading()
        verificationSessions[account.id]?.setVisible(false)
        verificationProofs.removeValue(forKey: account.id)
        manualMFAChallenges.removeValue(forKey: account.id)
        let session = sessionManager.verificationSession(for: account)
        verificationSessions[account.id] = session
        verificationProofs[account.id] = CleanLoginProof.none
        activeSession = session
    }

    func startFreshLogin(
        for account: AccountRecord,
        context: BrowserRecoveryContext
    ) async -> BrowserRecoveryResult {
        switch context {
        case .rotation(let stage) where stage != account.rotationStage:
            return .failure("Этап смены 2FA изменился. Повторно выберите действие восстановления.")
        case .subscriptionCheck where account.rotationStage != nil:
            return .failure("Сначала завершите восстановление смены 2FA.")
        default:
            break
        }
        let mode = BrowserRecoveryPolicy.availability(
            context: context,
            hasTrustedPage: false,
            hasCandidate: hasCandidateSession(for: account.id)).freshLoginMode
        switch mode {
        case .storedSecret:
            switch context {
            case .subscriptionCheck:
                await replaceSubscriptionCheckSession(for: account)
            case .rotation(stage: nil):
                replaceRotationSession(for: account)
            case .rotation:
                return .failure("Состояние смены 2FA не допускает автоматический старый код.")
            }
            return .readyToContinue("Новая сессия создана; вход запускается заново.")
        case .pendingSecret:
            guard account.rotationStage == .awaitingCleanLogin,
                  account.pendingTOTPSecret != nil
            else { return .failure("Ожидающий 2FA отсутствует; автоматический вход остановлен.") }
            replaceCleanLoginSession(for: account)
            return .readyToContinue("Проверочный вход с ожидающим 2FA запускается заново.")
        case .manualFactor:
            let candidate = sessionManager.verificationSession(for: account)
            recoveryCandidateSessions[account.id]?.cancelLoading()
            recoveryCandidateSessions[account.id]?.setVisible(false)
            rotationSessions[account.id]?.setVisible(false)
            recoveryCandidateSessions[account.id] = candidate
            activeSession = candidate
            candidate.setVisible(true)
            return .readyToContinue("Открыт новый вход без автоматической отправки старого 2FA.")
        }
    }

    func reloadRecoveryPage(
        for account: AccountRecord,
        context: BrowserRecoveryContext
    ) async -> BrowserRecoveryResult {
        guard let session = recoverySession(for: account, context: context),
              let navigation = session.reloadTrustedPage()
        else { return .manualAction("Нет доверенной страницы для обновления.") }
        guard await session.waitForNavigation(navigation, seconds: 30) else {
            return .manualAction("Страница не загрузилась. Используйте новый вход или продолжите вручную.")
        }
        return .readyToContinue("Страница обновлена; проверьте её и нажмите «Продолжить».")
    }

    func reopenExpectedPage(
        for account: AccountRecord,
        context: BrowserRecoveryContext
    ) async -> BrowserRecoveryResult {
        guard let session = recoverySession(for: account, context: context) else {
            return .manualAction("Открытая сессия недоступна.")
        }
        let availability = BrowserRecoveryPolicy.availability(
            context: context,
            hasTrustedPage: TrustedChatGPTOrigin.allowsAuthentication(session.webView.url),
            hasCandidate: hasCandidateSession(for: account.id))
        guard let destination = availability.reopenDestination else {
            return .manualAction("Для этого этапа используйте обновление или новый вход.")
        }
        let url = switch destination {
        case .chatGPT: URL(string: "https://chatgpt.com/")!
        case .security: Self.securitySettingsURL
        }
        guard let navigation = session.load(url),
              await session.waitForNavigation(navigation, seconds: 30)
        else { return .manualAction("Нужный раздел не загрузился.") }
        return .readyToContinue("Раздел открыт; проверьте его и нажмите «Продолжить».")
    }

    func returnToOriginalSession(for account: AccountRecord) {
        guard let candidate = recoveryCandidateSessions.removeValue(forKey: account.id) else { return }
        candidate.cancelLoading()
        candidate.setVisible(false)
        let original = verificationSessions[account.id]
            ?? rotationSessions[account.id]
            ?? subscriptionCheckSessions[account.id]
        activeSession = original
        original?.setVisible(true)
    }

    func browserSession(for account: AccountRecord) -> BrowserSession? {
        if let session = passwordVerificationSessions[account.id] { return session }
        if account.rotationStage != .awaitingCleanLogin,
           let candidate = recoveryCandidateSessions[account.id] { return candidate }
        if let verification = verificationSessions[account.id] {
            return verification
        }
        return rotationSessions[account.id] ?? sessionManager.session(for: account)
    }

    func prepareBrowserSession(for account: AccountRecord) {
        cancellationRequested = false
        let persistent = account.rotationStage == nil ? accountSession(for: account) : nil
        if account.rotationStage == .awaitingCleanLogin,
           let candidate = recoveryCandidateSessions.removeValue(forKey: account.id) {
            candidate.cancelLoading()
            candidate.setVisible(false)
        }
        if let existing = rotationSessions[account.id] {
            if account.rotationStage != nil {
                // A staged account may only continue in this exact WebView. Even a
                // blank or temporarily untrusted URL is evidence for manual
                // recovery, not a reason to silently replace the browser context.
                preparedRotationSessionIDs.insert(account.id)
                return
            }
            if existing.configuredProxy == persistent?.configuredProxy,
               (!existing.webView.configuration.websiteDataStore.isPersistent || existing === persistent),
               existing.webView.url == nil ||
                TrustedChatGPTOrigin.allowsAuthentication(existing.webView.url),
               existing.isVisible || preparedRotationSessionIDs.contains(account.id)
            {
                preparedRotationSessionIDs.insert(account.id)
                return
            }
        }
        rotationSessions[account.id] = persistent ?? sessionManager.verificationSession(for: account)
        preparedRotationSessionIDs.insert(account.id)
        if account.rotationStage != nil {
            unprovenRecoverySessionIDs.insert(account.id)
        } else {
            unprovenRecoverySessionIDs.remove(account.id)
        }
    }

    func accountSession(for account: AccountRecord) -> BrowserSession {
        sessionManager.session(for: account)
    }

    /// Probe saved sessions before OAuth without submitting credentials or changing its URL.
    func authorizationSession(for account: AccountRecord) async throws -> BrowserSession {
        guard account.rotationStage == nil, account.pendingTOTPSecret == nil,
              !account.hasPendingCredentialChange else { throw SavedSessionError.pendingChange }
        try Task.checkCancellation()
        let persistent = accountSession(for: account)
        var seen: Set<ObjectIdentifier> = [ObjectIdentifier(persistent)]
        let candidates = [unprovenRecoverySessionIDs.contains(account.id) ? nil : rotationSessions[account.id],
                          subscriptionCheckSessions[account.id]].compactMap { $0 }
        for candidate in candidates where seen.insert(ObjectIdentifier(candidate)).inserted {
            guard candidate.configuredProxy == persistent.configuredProxy,
                  TrustedChatGPTOrigin.allowsMetadata(candidate.webView.url) else { continue }
            let email: String?
            do { email = try await savedSessionEmail(in: candidate) }
            catch is CancellationError { throw CancellationError() }
            catch { continue }
            if email?.caseInsensitiveCompare(account.email) == .orderedSame {
                try await persistVerifiedSession(from: candidate, for: account)
                return persistent
            }
        }
        let generation = persistent.cancellationGeneration
        if !TrustedChatGPTOrigin.allowsMetadata(persistent.webView.url) {
            guard await persistent.loadInitialPage(URL(string: "https://chatgpt.com/")!, seconds: 10, attempts: 1)
            else {
                try Task.checkCancellation()
                guard generation == persistent.cancellationGeneration else { throw CancellationError() }
                throw SavedSessionError.unavailable
            }
        }
        try Task.checkCancellation()
        guard generation == persistent.cancellationGeneration else { throw CancellationError() }
        if TrustedChatGPTOrigin.allowsMetadata(persistent.webView.url),
           let email = try await savedSessionEmail(in: persistent),
           email.caseInsensitiveCompare(account.email) != .orderedSame { throw SavedSessionError.wrongAccount }
        return persistent
    }

    func hasAuthenticatedSession(for account: AccountRecord, in session: BrowserSession) async throws -> Bool {
        guard let email = try await savedSessionEmail(in: session) else { return false }
        guard email.caseInsensitiveCompare(account.email) == .orderedSame else { throw SavedSessionError.wrongAccount }
        return true
    }

    /// Finish registration in its existing saved session, without a second login.
    func registrationSetupSnapshot(for account: AccountRecord, in session: BrowserSession) async throws -> SubscriptionSnapshot {
        try Task.checkCancellation()
        guard TrustedChatGPTOrigin.allowsSecurityAutomation(session.webView.url), let url = session.webView.url else {
            throw SavedSessionError.unavailable
        }
        let generation = session.cancellationGeneration
        guard case .success(let snapshot) = try await metadata(in: session),
              !(try await hasSecurityChallenge(in: session)),
              await authenticatorSetupDialogIsVisible(in: session) == false,
              try await dismissOptionalAuthenticatorBackup(in: session, click: false) == .notFound,
              try await authenticatorAppearsEnabled(in: session) else { throw SavedSessionError.unavailable }
        try Task.checkCancellation()
        guard generation == session.cancellationGeneration, session.webView.url == url else { throw CancellationError() }
        guard snapshot.signedInEmail.caseInsensitiveCompare(account.email) == .orderedSame else { throw SavedSessionError.wrongAccount }
        return snapshot
    }

    /// Fetch only from this account's authenticated document; never log the returned bearer token.
    func accessToken(for account: AccountRecord, in session: BrowserSession) async throws -> String {
        try Task.checkCancellation()
        guard TrustedChatGPTOrigin.allowsMetadata(session.webView.url), let url = session.webView.url else {
            throw SavedSessionError.unavailable
        }
        let generation = session.cancellationGeneration
        let expectedURL = try Self.json(url.absoluteString)
        let expectedEmail = try Self.json(account.email.lowercased())
        let value = try await session.evaluate(#"""
        (async () => {
          const expectedURL = \#(expectedURL), expectedEmail = \#(expectedEmail);
          if (location.origin !== 'https://chatgpt.com' || location.href !== expectedURL) return {state:'unavailable'};
          try {
            const response = await fetch('/api/auth/session', {credentials:'include',cache:'no-store',redirect:'error'});
            if (!response.ok) return {state:'unavailable'};
            const data = await response.json();
            if (location.href !== expectedURL) return {state:'unavailable'};
            const email = data?.user?.email;
            if (typeof email !== 'string' || email.toLowerCase() !== expectedEmail) return {state:'wrongAccount'};
            const token = data?.accessToken;
            if (typeof token !== 'string' || !token.length || /[\s|\x00-\x1f\x7f]/.test(token)) return {state:'unavailable'};
            return {state:'success',token};
          } catch { return {state:'unavailable'}; }
        })()
        """#, timeout: .seconds(8))
        try Task.checkCancellation()
        guard generation == session.cancellationGeneration else { throw CancellationError() }
        guard session.webView.url == url, let result = value as? [String: Any] else { throw SavedSessionError.unavailable }
        if result["state"] as? String == "wrongAccount" { throw SavedSessionError.wrongAccount }
        guard result["state"] as? String == "success", let token = result["token"] as? String,
              !token.isEmpty, !token.contains("|"),
              token.rangeOfCharacter(from: .whitespacesAndNewlines.union(.controlCharacters)) == nil else {
            throw SavedSessionError.unavailable
        }
        return token
    }

    /// Return only identity, never API tokens; distinguish expired login from an unavailable server.
    private func savedSessionEmail(in session: BrowserSession) async throws -> String? {
        guard TrustedChatGPTOrigin.allowsMetadata(session.webView.url) else { throw SavedSessionError.unavailable }
        let url = session.webView.url
        let generation = session.cancellationGeneration
        let value = try await session.evaluate(#"""
        (async () => {
          const response = await fetch('/api/auth/session', {credentials:'include', cache:'no-store'});
          if (response.status === 401 || response.status === 403) return {state:'signedOut'};
          if (!response.ok) return {state:'unavailable'};
          const value = await response.json();
          const email = value?.user?.email;
          return typeof email === 'string' && email.length
            ? {state:'authenticated', email} : {state:'signedOut'};
        })()
        """#, timeout: .seconds(4))
        try Task.checkCancellation()
        guard generation == session.cancellationGeneration else { throw CancellationError() }
        guard session.webView.url == url, let result = value as? [String: Any] else { throw SavedSessionError.unavailable }
        if result["state"] as? String == "signedOut" { return nil }
        guard result["state"] as? String == "authenticated", let email = result["email"] as? String,
              !email.isEmpty else { throw SavedSessionError.unavailable }
        return email
    }

    private static func isSavedSessionCookie(_ cookie: HTTPCookie) -> Bool {
        let rawDomain = cookie.domain.lowercased()
        let domain = rawDomain.hasPrefix(".") ? String(rawDomain.dropFirst()) : rawDomain
        return ["chatgpt.com", "auth.openai.com", "openai.com"].contains(domain)
    }

    /// Promote only a live, matching login; fresh credential verification remains isolated until proven.
    func persistVerifiedSession(
        from source: BrowserSession,
        for account: AccountRecord,
        originalIdentity: EmailChangeProof? = nil
    ) async throws {
        let persistent = accountSession(for: account)
        let sourceGeneration = source.cancellationGeneration
        let destinationGeneration = persistent.cancellationGeneration
        let sourceURL = source.webView.url
        func checkCurrent() throws {
            try Task.checkCancellation()
            guard sourceGeneration == source.cancellationGeneration,
                  destinationGeneration == persistent.cancellationGeneration,
                  source.webView.url == sourceURL else { throw CancellationError() }
            guard source.configuredProxy == persistent.configuredProxy else { throw SavedSessionError.proxyChanged }
        }
        try checkCurrent()
        guard let email = try await savedSessionEmail(in: source) else { throw SavedSessionError.unavailable }
        guard email.caseInsensitiveCompare(account.email) == .orderedSame else { throw SavedSessionError.wrongAccount }
        if let originalIdentity {
            let identity = try await EmailChangeAutomation.identity(in: source)
            guard identity.userID == originalIdentity.userID else { throw SavedSessionError.wrongAccount }
        }
        try checkCurrent()
        if source === persistent { return }
        if !TrustedChatGPTOrigin.allowsMetadata(persistent.webView.url) {
            guard await persistent.loadInitialPage(URL(string: "https://chatgpt.com/")!, seconds: 10, attempts: 1) else {
                try checkCurrent()
                throw SavedSessionError.unavailable
            }
        }
        var destinationMatches = false
        if TrustedChatGPTOrigin.allowsMetadata(persistent.webView.url),
           let destinationEmail = try await savedSessionEmail(in: persistent) {
            if destinationEmail.caseInsensitiveCompare(account.email) == .orderedSame {
                if let originalIdentity {
                    guard try await EmailChangeAutomation.identity(in: persistent).userID == originalIdentity.userID
                    else { throw SavedSessionError.wrongAccount }
                }
                try checkCurrent()
                destinationMatches = true
            } else {
                guard let originalIdentity,
                      destinationEmail.caseInsensitiveCompare(originalIdentity.email) == .orderedSame,
                      try await EmailChangeAutomation.identity(in: persistent).userID == originalIdentity.userID
                else { throw SavedSessionError.wrongAccount }
            }
        }
        guard TrustedChatGPTOrigin.allowsAuthentication(persistent.webView.url) else { throw SavedSessionError.unavailable }
        let cookies = await source.webView.configuration.websiteDataStore.httpCookieStore.allCookies()
            .filter { Self.isSavedSessionCookie($0) && $0.isSecure && ($0.expiresDate.map { $0 > Date() } ?? true) }
        try checkCurrent()
        // ChatGPT identity alone does not prove the auth.openai.com SSO cookie
        // survived a password change. Promote the fresh verified cookie set.
        if cookies.isEmpty {
            guard destinationMatches else { throw SavedSessionError.unavailable }
            return
        }
        let store = persistent.webView.configuration.websiteDataStore.httpCookieStore
        let previous = await store.allCookies().filter(Self.isSavedSessionCookie)
        try checkCurrent()
        do {
            for cookie in previous {
                await store.deleteCookie(cookie)
                try checkCurrent()
            }
            for cookie in cookies {
                await store.setCookie(cookie)
                try checkCurrent()
            }
            guard await persistent.loadInitialPage(URL(string: "https://chatgpt.com/")!, seconds: 10, attempts: 1) else {
                try checkCurrent()
                throw SavedSessionError.unavailable
            }
            try checkCurrent()
            guard let savedEmail = try await savedSessionEmail(in: persistent) else { throw SavedSessionError.unavailable }
            guard savedEmail.caseInsensitiveCompare(account.email) == .orderedSame else { throw SavedSessionError.wrongAccount }
            if let originalIdentity {
                guard try await EmailChangeAutomation.identity(in: persistent).userID == originalIdentity.userID
                else { throw SavedSessionError.wrongAccount }
            }
            try checkCurrent()
        } catch {
            // Failed promotion must leave the saved profile's previous cookies intact.
            for cookie in await store.allCookies().filter(Self.isSavedSessionCookie) { await store.deleteCookie(cookie) }
            for cookie in previous { await store.setCookie(cookie) }
            throw error
        }
    }

    func verificationSession(for account: AccountRecord) -> BrowserSession {
        sessionManager.verificationSession(for: account)
    }

    func existingAccountSession(for account: AccountRecord) -> BrowserSession? {
        sessionManager.existingSession(for: account)
    }

    func subscriptionCheckSession(for account: AccountRecord) -> BrowserSession {
        let session = accountSession(for: account)
        subscriptionCheckSessions[account.id] = session
        return session
    }

    func newSubscriptionCheckSession(for account: AccountRecord) -> BrowserSession {
        for session in subscriptionCheckSessions.values {
            session.cancelLoading()
            session.setVisible(false)
        }
        let session = subscriptionCheckSession(for: account)
        session.endOAuth()
        return session
    }

    func cleanLoginSession(for account: AccountRecord) -> BrowserSession {
        if let existing = verificationSessions[account.id] {
            return existing
        }
        verificationProofs.removeValue(forKey: account.id)
        manualMFAChallenges.removeValue(forKey: account.id)

        let session = sessionManager.verificationSession(for: account)
        verificationSessions[account.id] = session
        verificationProofs[account.id] = CleanLoginProof.none
        return session
    }

    func finishSubscriptionCheck(accountID: UUID) {
        guard let session = subscriptionCheckSessions.removeValue(forKey: accountID) else {
            return
        }
        session.setVisible(false)
        if activeSession === session {
            activeSession = nil
        }
    }

    func twoFARotationSession(for account: AccountRecord) -> BrowserSession {
        let persistent = account.rotationStage == nil ? accountSession(for: account) : nil
        if let existing = rotationSessions[account.id] {
            if account.rotationStage != nil {
                preparedRotationSessionIDs.remove(account.id)
                return existing
            }
            if existing.configuredProxy == persistent?.configuredProxy,
               (!existing.webView.configuration.websiteDataStore.isPersistent || existing === persistent),
               (preparedRotationSessionIDs.contains(account.id) || existing.isVisible),
               existing.webView.url == nil ||
                TrustedChatGPTOrigin.allowsAuthentication(existing.webView.url)
            {
                preparedRotationSessionIDs.remove(account.id)
                return existing
            }
        }
        let session = persistent ?? sessionManager.verificationSession(for: account)
        rotationSessions[account.id] = session
        preparedRotationSessionIDs.remove(account.id)
        if account.rotationStage != nil {
            unprovenRecoverySessionIDs.insert(account.id)
        } else {
            unprovenRecoverySessionIDs.remove(account.id)
        }
        return session
    }

    func rotationRecoverySessionState(
        for account: AccountRecord
    ) -> RotationRecoverySessionState {
        guard account.rotationStage != nil,
              rotationSessions[account.id] != nil,
              !unprovenRecoverySessionIDs.contains(account.id)
        else { return .unavailable }
        return .authenticated
    }

    func check(account: AccountRecord) async -> SubscriptionCheckOutcome {
        await check(
            account: account,
            in: newSubscriptionCheckSession(for: account))
    }

    func continueCheck(account: AccountRecord) async -> SubscriptionCheckOutcome {
        await check(
            account: account,
            in: subscriptionCheckSession(for: account))
    }

    func accessTokenAfterCheck(for account: AccountRecord) async throws -> String? {
        guard !operationIsCancelled,
              let session = subscriptionCheckSessions[account.id], activeSession === session,
              session.configuredProxy == account.proxy else { throw SavedSessionError.unavailable }
        let token = try await accessToken(for: account, in: session)
        guard !operationIsCancelled, subscriptionCheckSessions[account.id] === session,
              activeSession === session else { throw CancellationError() }
        return token
    }

    private func check(
        account: AccountRecord,
        in session: BrowserSession
    ) async -> SubscriptionCheckOutcome {
        cancellationRequested = false
        activeSession = session
        let isResumingAuthentication = !session.needsInitialPageLoad && Self.shouldKeepAuthenticationSessionVisible(
            isVisible: session.isVisible,
            url: session.webView.url)
        session.setVisible(true)
        if !isResumingAuthentication {
            guard await loadAndWait(
                URL(string: "https://chatgpt.com/")!,
                in: session,
                seconds: 30)
            else {
                if operationIsCancelled {
                    finishSubscriptionCheck(accountID: account.id)
                    return .failure("Stopped")
                }
                return requireManual(session, session.pageLoadMessage ?? "ChatGPT не загрузился. Нажмите «Обновить страницу» и продолжите проверку.")
            }
        }

        do {
            switch try await metadata(in: session) {
            case .success(let snapshot):
                return await verifiedSubscription(
                    snapshot,
                    for: account,
                    session: session)
            case .loginRequired:
                break
            case .unavailable:
                return requireManual(session, SavedSessionError.unavailable.localizedDescription)
            }
        } catch {
            if TrustedChatGPTOrigin.allowsMetadata(session.webView.url) {
                return requireManual(session, SavedSessionError.unavailable.localizedDescription)
            }
        }

        switch await signIn(account: account, secret: account.totpSecret, in: session) {
        case .success(let snapshot, _):
            return await verifiedSubscription(
                snapshot,
                for: account,
                session: session)
        case .manual(let message, _):
            return requireManual(session, message)
        case .restart(let message):
            return requireManual(session, message)
        case .failure(let message):
            finishSubscriptionCheck(accountID: account.id)
            return .failure(message)
        }
    }

    func cancelActiveOperation() {
        cancellationRequested = true
        passwordMailboxGeneration += 1
        passwordMailbox?.cancel()
        var sessions = Array(rotationSessions.values)
        sessions.append(contentsOf: verificationSessions.values)
        sessions.append(contentsOf: passwordVerificationSessions.values)
        if let activeSession, !sessions.contains(where: { $0 === activeSession }) {
            sessions.append(activeSession)
        }
        for session in sessions {
            session.cancelLoading()
            session.setVisible(false)
        }
    }

    func probeRecoverySession(
        account: AccountRecord,
        in session: BrowserSession
    ) async -> RecoverySessionProbeResult {
        guard account.rotationStage != nil else {
            return .manual("This browser session is not a staged 2FA recovery session.")
        }
        guard rotationRecoverySessionState(for: account) == .authenticated,
              rotationSessions[account.id] === session
        else {
            return .manual(
                "The original 2FA browser session is unavailable. Reopen the account manually using its email or recovery method.")
        }
        guard let url = session.webView.url else {
            return .manual(
                "The original 2FA browser session has no active page. Reopen the account manually using its email or recovery method.")
        }
        guard TrustedChatGPTOrigin.allowsAuthentication(url) else {
            return .manual("The recovery browser is on an untrusted page. Return to ChatGPT Security settings manually.")
        }
        guard url.host?.lowercased() == "chatgpt.com" else {
            return .manual(
                "OpenAI is asking for identity confirmation again. Complete it manually in the same browser session.")
        }

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(8))
        while clock.now < deadline {
            if operationIsCancelled { return .cancelled }
            guard TrustedChatGPTOrigin.allowsAuthentication(session.webView.url) else {
                return .manual("The recovery browser left the trusted ChatGPT pages. Continue manually.")
            }
            guard session.webView.url?.host?.lowercased() == "chatgpt.com" else {
                return .manual(
                    "OpenAI is asking for identity confirmation again. Complete it manually in the same browser session.")
            }

            do {
                switch try await metadata(in: session) {
                case .success(let snapshot):
                    guard snapshot.signedInEmail.caseInsensitiveCompare(account.email) == .orderedSame else {
                        return .manual("The open browser session belongs to a different account. Continue manually.")
                    }
                    return .authenticated
                case .loginRequired:
                    return .manual(
                        "The original browser session is no longer signed in. Reopen the account manually using its email or recovery method.")
                case .unavailable:
                    break
                }
            } catch {}

            try? await Task.sleep(for: .milliseconds(200))
        }
        if operationIsCancelled { return .cancelled }
        return .manual(
            "The original authenticated browser session could not be verified. Continue the 2FA recovery manually.")
    }

    func rotate2FA(
        account: AccountRecord,
        onCheckpoint: @escaping @MainActor (RotationCheckpointEvent) throws -> Void
    ) async -> TwoFARotationOutcome {
        if operationIsCancelled {
            return .failure(stage: account.rotationStage, message: "Stopped")
        }
        if let candidateOutcome = await adoptRecoveryCandidateIfReady(for: account) {
            return candidateOutcome
        }
        let session = twoFARotationSession(for: account)
        activeSession = session
        session.setVisible(true)
        var working = account

        if operationIsCancelled {
            return .failure(stage: working.rotationStage, message: "Stopped")
        }

        do {
            switch working.rotationStage {
            case .awaitingCleanLogin:
                return await performCleanLogin(account: working, in: session)

            case .pendingSecretCaptured:
                return await resumePendingSetup(
                    account: working,
                    in: session,
                    onCheckpoint: onCheckpoint)

            case .removingOldMethod:
                return await resumeRemoval(
                    account: working,
                    in: session,
                    onCheckpoint: onCheckpoint)

            case .oldMethodDisabled:
                return await resumeDisabledSetup(
                    account: working,
                    in: session,
                    onCheckpoint: onCheckpoint)

            case nil:
                switch await authenticate(account: working, secret: working.totpSecret, in: session) {
                case .success:
                    break
                case .manual(let message):
                    return .manualActionRequired(stage: nil, message: message)
                case .failure(let message):
                    return .failure(stage: nil, message: message)
                }

                guard await openSecuritySettings(in: session, seconds: 30) else {
                    return .manualActionRequired(
                        stage: nil,
                        message: "Security settings did not finish loading. Continue in the browser.")
                }

                switch try await authenticatorSwitch(click: false, in: session) {
                case .on:
                    let externalMail = externalLoginMail(for: working, in: session)
                    let toggle = try await ExternalLoginMailRequest.performTrigger(
                        request: externalMail, in: session, from: session.webView.url,
                        skipped: .notFound, wasSubmitted: { $0 == .clicked }
                    ) {
                        try onCheckpoint(.removalStarted)
                        RotationState.markRemovalStarted(in: &working)
                        return try await authenticatorSwitch(click: true, in: session, expectedState: .on)
                    }
                    guard toggle == .clicked else {
                        return .manualActionRequired(
                            stage: working.rotationStage,
                            message: "The authenticator switch changed. Continue manually.")
                    }
                    await waitAfterSubmission(in: session)
                    return await continueRemoval(
                        account: &working,
                        in: session,
                        allowAutomaticOldCode: true,
                        externalMail: externalMail,
                        onCheckpoint: onCheckpoint)
                case .off:
                    try markOldMethodDisabled(
                        in: &working,
                        onCheckpoint: onCheckpoint)
                    return await beginNewSetup(
                        account: &working,
                        in: session,
                        onCheckpoint: onCheckpoint)
                case .ambiguous, .clicked:
                    return .manualActionRequired(
                        stage: nil,
                        message: "The authenticator switch could not be identified uniquely.")
                case .notFound:
                    break
                }

                let authenticator = try await clickUniqueControl(
                    labels: authenticatorLabels,
                    click: true,
                    in: session)
                guard authenticator == .clicked else {
                    return .manualActionRequired(
                        stage: nil,
                        message: "Open the unique Authenticator app control in the browser.")
                }
                await waitAfterSubmission(in: session)

                let manage = try await clickUniqueControl(
                    labels: manageLabels,
                    click: true,
                    in: session)
                guard manage == .clicked else {
                    return .manualActionRequired(
                        stage: nil,
                        message: "Open the unique authenticator management control in the browser.")
                }
                await waitAfterSubmission(in: session)

                return await continueRemoval(
                    account: &working,
                    in: session,
                    allowAutomaticOldCode: true,
                    onCheckpoint: onCheckpoint)
            }
        } catch {
            if operationIsCancelled {
                return .failure(stage: working.rotationStage, message: "Stopped")
            }
            return .failure(
                stage: working.rotationStage,
                message: "2FA rotation stopped before the next verified checkpoint.")
        }
    }

    private func promoteRecoveryCandidate(
        _ candidate: BrowserSession,
        snapshot: SubscriptionSnapshot,
        account: AccountRecord
    ) -> TwoFARotationOutcome? {
        guard !operationIsCancelled else {
            return .failure(stage: account.rotationStage, message: "Stopped")
        }
        guard Self.recoveryCandidateMatches(
            signedInEmail: snapshot.signedInEmail,
            accountEmail: account.email)
        else {
            return .failure(
                stage: account.rotationStage,
                message: "Новая сессия открыта для другого аккаунта.")
        }
        rotationSessions[account.id]?.cancelLoading()
        rotationSessions[account.id]?.setVisible(false)
        rotationSessions[account.id] = candidate
        recoveryCandidateSessions.removeValue(forKey: account.id)
        unprovenRecoverySessionIDs.remove(account.id)
        activeSession = candidate
        return nil
    }

    private func adoptRecoveryCandidateIfReady(
        for account: AccountRecord
    ) async -> TwoFARotationOutcome? {
        guard let candidate = recoveryCandidateSessions[account.id] else { return nil }
        activeSession = candidate
        candidate.setVisible(true)

        if candidate.webView.url == nil {
            guard await loadAndWait(
                URL(string: "https://chatgpt.com/")!,
                in: candidate,
                seconds: 30)
            else {
                return .manualActionRequired(
                    stage: account.rotationStage,
                    message: "Новая страница входа не загрузилась. Обновите её вручную.")
            }
        }

        if let metadataResult = try? await metadata(in: candidate),
           case .success(let snapshot) = metadataResult {
            return promoteRecoveryCandidate(candidate, snapshot: snapshot, account: account)
        }

        defer { candidate.setOperationMessage(nil) }
        switch await signIn(
            account: account,
            secret: account.totpSecret,
            in: candidate,
            automaticallySubmitOTP: false,
            waitForManualFactor: true)
        {
        case .success(let snapshot, _):
            return promoteRecoveryCandidate(candidate, snapshot: snapshot, account: account)
        case .manual(let message, _), .restart(let message):
            return .manualActionRequired(stage: account.rotationStage, message: message)
        case .failure(let message):
            return .failure(stage: account.rotationStage, message: message)
        }
    }

    private func resumeRemoval(
        account: AccountRecord,
        in session: BrowserSession,
        onCheckpoint: @escaping @MainActor (RotationCheckpointEvent) throws -> Void
    ) async -> TwoFARotationOutcome {
        if operationIsCancelled {
            return .failure(stage: .removingOldMethod, message: "Stopped")
        }
        var working = account
        let externalMail = externalLoginMail(for: working, in: session)
        if session.webView.url?.host?.lowercased() == "auth.openai.com",
           rotationSessions[account.id] === session,
           rotationRecoverySessionState(for: account) == .authenticated {
            switch await completeSecurityReauthentication(
                account: account, in: session, externalMail: externalMail, allowAutomaticOldCode: false
            ) {
            case .ready: break
            case .manual(let message): return .manualActionRequired(stage: .removingOldMethod, message: message)
            case .cancelled: return .failure(stage: .removingOldMethod, message: "Stopped")
            }
        }
        switch await probeRecoverySession(account: working, in: session) {
        case .authenticated:
            break
        case .manual(let message):
            return .manualActionRequired(stage: .removingOldMethod, message: message)
        case .cancelled:
            return .failure(stage: .removingOldMethod, message: "Stopped")
        }
        if operationIsCancelled {
            return .failure(stage: .removingOldMethod, message: "Stopped")
        }

        guard await openSecuritySettings(in: session, seconds: 30) else {
            return .manualActionRequired(
                stage: .removingOldMethod,
                message: "Open Security settings and continue.")
        }

        do {
            // Reauthentication returns to a URL carrying action=disable and an
            // already-open confirmation dialog. Handle that dialog before
            // inspecting or toggling the switch; reloading/toggling here would
            // restart the removal flow and ask for the old code again.
            let pendingRemoval = try await clickUniqueControl(
                labels: removalConfirmLabels,
                click: false,
                in: session)
            if pendingRemoval != .notFound {
                return await continueRemoval(
                    account: &working,
                    in: session,
                    allowAutomaticOldCode: false,
                    onCheckpoint: onCheckpoint)
            }

            switch try await authenticatorSwitch(click: false, in: session) {
            case .off:
                guard RotationRecoveryPolicy.decision(
                    stage: .removingOldMethod,
                    session: rotationRecoverySessionState(for: working),
                    authenticatorEnabled: false) == .continueSetup
                else {
                    return .manualActionRequired(
                        stage: .removingOldMethod,
                        message: "The original authenticated browser session is unavailable.")
                }
                try markOldMethodDisabled(in: &working, onCheckpoint: onCheckpoint)
                return await beginNewSetup(
                    account: &working,
                    in: session,
                    onCheckpoint: onCheckpoint)
            case .on:
                guard RotationRecoveryPolicy.decision(
                    stage: .removingOldMethod,
                    session: rotationRecoverySessionState(for: working),
                    authenticatorEnabled: true) == .continueRemoval
                else {
                    return .manualActionRequired(
                        stage: .removingOldMethod,
                        message: "The original authenticated browser session is unavailable.")
                }
                let toggle = try await ExternalLoginMailRequest.performTrigger(
                    request: externalMail, in: session, from: session.webView.url,
                    skipped: .notFound, wasSubmitted: { $0 == .clicked }
                ) {
                    try await authenticatorSwitch(click: true, in: session, expectedState: .on)
                }
                guard toggle == .clicked else {
                    return .manualActionRequired(
                        stage: .removingOldMethod,
                        message: "The authenticator switch changed. Continue manually.")
                }
                await waitAfterSubmission(in: session)
                return await continueRemoval(
                    account: &working,
                    in: session,
                    allowAutomaticOldCode: false,
                    externalMail: externalMail,
                    onCheckpoint: onCheckpoint)
            case .ambiguous, .clicked:
                return .manualActionRequired(
                    stage: .removingOldMethod,
                    message: "The authenticator switch could not be identified uniquely.")
            case .notFound:
                break
            }

            let enable = try await clickUniqueControl(labels: enableLabels, click: false, in: session)
            if enable == .found {
                guard RotationRecoveryPolicy.decision(
                    stage: .removingOldMethod,
                    session: rotationRecoverySessionState(for: working),
                    authenticatorEnabled: false) == .continueSetup
                else {
                    return .manualActionRequired(
                        stage: .removingOldMethod,
                        message: "The original authenticated browser session is unavailable.")
                }
                try markOldMethodDisabled(in: &working, onCheckpoint: onCheckpoint)
                return await beginNewSetup(
                    account: &working,
                    in: session,
                    onCheckpoint: onCheckpoint)
            }
            if enable == .ambiguous {
                return .manualActionRequired(
                    stage: .removingOldMethod,
                    message: "More than one setup control is visible. Continue manually.")
            }

            let authenticator = try await clickUniqueControl(
                labels: authenticatorLabels,
                click: true,
                in: session)
            guard authenticator == .clicked else {
                return .manualActionRequired(
                    stage: .removingOldMethod,
                    message: "Open the unique Authenticator app control in the browser.")
            }
            await waitAfterSubmission(in: session)
            let manage = try await clickUniqueControl(labels: manageLabels, click: true, in: session)
            guard manage == .clicked else {
                return .manualActionRequired(
                    stage: .removingOldMethod,
                    message: "Open the unique authenticator management control in the browser.")
            }
            await waitAfterSubmission(in: session)
            return await continueRemoval(
                account: &working,
                in: session,
                allowAutomaticOldCode: false,
                onCheckpoint: onCheckpoint)
        } catch {
            if operationIsCancelled {
                return .failure(stage: working.rotationStage, message: "Stopped")
            }
            return .manualActionRequired(
                stage: working.rotationStage ?? .removingOldMethod,
                message: "Inspect the current 2FA state in the browser and continue.")
        }
    }

    private func resumeDisabledSetup(
        account: AccountRecord,
        in session: BrowserSession,
        onCheckpoint: @escaping @MainActor (RotationCheckpointEvent) throws -> Void
    ) async -> TwoFARotationOutcome {
        if operationIsCancelled {
            return .failure(stage: .oldMethodDisabled, message: "Stopped")
        }
        var working = account
        if let blocked = await prepareRotationEnrollmentResume(account: working, in: session) {
            return blocked
        }
        if session.webView.url?.host?.lowercased() == "chatgpt.com",
           !TrustedChatGPTOrigin.allowsSecurityAutomation(session.webView.url),
           !(await openSecuritySettings(in: session, seconds: 30)) {
            return .manualActionRequired(
                stage: .oldMethodDisabled,
                message: "Откройте настройки безопасности в подтверждённой сессии аккаунта.")
        }
        return await beginNewSetup(account: &working, in: session, onCheckpoint: onCheckpoint)
    }

    private func markOldMethodDisabled(
        in account: inout AccountRecord,
        onCheckpoint: @escaping @MainActor (RotationCheckpointEvent) throws -> Void
    ) throws {
        guard account.rotationStage != .oldMethodDisabled else { return }
        try onCheckpoint(.oldMethodDisabled)
        RotationState.markOldMethodDisabled(in: &account)
    }

    private func continueRemoval(
        account: inout AccountRecord,
        in session: BrowserSession,
        allowAutomaticOldCode: Bool,
        externalMail: ExternalLoginMailRequest? = nil,
        onCheckpoint: @escaping @MainActor (RotationCheckpointEvent) throws -> Void
    ) async -> TwoFARotationOutcome {
        if operationIsCancelled {
            return .failure(stage: account.rotationStage, message: "Stopped")
        }
        do {
            if session.webView.url?.host?.lowercased() == "auth.openai.com" {
                switch await completeSecurityReauthentication(
                    account: account,
                    in: session,
                    externalMail: externalMail,
                    allowAutomaticOldCode: allowAutomaticOldCode
                ) {
                case .ready:
                    break
                case .manual(let message):
                    return .manualActionRequired(stage: .removingOldMethod, message: message)
                case .cancelled:
                    return .failure(stage: .removingOldMethod, message: "Stopped")
                }
            }

            let remove = try await clickUniqueControl(
                labels: removalConfirmLabels,
                click: false,
                in: session)
            if remove == .ambiguous {
                return .manualActionRequired(
                    stage: .removingOldMethod,
                    message: "The authenticator removal confirmation is ambiguous.")
            }
            if remove == .found {
                try onCheckpoint(.removalStarted)
                RotationState.markRemovalStarted(in: &account)
                guard try await clickUniqueControl(
                    labels: removalConfirmLabels,
                    click: true,
                    in: session) == .clicked
                else {
                    return .manualActionRequired(
                        stage: .removingOldMethod,
                        message: "Confirm removal of the old authenticator in the browser.")
                }
                await waitAfterSubmission(in: session)
                guard await waitForAuthenticatorSwitch(.off, in: session, seconds: 10) else {
                    return .manualActionRequired(
                        stage: .removingOldMethod,
                        message: "Confirm that the old authenticator is disabled, then continue.")
                }
                try markOldMethodDisabled(in: &account, onCheckpoint: onCheckpoint)
                return await beginNewSetup(
                    account: &account,
                    in: session,
                    onCheckpoint: onCheckpoint)
            }

            let disable = try await clickUniqueControl(labels: disableLabels, click: false, in: session)
            guard disable == .found else {
                return .manualActionRequired(
                    stage: account.rotationStage,
                    message: "The current authenticator method could not be identified uniquely.")
            }

            try onCheckpoint(.removalStarted)
            RotationState.markRemovalStarted(in: &account)

            guard try await clickUniqueControl(
                labels: disableLabels,
                click: true,
                in: session) == .clicked
            else {
                return .manualActionRequired(
                    stage: .removingOldMethod,
                    message: "The disable control changed. Continue manually.")
            }
            await waitAfterSubmission(in: session)

            guard allowAutomaticOldCode else {
                return .manualActionRequired(
                    stage: .removingOldMethod,
                    message: "Enter the current authenticator code manually in this same browser session, then continue.")
            }
            let oldCode = try TOTPService.code(secret: account.totpSecret)
            let otp = try await fillAndSubmit(
                selectors: otpSelectors,
                value: oldCode,
                context: .security,
                in: session)
            guard otp == .submitted else {
                return .manualActionRequired(
                    stage: .removingOldMethod,
                    message: "Enter the current authenticator code in the browser, then continue.")
            }
            await waitAfterSubmission(in: session)

            let confirm = try await clickUniqueControl(labels: confirmLabels, click: true, in: session)
            guard confirm == .clicked else {
                return .manualActionRequired(
                    stage: .removingOldMethod,
                    message: "Use the unique authenticator confirmation control in the browser.")
            }
            await waitAfterSubmission(in: session)

            switch try await authenticatorSwitch(click: false, in: session) {
            case .off:
                try markOldMethodDisabled(in: &account, onCheckpoint: onCheckpoint)
                return await beginNewSetup(
                    account: &account,
                    in: session,
                    onCheckpoint: onCheckpoint)
            case .on:
                return .manualActionRequired(
                    stage: .removingOldMethod,
                    message: "Confirm that the old authenticator is disabled, then continue.")
            case .ambiguous, .clicked:
                return .manualActionRequired(
                    stage: .removingOldMethod,
                    message: "The authenticator switch could not be verified uniquely.")
            case .notFound:
                break
            }

            let enable = try await clickUniqueControl(labels: enableLabels, click: false, in: session)
            guard enable == .found else {
                return .manualActionRequired(
                    stage: .removingOldMethod,
                    message: "Confirm that the old authenticator is disabled, then continue.")
            }
            try markOldMethodDisabled(in: &account, onCheckpoint: onCheckpoint)
            return await beginNewSetup(
                account: &account,
                in: session,
                onCheckpoint: onCheckpoint)
        } catch {
            if operationIsCancelled {
                return .failure(stage: account.rotationStage, message: "Stopped")
            }
            return .manualActionRequired(
                stage: account.rotationStage,
                message: "Complete the current 2FA step in the browser, then continue.")
        }
    }

    func enrollNewAuthenticator(
        in session: BrowserSession,
        pendingSecret: String?,
        automaticallyWaitForTransitions: Bool = false,
        transitionTimeoutSeconds: Int = 45,
        humanChallengeTimeoutSeconds: Int = 300,
        beforeSetup: (@MainActor (BrowserSession) async throws -> Bool)? = nil,
        reauthenticationHandler: (@MainActor (BrowserSession) async throws -> Bool)? = nil,
        rotationMail: ExternalLoginMailRequest? = nil,
        rotationReauthentication: (@MainActor () async -> ReauthenticationResult)? = nil,
        onSecret: @MainActor (String) throws -> Void
    ) async -> RegistrationMFAResult {
        if rotationReauthentication == nil { cancellationRequested = false }
        let generation = session.cancellationGeneration
        let clock = ContinuousClock()
        var limit = clock.now.advanced(by: .seconds(transitionTimeoutSeconds + humanChallengeTimeoutSeconds))
        var deadline = clock.now.advanced(by: .seconds(transitionTimeoutSeconds))
        var waitingForHuman = false
        var secret = pendingSecret.map(TOTPService.normalizedSecret)
        var setupStarted = false
        var introductionAdvanced = false
        var qrAdvanced = false
        var secretChecked = false
        var codeSubmitted = false
        var confirmationClicked = false
        var backupPromptDismissed = false
        var enabledSince: ContinuousClock.Instant?
        let reauthenticationToken = UUID().uuidString
        var reauthenticationSubmittedURL: URL?
        if let secret, !TOTPService.isValidSecret(secret) {
            return .failure("Сохранённый ожидающий ключ 2FA недействителен.")
        }
        while clock.now < deadline && clock.now < limit {
            guard !operationIsCancelled, generation == session.cancellationGeneration else {
                return .failure("Подключение 2FA остановлено.")
            }
            if rotationReauthentication != nil, session.webView.isLoading {
                try? await Task.sleep(for: .milliseconds(200))
                continue
            }
            guard TrustedChatGPTOrigin.allowsAuthentication(session.webView.url) else {
                return .manual("Откройте настройки безопасности ChatGPT и продолжите подключение 2FA.")
            }
            do {
                let challenge = try await hasSecurityChallenge(in: session)
                let reauthentication = session.webView.url?.host?.lowercased() == "auth.openai.com"
                if reauthentication, !challenge, let rotationReauthentication {
                    switch await rotationReauthentication() {
                    case .ready:
                        setupStarted = true
                        limit = clock.now.advanced(by: .seconds(transitionTimeoutSeconds + humanChallengeTimeoutSeconds))
                        deadline = clock.now.advanced(by: .seconds(transitionTimeoutSeconds))
                        continue
                    case .manual(let message): return .manual(message)
                    case .cancelled: return .failure("Подключение 2FA остановлено.")
                    }
                }
                if reauthentication, !challenge, let reauthenticationHandler {
                    let state = try await RegistrationForm.inspect(in: session)
                    if state.kind == .emailCode, let pageURL = state.pageURL, pageURL == session.webView.url {
                        var alreadySubmitted = false
                        if reauthenticationSubmittedURL == pageURL {
                            alreadySubmitted = try await RegistrationForm.emailCodeScreenMatches(in: session, expectedEmail: state.displayedEmail ?? "",
                                                                                                pageURL: pageURL, token: reauthenticationToken,
                                                                                                identityKey: "__gptAccountManagerEnrollmentReauthentication")
                        }
                        if !alreadySubmitted {
                            guard try await RegistrationForm.emailCodeScreenMatches(in: session, expectedEmail: state.displayedEmail ?? "",
                                                                                   pageURL: pageURL, token: reauthenticationToken, capture: true,
                                                                                   identityKey: "__gptAccountManagerEnrollmentReauthentication") else { continue }
                            if try await reauthenticationHandler(session) {
                                reauthenticationSubmittedURL = pageURL
                                limit = clock.now.advanced(by: .seconds(transitionTimeoutSeconds + humanChallengeTimeoutSeconds))
                                deadline = clock.now.advanced(by: .seconds(transitionTimeoutSeconds))
                            } else if session.webView.url != pageURL {
                                limit = clock.now.advanced(by: .seconds(transitionTimeoutSeconds + humanChallengeTimeoutSeconds))
                                deadline = clock.now.advanced(by: .seconds(transitionTimeoutSeconds))
                            }
                            try Task.checkCancellation()
                            guard !operationIsCancelled, generation == session.cancellationGeneration else {
                                return .failure("Подключение 2FA остановлено.")
                            }
                        }
                        try await Task.sleep(for: .milliseconds(250))
                        continue
                    }
                }
                if challenge || reauthentication {
                    guard automaticallyWaitForTransitions else {
                        return .manual("Завершите проверку OpenAI в открытом браузере.")
                    }
                    if !waitingForHuman {
                        waitingForHuman = true
                        deadline = min(limit, clock.now.advanced(by: .seconds(humanChallengeTimeoutSeconds)))
                        session.setVisible(true)
                        session.setOperationMessage("Завершите проверку OpenAI в браузере. Подключение 2FA продолжится автоматически.")
                    }
                    try await Task.sleep(for: .milliseconds(250))
                    continue
                }
                if waitingForHuman {
                    waitingForHuman = false
                    deadline = min(limit, clock.now.advanced(by: .seconds(transitionTimeoutSeconds)))
                }
                if TrustedChatGPTOrigin.allowsSecurityAutomation(session.webView.url) {
                    let canAdvance = !introductionAdvanced && secret == nil
                    let introduction: ControlResult
                    if let rotationMail, canAdvance {
                        let probe = try await AuthenticatorSetupIntroduction.advance(in: session, click: false)
                        if probe == .found {
                            introduction = try await ExternalLoginMailRequest.performTrigger(
                                request: rotationMail, in: session, from: session.webView.url,
                                skipped: .notFound, wasSubmitted: { $0 == .clicked }
                            ) {
                                try await AuthenticatorSetupIntroduction.advance(in: session)
                            }
                        } else {
                            introduction = probe
                        }
                    } else {
                        introduction = try await AuthenticatorSetupIntroduction.advance(in: session, click: canAdvance)
                    }
                    switch introduction {
                    case .clicked:
                        introductionAdvanced = true
                        setupStarted = true
                        deadline = min(limit, clock.now.advanced(by: .seconds(transitionTimeoutSeconds)))
                        await waitAfterSubmission(in: session)
                        continue
                    case .found:
                        guard secret == nil else {
                            return .manual("Ожидающий ключ 2FA уже сохранён. Новый выпуск ключа не запущен.")
                        }
                        try await Task.sleep(for: .milliseconds(200))
                        continue
                    case .ambiguous:
                        return .manual("Вводный шаг подключения 2FA неоднозначен. Проверьте открытый браузер.")
                    case .notFound: break
                    }
                    if secret != nil {
                        switch try await dismissOptionalAuthenticatorBackup(in: session, click: !backupPromptDismissed) {
                        case .clicked:
                            backupPromptDismissed = true
                            enabledSince = nil
                            deadline = min(limit, clock.now.advanced(by: .seconds(transitionTimeoutSeconds)))
                            await waitAfterSubmission(in: session)
                            continue
                        case .found:
                            enabledSince = nil
                            try await Task.sleep(for: .milliseconds(200))
                            continue
                        case .ambiguous:
                            return .manual("Предложение резервного способа 2FA неоднозначно. Проверьте открытый браузер.")
                        case .notFound:
                            break
                        }
                    }
                    let dialogVisible = await authenticatorSetupDialogIsVisible(in: session)
                    if dialogVisible == false, try await authenticatorAppearsEnabled(in: session) {
                        guard let secret else {
                            return .manual("2FA уже включён, но ожидающий ключ не сохранён. Нужна проверка ключа.")
                        }
                        if enabledSince == nil { enabledSince = clock.now }
                        if let enabledSince, clock.now - enabledSince >= .milliseconds(750) {
                            return .enabled(secret: secret)
                        }
                        try await Task.sleep(for: .milliseconds(250))
                        continue
                    }
                    enabledSince = nil
                    if dialogVisible == false, secret == nil, !setupStarted {
                        if let beforeSetup {
                            guard try await beforeSetup(session) else { continue }
                        }
                        try Task.checkCancellation()
                        guard !operationIsCancelled, generation == session.cancellationGeneration else {
                            return .failure("Подключение 2FA остановлено.")
                        }
                        let started = try await ExternalLoginMailRequest.performTrigger(
                            request: rotationMail, in: session, from: session.webView.url,
                            skipped: .notFound, wasSubmitted: { $0 == .clicked }
                        ) {
                            try await startAuthenticatorSetup(in: session)
                        }
                        if started == .ambiguous {
                            return .manual("Форма подключения 2FA неоднозначна. Проверьте её в браузере.")
                        }
                        if started == .clicked {
                            setupStarted = true
                            deadline = min(limit, clock.now.advanced(by: .seconds(transitionTimeoutSeconds)))
                            await waitAfterSubmission(in: session)
                            continue
                        }
                    }
                    // A durable pending secret belongs to this setup. Never start a replacement factor.
                    if dialogVisible == true {
                        if !secretChecked, try await AuthenticatorSetupIntroduction.codeStep(in: session) == .found {
                            guard secret != nil else {
                                return .manual("Открыт шаг кода 2FA, но ключ ещё не сохранён. Вернитесь к шагу «Ключ».")
                            }
                            // This separate code screen has no key to recapture.
                            // Reuse only the key already persisted for this attempt.
                            secretChecked = true
                            setupStarted = true
                        }
                        if !secretChecked {
                            let captured = try await captureNewSecret(in: session)
                            guard !operationIsCancelled, generation == session.cancellationGeneration else {
                                return .failure("Подключение 2FA остановлено.")
                            }
                            if let secret, secret != TOTPService.normalizedSecret(captured) {
                                return .failure("Открытый ключ 2FA отличается от сохранённого. Ожидающий ключ не изменён.")
                            }
                            if secret == nil {
                                do { try onSecret(captured) } catch {
                                    return .failure("Не удалось сохранить ожидающий ключ 2FA. Код не отправлен.")
                                }
                                secret = TOTPService.normalizedSecret(captured)
                            }
                            secretChecked = true
                            deadline = min(limit, clock.now.advanced(by: .seconds(transitionTimeoutSeconds)))
                        }
                        guard let secret else { return .failure("Ожидающий ключ 2FA отсутствует.") }
                        switch try await AuthenticatorSetupIntroduction.advanceQRCode(in: session, click: !qrAdvanced) {
                        case .clicked:
                            qrAdvanced = true
                            deadline = min(limit, clock.now.advanced(by: .seconds(transitionTimeoutSeconds)))
                            await waitAfterSubmission(in: session)
                            continue
                        case .found:
                            try await Task.sleep(for: .milliseconds(200))
                            continue
                        case .ambiguous:
                            return .manual("Шаг сохранённого ключа 2FA неоднозначен. Новый ключ не запрашивается.")
                        case .notFound: break
                        }
                        if !codeSubmitted {
                            let codePageURL = session.webView.url
                            let delay = TOTPService.safeSubmissionDelay(minimumRemaining: 10)
                            if delay > 0 { try await Task.sleep(for: .seconds(delay + 0.15)) }
                            guard !operationIsCancelled, generation == session.cancellationGeneration else {
                                return .failure("Подключение 2FA остановлено.")
                            }
                            guard session.webView.url == codePageURL else { continue }
                            let code = try TOTPService.code(secret: secret)
                            let result = try await submitAuthenticatorSetupCode(code, in: session)
                            if result == .ambiguous || result == .noForm {
                                return .manual("Форма кода 2FA неоднозначна. Проверьте её в браузере.")
                            }
                            if result == .submitted {
                                codeSubmitted = true
                                deadline = min(limit, clock.now.advanced(by: .seconds(transitionTimeoutSeconds)))
                                await waitAfterSubmission(in: session)
                            }
                        }
                        if codeSubmitted, !confirmationClicked,
                           await authenticatorSetupDialogIsVisible(in: session) == true,
                           try await AuthenticatorSetupIntroduction.codeStep(in: session) == .notFound,
                           try await visibleFieldState(selectors: otpSelectors, in: session) == .notFound,
                           try await clickUniqueControl(labels: confirmLabels, click: true, in: session) == .clicked {
                            confirmationClicked = true
                            deadline = min(limit, clock.now.advanced(by: .seconds(transitionTimeoutSeconds)))
                            await waitAfterSubmission(in: session)
                        }
                        if !automaticallyWaitForTransitions, codeSubmitted,
                           await waitForAuthenticatorSetupCompletion(in: session, seconds: 10),
                           !operationIsCancelled, generation == session.cancellationGeneration {
                            return .enabled(secret: secret)
                        }
                    }
                }
                guard automaticallyWaitForTransitions else {
                    return .manual("Включение 2FA ещё не подтверждено. Продолжите в открытом браузере.")
                }
                try await Task.sleep(for: .milliseconds(250))
            } catch {
                if operationIsCancelled || generation != session.cancellationGeneration {
                    return .failure("Подключение 2FA остановлено.")
                }
                if let mailboxError = error as? MailVerificationError {
                    return .manual(mailboxError.localizedDescription)
                }
                if automaticallyWaitForTransitions {
                    if case QRCodeSecretError.missingURI = error {
                        try? await Task.sleep(for: .milliseconds(250))
                        continue
                    }
                    if session.webView.isLoading {
                        try? await Task.sleep(for: .milliseconds(250))
                        continue
                    }
                }
                return .manual("Завершите текущий шаг подключения 2FA в открытом браузере.")
            }
        }
        if operationIsCancelled || generation != session.cancellationGeneration {
            return .failure("Подключение 2FA остановлено.")
        }
        return .manual("Включение 2FA ещё не подтверждено. Проверьте открытый браузер.")
    }

    func dismissOptionalAuthenticatorBackup(in session: BrowserSession, click: Bool = true) async throws -> ControlResult {
        try Task.checkCancellation()
        guard !operationIsCancelled else { throw CancellationError() }
        guard TrustedChatGPTOrigin.allowsSecurityAutomation(session.webView.url), let url = session.webView.url
        else { return .notFound }
        let expectedURL = try Self.json(url.absoluteString)
        let result = try await session.evaluate(#"""
        (() => {
          if (location.origin !== 'https://chatgpt.com' || location.href !== new URL(\#(expectedURL)).href) return 'notFound';
          const visible = e => {
            if (!e || !e.getClientRects().length) return false;
            for (let p=e; p; p=p.parentElement) {
              const s=getComputedStyle(p);
              if (p.hidden || p.getAttribute('aria-hidden')==='true' || p.hasAttribute('inert') ||
                  s.display==='none' || s.visibility!=='visible' || s.opacity==='0') return false;
            }
            return true;
          };
          const text = e => {
            const walker=document.createTreeWalker(e,NodeFilter.SHOW_TEXT), parts=[];
            while(walker.nextNode()) if(visible(walker.currentNode.parentElement)) parts.push(walker.currentNode.textContent);
            return parts.join(' ').trim().replace(/\s+/g,' ');
          };
          const headings=[...document.querySelectorAll('h1,h2,h3,[role="heading"]')].filter(visible)
            .filter(e=>/^(Приложение (?:для )?аутентификации добавлено|Authenticator app added)$/i.test(text(e)));
          if (!headings.length) return 'notFound';
          if (headings.length!==1) return 'ambiguous';
          let scope=headings[0].parentElement;
          let backupContext = message => /\bSMS\b|СМС|\btext messages\b|текстов(?:ые|ых) сообщени[яй]/i.test(message) &&
            /резерв|backup|back-up/i.test(message);
          let knownBackupPending = backupContext(text(scope));
          while(scope && scope!==document.documentElement) {
            if (scope===document.body && headings[0].parentElement!==document.body) break;
            const buttons=[...scope.querySelectorAll('button,[role="button"]')].filter(visible);
            const skip=buttons.filter(e=>/^(Не сейчас|Not now)$/i.test(text(e)));
            if (skip.length>1) return 'ambiguous';
            if (skip.length===1) {
              const message=text(scope);
              if (!backupContext(message)) return 'notFound';
              if ([...scope.querySelectorAll('input,select,textarea')].some(visible)) return 'notFound';
              const button=skip[0];
              if (button.disabled || button.getAttribute('aria-disabled')==='true') return 'found';
              const sameOrigin = raw => {
                try { const u=new URL(raw,location.href);return u.origin===location.origin && !u.username && !u.password; }
                catch { return false; }
              };
              if ((button.hasAttribute('href') && !sameOrigin(button.getAttribute('href'))) ||
                  (button.hasAttribute('formaction') && !sameOrigin(button.getAttribute('formaction'))) ||
                  (button.form && !sameOrigin(button.form.action))) return 'ambiguous';
              if (!\#(click ? "true" : "false")) return 'found';
              button.click(); return 'clicked';
            }
            scope=scope.parentElement;
          }
          return knownBackupPending ? 'found' : 'notFound';
        })()
        """#) as? String
        return result.flatMap(ControlResult.init(rawValue:)) ?? .notFound
    }

    private func prepareRotationEnrollmentResume(
        account: AccountRecord,
        in session: BrowserSession
    ) async -> TwoFARotationOutcome? {
        if rotationSessions[account.id] === session,
           rotationRecoverySessionState(for: account) == .authenticated,
           TrustedChatGPTOrigin.allowsAuthentication(session.webView.url),
           session.webView.url?.host?.lowercased() == "auth.openai.com" {
            // A challenge in the original browser belongs to the saved setup.
            // The shared enrollment loop verifies the account on return.
            return nil
        }
        switch await probeRecoverySession(account: account, in: session) {
        case .authenticated: return nil
        case .manual(let message): return .manualActionRequired(stage: account.rotationStage, message: message)
        case .cancelled: return .failure(stage: account.rotationStage, message: "Stopped")
        }
    }

    private func beginNewSetup(
        account: inout AccountRecord,
        in session: BrowserSession,
        onCheckpoint: @escaping @MainActor (RotationCheckpointEvent) throws -> Void
    ) async -> TwoFARotationOutcome {
        if operationIsCancelled {
            return .failure(stage: account.rotationStage, message: "Stopped")
        }
        let original = account
        let generation = session.cancellationGeneration
        let externalMail = externalLoginMail(for: original, in: session)
        session.setOperationMessage("Подключение нового 2FA…")
        let outcome = await enrollNewAuthenticator(
            in: session,
            pendingSecret: original.pendingTOTPSecret,
            automaticallyWaitForTransitions: true,
            rotationMail: externalMail,
            rotationReauthentication: {
                await self.completeSecurityReauthentication(
                    account: original, in: session, externalMail: externalMail, allowAutomaticOldCode: false)
            }
        ) { secret in
            guard TOTPService.normalizedSecret(secret) != TOTPService.normalizedSecret(original.totpSecret) else {
                throw RotationVerificationError.identityOrSecretMissing
            }
            try onCheckpoint(.secretCaptured(secret))
            RotationState.capture(secret: secret, in: &account)
        }
        session.setOperationMessage(nil)
        guard !operationIsCancelled, generation == session.cancellationGeneration else {
            return .failure(stage: account.rotationStage, message: "Stopped")
        }
        switch outcome {
        case .manual(let message):
            return .manualActionRequired(stage: account.rotationStage, message: message)
        case .failure(let message):
            return .failure(stage: account.rotationStage, message: message)
        case .enabled(let secret):
            guard account.pendingTOTPSecret.map(TOTPService.normalizedSecret) == TOTPService.normalizedSecret(secret) else {
                return .failure(stage: account.rotationStage, message: "Подтверждённый ключ 2FA не совпадает с сохранённым.")
            }
            do {
                guard try await hasAuthenticatedSession(for: account, in: session) else {
                    return .manualActionRequired(stage: account.rotationStage, message: "Сессия аккаунта не подтверждена. Войдите в нужный аккаунт.")
                }
                try Task.checkCancellation()
                guard !operationIsCancelled, generation == session.cancellationGeneration else { throw CancellationError() }
                try onCheckpoint(.setupConfirmed)
                RotationState.markSetupConfirmed(in: &account)
                return await performCleanLogin(account: account, in: session)
            } catch {
                return .failure(stage: account.rotationStage, message: "Не удалось сохранить подтверждённый этап подключения 2FA.")
            }
        }
    }

    private func resumePendingSetup(
        account: AccountRecord,
        in session: BrowserSession,
        onCheckpoint: @escaping @MainActor (RotationCheckpointEvent) throws -> Void
    ) async -> TwoFARotationOutcome {
        var working = account
        guard working.pendingTOTPSecret != nil else {
            return .failure(stage: .pendingSecretCaptured, message: "Ожидающий ключ 2FA отсутствует.")
        }
        if let blocked = await prepareRotationEnrollmentResume(account: working, in: session) {
            return blocked
        }
        return await beginNewSetup(account: &working, in: session, onCheckpoint: onCheckpoint)
    }

    private func performCleanLogin(
        account: AccountRecord,
        in persistentSession: BrowserSession
    ) async -> TwoFARotationOutcome {
        if operationIsCancelled {
            return .failure(stage: .awaitingCleanLogin, message: "Stopped")
        }
        guard let pending = account.pendingTOTPSecret else {
            return .failure(stage: .awaitingCleanLogin, message: "Pending authenticator secret is missing.")
        }

        persistentSession.setVisible(false)
        let session = cleanLoginSession(for: account)
        activeSession = session
        session.setVisible(true)
        session.setOperationMessage("Проверочный вход: новый 2FA уже включён. Открывается отдельная сессия…")
        defer { session.setOperationMessage(nil) }

        if session.needsInitialPageLoad {
            guard await session.loadInitialPage(URL(string: "https://chatgpt.com/")!, seconds: 10, attempts: 3) else {
                if operationIsCancelled {
                    return .failure(stage: .awaitingCleanLogin, message: "Stopped")
                }
                return .manualActionRequired(
                    stage: .awaitingCleanLogin,
                    message: session.pageLoadMessage ?? "Проверочная страница входа не загрузилась. Нажмите «Обновить страницу» и продолжите проверку.")
            }
        }

        let initialProof = verificationProofs[account.id] ?? .none
        switch await signIn(
            account: account,
            secret: pending,
            in: session,
            initialProof: initialProof,
            requireExplicitProof: true,
            automaticallyWaitForTransitions: true
        ) {
        case .success(let snapshot, let proof):
            if operationIsCancelled {
                return .failure(stage: .awaitingCleanLogin, message: "Stopped")
            }
            guard snapshot.signedInEmail.caseInsensitiveCompare(account.email) == .orderedSame else {
                verificationSessions.removeValue(forKey: account.id)
                verificationProofs.removeValue(forKey: account.id)
                manualMFAChallenges.removeValue(forKey: account.id)
                return .failure(
                    stage: .awaitingCleanLogin,
                    message: "Clean login reached a different account.")
            }
            guard proof.isSufficient else {
                return .manualActionRequired(
                    stage: .awaitingCleanLogin,
                    message: "The pending authenticator code was not proven by this clean login.")
            }
            // Keep proof until the verified login is saved, including a retry
            // after WebKit or the session endpoint is temporarily unavailable.
            verificationProofs[account.id] = proof
            session.setOperationMessage("Вход с новым 2FA подтверждён. Проверяется подписка…")
            let verifiedSnapshot = await pricingEnriched(snapshot, in: session)
            if operationIsCancelled {
                return .failure(stage: .awaitingCleanLogin, message: "Stopped")
            }
            session.setOperationMessage("Вход с новым 2FA подтверждён. Сохраняется сессия…")
            do {
                try await persistVerifiedSession(from: session, for: account)
            } catch {
                session.setVisible(true)
                return .manualActionRequired(
                    stage: .awaitingCleanLogin,
                    message: "Новый 2FA проверен, но сессия ещё не сохранена. Продолжите для повторной проверки.")
            }
            verificationSessions.removeValue(forKey: account.id)
            verificationProofs.removeValue(forKey: account.id)
            manualMFAChallenges.removeValue(forKey: account.id)
            session.setVisible(false)
            let saved = accountSession(for: account)
            rotationSessions[account.id] = saved
            activeSession = saved
            saved.setVisible(true)
            return .success(snapshot: verifiedSnapshot, proof: proof)
        case .manual(let message, let proof):
            if operationIsCancelled {
                return .failure(stage: .awaitingCleanLogin, message: "Stopped")
            }
            verificationProofs[account.id] = proof
            session.setVisible(true)
            return .manualActionRequired(stage: .awaitingCleanLogin, message: message)
        case .restart(let message):
            if operationIsCancelled {
                return .failure(stage: .awaitingCleanLogin, message: "Stopped")
            }
            verificationSessions.removeValue(forKey: account.id)
            verificationProofs.removeValue(forKey: account.id)
            manualMFAChallenges.removeValue(forKey: account.id)
            session.setVisible(false)
            return .manualActionRequired(stage: .awaitingCleanLogin, message: message)
        case .failure(let message):
            return .failure(stage: .awaitingCleanLogin, message: message)
        }
    }

    private func completeSecurityReauthentication(
        account: AccountRecord,
        in session: BrowserSession,
        externalMail: ExternalLoginMailRequest?,
        allowAutomaticOldCode: Bool
    ) async -> ReauthenticationResult {
        let generation = session.cancellationGeneration
        let clock = ContinuousClock()
        var deadline = clock.now.advanced(by: .seconds(30))
        var chosePassword = false
        var submittedPassword = false
        var submittedMail = false
        var submittedOTP = false

        while clock.now < deadline {
            guard !operationIsCancelled, generation == session.cancellationGeneration else { return .cancelled }
            if session.webView.isLoading {
                try? await Task.sleep(for: .milliseconds(250))
                continue
            }
            guard let pageURL = session.webView.url, TrustedChatGPTOrigin.allowsAuthentication(pageURL) else {
                return .manual("Return to the OpenAI reauthentication page and continue.")
            }

            do {
                if TrustedChatGPTOrigin.allowsSecurityAutomation(pageURL) {
                    guard try await hasAuthenticatedSession(for: account, in: session) else {
                        return .manual("Sign in to the selected account to continue from Security settings.")
                    }
                    return .ready
                }
                guard pageURL.host?.lowercased() == "auth.openai.com" else {
                    return .manual("Return to ChatGPT Security settings and continue.")
                }
                if try await hasSecurityChallenge(in: session) {
                    return .manual("Complete the CAPTCHA or security check in the browser.")
                }
                guard !operationIsCancelled, generation == session.cancellationGeneration else { return .cancelled }
                guard session.webView.url == pageURL else { continue }

                let path = pageURL.path.lowercased()
                let emailRoute = Self.isPasswordEmailCodeRoute(pageURL)
                if !chosePassword, !submittedPassword, !account.password.isEmpty,
                   emailRoute || ["/log-in", "/log-in-or-create-account"].contains(path),
                   try await RegistrationForm.selectPasswordLogin(in: session) {
                    if emailRoute { externalMail?.switchedToPassword() }
                    chosePassword = true
                    deadline = clock.now.advanced(by: .seconds(30))
                    await waitAfterSubmission(in: session)
                    continue
                }

                if emailRoute, !submittedMail, !chosePassword || submittedPassword {
                    let state = try await RegistrationForm.inspect(in: session)
                    if state.kind == .emailCode, state.pageURL == session.webView.url {
                        guard let externalMail else {
                            return .manual("Подтвердите вход кодом из письма в браузере.")
                        }
                        if try await externalMail.submit(in: session, state: state) {
                            submittedMail = true
                            deadline = clock.now.advanced(by: .seconds(30))
                            await waitAfterSubmission(in: session)
                            continue
                        }
                    }
                } else if path == "/log-in/password", !submittedPassword, !account.password.isEmpty {
                    let password = try await ExternalLoginMailRequest.performTrigger(
                        request: externalMail, in: session, from: pageURL,
                        skipped: .notFound, wasSubmitted: { $0 == .submitted }
                    ) {
                        try await fillAndSubmit(
                            selectors: passwordSelectors, value: account.password, context: .authentication,
                            in: session, expectedPageURL: pageURL, expectedEmail: account.email)
                    }
                    if password == .ambiguous || password == .noForm {
                        return .manual("The password confirmation page is ambiguous.")
                    }
                    if password == .submitted {
                        submittedPassword = true
                        deadline = clock.now.advanced(by: .seconds(30))
                        await waitAfterSubmission(in: session)
                        continue
                    }
                } else if path.hasPrefix("/mfa-challenge/") {
                    guard allowAutomaticOldCode else {
                        return .manual("Complete OpenAI identity confirmation manually in this same browser session.")
                    }
                    if !submittedOTP {
                        let delay = TOTPService.safeSubmissionDelay()
                        if delay > 0 { try await Task.sleep(for: .seconds(delay + 0.15)) }
                        guard !operationIsCancelled, generation == session.cancellationGeneration else { return .cancelled }
                        guard session.webView.url == pageURL else { continue }
                        let text = try await authenticationPageText(in: session)
                        guard session.webView.url == pageURL else { continue }
                        if Self.isEmailLoginChallenge(text) {
                            return .manual("Подтвердите вход кодом из письма в браузере.")
                        }
                        let oldCode = try TOTPService.code(secret: account.totpSecret)
                        let otp = try await submitAuthenticationOTP(value: oldCode, in: session, expectedPageURL: pageURL)
                        if otp == .ambiguous || otp == .noForm {
                            return .manual("The current authenticator challenge is ambiguous.")
                        }
                        if otp == .submitted {
                            submittedOTP = true
                            deadline = clock.now.advanced(by: .seconds(30))
                            await waitAfterSubmission(in: session)
                            continue
                        }
                    }
                }
            } catch let error as ExternalLoginMailError {
                return .manual(error.localizedDescription)
            } catch SavedSessionError.wrongAccount {
                return .manual(SavedSessionError.wrongAccount.localizedDescription)
            } catch {
                if operationIsCancelled || generation != session.cancellationGeneration { return .cancelled }
                return .manual("Complete OpenAI identity confirmation in the browser.")
            }

            try? await Task.sleep(for: .milliseconds(250))
        }
        return .manual("OpenAI identity confirmation timed out. Continue in the browser.")
    }

    private func captureNewSecret(in session: BrowserSession) async throws -> String {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(10))
        var introductionAdvanced = false
        var keyTabSelected = false
        while clock.now < deadline {
            if operationIsCancelled {
                throw CancellationError()
            }
            switch try await AuthenticatorSetupIntroduction.advance(in: session, click: !introductionAdvanced) {
            case .clicked:
                introductionAdvanced = true
                await waitAfterSubmission(in: session)
                continue
            case .found:
                try await Task.sleep(for: .milliseconds(200))
                continue
            case .ambiguous: throw QRCodeSecretError.ambiguousURI
            case .notFound: break
            }
            var textKeyStep = false
            switch try await AuthenticatorSetupIntroduction.selectKey(in: session, click: !keyTabSelected) {
            case .clicked:
                keyTabSelected = true
                await waitAfterSubmission(in: session)
                continue
            case .ambiguous: throw QRCodeSecretError.ambiguousURI
            case .found: textKeyStep = true
            case .notFound: break
            }
            if let secret = try? await QRCodeSecretExtractor.extract(from: session.webView, textOnly: textKeyStep) {
                return secret
            }
            if try await clickUniqueControl(
                labels: problemsScanningLabels,
                click: true,
                in: session) == .clicked
            {
                await waitAfterSubmission(in: session)
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
        throw QRCodeSecretError.missingURI
    }

    private func submitAuthenticatorSetupCode(_ code: String, in session: BrowserSession) async throws -> FormResult {
        guard !operationIsCancelled else { throw CancellationError() }
        switch try await AuthenticatorSetupIntroduction.codeStep(in: session) {
        case .found:
            return try await AuthenticatorSetupIntroduction.submitCode(code, in: session)
        case .ambiguous, .clicked:
            return .ambiguous
        case .notFound:
            return try await fillAndSubmit(selectors: otpSelectors, value: code, context: .security, in: session)
        }
    }

    private func authenticatorSetupDialogIsVisible(
        in session: BrowserSession
    ) async -> Bool? {
        guard TrustedChatGPTOrigin.allowsSecurityAutomation(session.webView.url) else {
            return nil
        }
        do {
            switch try await AuthenticatorSetupIntroduction.codeStep(in: session) {
            case .found, .clicked: return true
            case .ambiguous: return nil
            case .notFound: break
            }
            let labelsJSON = try Self.json(setupDialogLabels.map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            })
            let value = try await session.evaluate("""
            (() => {
              const labels = new Set(\(labelsJSON));
              const normalize = value => String(value || "")
                .replace(/\\s+/g, " ").trim().toLowerCase();
              const displayed = element => {
                for (let current = element; current; current = current.parentElement) {
                  const style = getComputedStyle(current);
                  if (current.hidden || current.getAttribute("aria-hidden") === "true" ||
                      style.visibility === "hidden" || style.display === "none") return false;
                }
                const rect = element.getBoundingClientRect();
                return rect.width > 0 || rect.height > 0;
              };
              const headings = [...document.querySelectorAll("h1, h2, h3, h4")]
                .filter(displayed)
                .filter(element => labels.has(normalize(element.innerText)));
              if (headings.length > 1) return "ambiguous";
              return headings.length === 1 ? "visible" : "hidden";
            })()
            """) as? String
            if value == "ambiguous" { return nil }
            return value == "visible"
        } catch {
            return nil
        }
    }

    func waitForAuthenticatorSetupCompletion(
        in session: BrowserSession,
        seconds: Int
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(seconds))
        let generation = session.cancellationGeneration
        var backupPromptDismissed = false
        var enabledSince: ContinuousClock.Instant?
        while clock.now < deadline {
            guard !operationIsCancelled, generation == session.cancellationGeneration,
                  TrustedChatGPTOrigin.allowsSecurityAutomation(session.webView.url) else { return false }
            do {
                switch try await dismissOptionalAuthenticatorBackup(in: session, click: !backupPromptDismissed) {
                case .clicked:
                    backupPromptDismissed = true
                    enabledSince = nil
                    await waitAfterSubmission(in: session)
                    continue
                case .found:
                    enabledSince = nil
                case .ambiguous:
                    return false
                case .notFound:
                    if await authenticatorSetupDialogIsVisible(in: session) == false,
                       try await authenticatorAppearsEnabled(in: session) {
                        if enabledSince == nil { enabledSince = clock.now }
                        if let enabledSince, clock.now - enabledSince >= .milliseconds(750) {
                            return !operationIsCancelled && generation == session.cancellationGeneration
                        }
                    } else {
                        enabledSince = nil
                    }
                }
            } catch {
                enabledSince = nil
            }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return false
    }

    private func waitForAuthenticatorSwitch(
        _ expected: AuthenticatorSwitchResult,
        in session: BrowserSession,
        seconds: Int
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(seconds))
        while clock.now < deadline {
            if operationIsCancelled { return false }
            if (try? await authenticatorSwitch(click: false, in: session)) == expected {
                return true
            }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return false
    }

    func openSecuritySettings(
        in session: BrowserSession,
        seconds: Int
    ) async -> Bool {
        // Keep a live action URL (for example ?action=disable) intact. Loading
        // the root settings URL here discards OpenAI's confirmation dialog.
        if !TrustedChatGPTOrigin.allowsSecurityAutomation(session.webView.url) {
            _ = session.load(Self.securitySettingsURL)
        }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(seconds))
        while clock.now < deadline {
            if operationIsCancelled { return false }
            if TrustedChatGPTOrigin.allowsSecurityAutomation(session.webView.url) {
                switch try? await authenticatorSwitch(click: false, in: session) {
                case .on, .off:
                    return true
                case .ambiguous:
                    return false
                case .notFound, .clicked, nil:
                    break
                }
            }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return false
    }

    private func authenticate(
        account: AccountRecord,
        secret: String,
        in session: BrowserSession,
        emailCodeHandler: (@MainActor (BrowserSession) async throws -> Bool)? = nil
    ) async -> AuthenticationResult {
        if session.needsInitialPageLoad || !Self.shouldKeepAuthenticationSessionVisible(
            isVisible: session.isVisible,
            url: session.webView.url) {
            guard await loadAndWait(
                URL(string: "https://chatgpt.com/")!,
                in: session,
                seconds: 30)
            else {
                if operationIsCancelled {
                    return .failure("Stopped")
                }
                return .manual(session.pageLoadMessage ?? "ChatGPT не загрузился. Нажмите «Обновить страницу» и продолжите проверку.")
            }
        }

        if operationIsCancelled {
            return .failure("Stopped")
        }

        do {
            switch try await metadata(in: session) {
            case .success(let snapshot):
                guard snapshot.signedInEmail.caseInsensitiveCompare(account.email) == .orderedSame else {
                    return .failure("Signed-in account does not match the selected account.")
                }
                return .success(snapshot)
            case .loginRequired:
                break
            case .unavailable:
                return .manual(SavedSessionError.unavailable.localizedDescription)
            }
        } catch {
            if TrustedChatGPTOrigin.allowsMetadata(session.webView.url) {
                return .manual(SavedSessionError.unavailable.localizedDescription)
            }
        }

        switch await signIn(account: account, secret: secret, in: session,
                           automaticallyWaitForTransitions: emailCodeHandler != nil,
                           emailCodeHandler: emailCodeHandler) {
        case .success(let snapshot, _):
            guard snapshot.signedInEmail.caseInsensitiveCompare(account.email) == .orderedSame else {
                return .failure("Signed-in account does not match the selected account.")
            }
            return .success(snapshot)
        case .manual(let message, _):
            return .manual(message)
        case .restart(let message):
            return .manual(message)
        case .failure(let message):
            return .failure(message)
        }
    }

    func verifiedSubscription(
        _ snapshot: SubscriptionSnapshot,
        for account: AccountRecord,
        session: BrowserSession
    ) async -> SubscriptionCheckOutcome {
        guard snapshot.signedInEmail.caseInsensitiveCompare(account.email) == .orderedSame else {
            session.setVisible(true)
            return .failure("Signed-in account does not match the selected account.")
        }
        let enriched = await pricingEnriched(snapshot, in: session)
        session.setVisible(true)
        return .success(enriched)
    }

    private func pricingEnriched(
        _ snapshot: SubscriptionSnapshot,
        in session: BrowserSession
    ) async -> SubscriptionSnapshot {
        if operationIsCancelled {
            return snapshot
        }
        guard snapshot.activeUntil == nil,
              session.load(Self.pricingURL) != nil
        else { return snapshot }

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(15))
        while clock.now < deadline {
            if operationIsCancelled { return snapshot }
            if let details = try? await pricingDetails(in: session) {
                return snapshot.addingPricingDetails(details)
            }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return snapshot
    }

    private func requireManual(
        _ session: BrowserSession,
        _ message: String
    ) -> SubscriptionCheckOutcome {
        session.setVisible(true)
        return .manualActionRequired(message)
    }

    func dismissCookieConsent(in session: BrowserSession) async -> ControlResult {
        guard session.webView.url?.host?.lowercased() == "chatgpt.com" else {
            return .notFound
        }
        guard let result = try? await clickUniqueControl(
            labels: cookieConsentLabels,
            click: true,
            in: session)
        else {
            return .ambiguous
        }
        if result == .clicked {
            await waitAfterSubmission(in: session)
        }
        return result
    }

    func signIn(
        account: AccountRecord,
        secret: String,
        in session: BrowserSession,
        initialProof: CleanLoginProof = .none,
        requireExplicitProof: Bool = false,
        immediateAuthenticationWaitSeconds: Int = ChatGPTAutomation.cleanLoginAuthenticationWaitSeconds,
        automaticallySubmitOTP: Bool = true,
        waitForManualFactor: Bool = false,
        loginTimeoutSeconds: Int = 60,
        automaticallyWaitForTransitions: Bool = false,
        continueWaitingOnTimeout: Bool = false,
        humanChallengeTimeoutSeconds: Int = 300,
        registrationProfileHandler: (@MainActor (BrowserSession) async throws -> Bool)? = nil,
        beforePasswordSubmission: (@MainActor (BrowserSession) async throws -> Void)? = nil,
        emailCodeHandler: (@MainActor (BrowserSession) async throws -> Bool)? = nil
    ) async -> SignInResult {
        let externalMail = emailCodeHandler == nil ? externalLoginMail(for: account, in: session) : nil
        let automaticallyWaitForTransitions = automaticallyWaitForTransitions || externalMail != nil || waitForManualFactor
        let clock = ContinuousClock()
        var deadline = clock.now.advanced(by: .seconds(loginTimeoutSeconds))
        var limit = clock.now.advanced(by: .seconds(loginTimeoutSeconds + humanChallengeTimeoutSeconds))
        let continuousWait = automaticallyWaitForTransitions && continueWaitingOnTimeout
        let generation = session.cancellationGeneration
        var waitingForHuman = false
        var waitingForManualFactor = false
        let passwordLoginRequest = passwordEmailRequests[ObjectIdentifier(session)]
        var submittedStages = passwordLoginRequest?.submittedLoginStages ?? []
        var preparedPasswordStages: Set<String> = []
        defer { passwordLoginRequest?.submittedLoginStages = submittedStages }
        var proof = initialProof
        if submittedStages.contains(where: { $0.hasSuffix(":password") }) {
            proof.passwordSubmitted = true
        }
        var authenticationErrorRetries = 0
        let isRegistrationRecovery = registrationProfileHandler != nil
        var redirectedRegistration = false
        if requireExplicitProof {
            session.setOperationMessage("Проверочный вход: вход с новым 2FA…")
        }

        while continuousWait || (clock.now < deadline && clock.now < limit) {
            if operationIsCancelled || (automaticallyWaitForTransitions && generation != session.cancellationGeneration) {
                return .failure("Stopped")
            }
            if continuousWait, clock.now >= deadline || clock.now >= limit {
                if !waitingForHuman {
                    session.setOperationMessage("Вход отвечает дольше обычного. Проверка продолжается автоматически в той же сессии…")
                }
                do { try await Task.sleep(for: .seconds(1)) } catch { return .failure("Stopped") }
                guard !operationIsCancelled, generation == session.cancellationGeneration else { return .failure("Stopped") }
                limit = clock.now.advanced(by: .seconds(max(1, loginTimeoutSeconds + humanChallengeTimeoutSeconds)))
                deadline = clock.now.advanced(by: .seconds(max(1, waitingForHuman ? humanChallengeTimeoutSeconds : loginTimeoutSeconds)))
            }
            if automaticallyWaitForTransitions {
                guard TrustedChatGPTOrigin.allowsAuthentication(session.webView.url) else {
                    if session.webView.url == nil, session.webView.isLoading {
                        try? await Task.sleep(for: .milliseconds(250))
                        continue
                    }
                    return .manual("Вернитесь на доверенную страницу входа OpenAI.", proof)
                }
                if let text = try? await authenticationPageText(in: session), PasswordChangeForm.rejectsPassword(text) {
                    return .failure("OpenAI отклонил пароль. Проверьте данные аккаунта.")
                }
            }
            let recoveryPageURL: URL?
            if isRegistrationRecovery {
                guard TrustedChatGPTOrigin.allowsAuthentication(session.webView.url),
                      let href = try? await session.evaluate("location.href") as? String,
                      let pageURL = URL(string: href), pageURL == session.webView.url else {
                    try? await Task.sleep(for: .milliseconds(250))
                    continue
                }
                recoveryPageURL = pageURL
                if pageURL.host?.lowercased() == "auth.openai.com",
                   pageURL.path.lowercased().contains("reset-password") ||
                    pageURL.path.lowercased().contains("password-reset") ||
                    pageURL.path.lowercased().contains("forgot-password") {
                    return .failure("OpenAI открыл сброс пароля. Продолжение сохранённой регистрации остановлено; пароль не изменён.")
                }
                if pageURL.path.lowercased().hasPrefix("/create-account") ||
                    pageURL.path.lowercased() == "/auth/signup" {
                    guard !redirectedRegistration else {
                        return .failure("OpenAI снова предлагает регистрацию. Вход в сохранённый аккаунт не подтверждён; повторная регистрация не отправлена.")
                    }
                    redirectedRegistration = true
                    guard await loadAndWait(URL(string: "https://chatgpt.com/auth/login")!, in: session, seconds: 25) else {
                        return .failure("Страница входа в сохранённый аккаунт не загрузилась.")
                    }
                    submittedStages.removeAll()
                    deadline = min(limit, clock.now.advanced(by: .seconds(loginTimeoutSeconds)))
                    continue
                }
            } else {
                recoveryPageURL = nil
            }
            if Self.detectsAuthenticationCallbackError(url: session.webView.url) {
                return .failure("OpenAI не завершил вход. Начните проверку ещё раз.")
            }
            if await dismissCookieConsent(in: session) == .clicked {
                continue
            }
            if (try? await hasDeactivatedAccount(in: session)) == true {
                return .failure("Аккаунт OpenAI удалён или деактивирован.")
            }
            if (try? await hasRejectedAuthenticatorCode(in: session)) == true {
                return .failure("OpenAI отклонил одноразовый код. Проверьте сохранённый 2FA-ключ аккаунта.")
            }
            if (try? await hasAuthenticationServerError(in: session)) == true {
                if authenticationErrorRetries < 1 {
                    authenticationErrorRetries += 1
                    if (try? await clickUniqueControl(
                        labels: retryLabels,
                        click: true,
                        in: session)) == .clicked
                    {
                        await waitAfterSubmission(in: session)
                        continue
                    }
                }
                return .manual(
                    "OpenAI вернул ошибку сервера 500. Нажмите «Попробовать ещё раз» в браузере и продолжите.",
                    proof)
            }
            if requireExplicitProof,
               session.webView.url?.host?.lowercased() == "auth.openai.com",
               session.webView.url?.path.lowercased().hasPrefix("/mfa-challenge/") == true
            {
                manualMFAChallenges[account.id] = ObjectIdentifier(session)
            }
            if (try? await hasSecurityChallenge(in: session)) == true {
                if automaticallyWaitForTransitions {
                    if !waitingForHuman {
                        waitingForHuman = true
                        deadline = min(limit, clock.now.advanced(by: .seconds(humanChallengeTimeoutSeconds)))
                        session.setVisible(true)
                        session.setOperationMessage("Пройдите проверку безопасности в браузере. Вход продолжится автоматически.")
                    }
                    try? await Task.sleep(for: .milliseconds(250))
                    continue
                }
                return .manual(
                    "Пройдите проверку безопасности в окне браузера, затем нажмите «Продолжить».",
                    proof)
            }

            if waitingForHuman {
                waitingForHuman = false
                deadline = min(limit, clock.now.advanced(by: .seconds(loginTimeoutSeconds)))
            }
            if case .success(let snapshot) = try? await metadata(in: session) {
                if isRegistrationRecovery,
                   snapshot.signedInEmail.caseInsensitiveCompare(account.email) != .orderedSame {
                    return .failure("В браузере открыт другой аккаунт. Продолжение сохранённой регистрации остановлено.")
                }
                if requireExplicitProof {
                    proof = Self.manualMFACompletionProof(
                        proof: proof,
                        challengeObserved: manualMFAChallenges[account.id] == ObjectIdentifier(session),
                        authenticated: true)
                    switch Self.explicitLoginDecision(authenticated: true, proof: proof) {
                    case .acceptAuthenticated:
                        return .success(snapshot, proof)
                    case .restartFreshSession:
                        return .restart(
                            "The verification browser was already signed in. Continue to retry in a fresh isolated login.")
                    case .continueLogin:
                        break
                    }
                } else {
                    return .success(snapshot, proof)
                }
            }

            do {
                let pageURL = session.webView.url
                let path = pageURL?.path.lowercased() ?? ""
                let stage = "\(pageURL?.host ?? "")\(pageURL?.path ?? "")"
                if let registrationProfileHandler,
                   recoveryPageURL?.host?.lowercased() == "auth.openai.com",
                   recoveryPageURL?.path == "/about-you" {
                    let profileRejected = try await RegistrationForm.inspect(in: session).kind == .registrationRejected
                    if (!submittedStages.contains(stage + ":profile") || profileRejected),
                       try await registrationProfileHandler(session) {
                        submittedStages.insert(stage + ":profile")
                        deadline = min(limit, clock.now.advanced(by: .seconds(loginTimeoutSeconds)))
                        await waitAfterSubmission(in: session)
                    } else {
                        try await Task.sleep(for: .milliseconds(250))
                    }
                    continue
                }
                if Self.isPasswordEmailCodeRoute(pageURL) {
                    if !proof.passwordSubmitted,
                       !account.password.isEmpty,
                       !automaticallyWaitForTransitions || !submittedStages.contains(stage + ":passwordChoice"),
                       try await RegistrationForm.selectPasswordLogin(in: session) {
                        externalMail?.switchedToPassword()
                        submittedStages.insert(stage + ":passwordChoice")
                        if automaticallyWaitForTransitions {
                            deadline = min(limit, clock.now.advanced(by: .seconds(loginTimeoutSeconds)))
                        }
                        await waitAfterSubmission(in: session)
                        continue
                    }
                    if automaticallyWaitForTransitions,
                       submittedStages.contains(stage + ":emailCode") ||
                        (!proof.passwordSubmitted && submittedStages.contains(stage + ":passwordChoice")) {
                        try await Task.sleep(for: .milliseconds(250))
                        continue
                    }
                    let emailState = try await RegistrationForm.inspect(in: session)
                    if automaticallyWaitForTransitions, emailState.kind == .unknown {
                        try await Task.sleep(for: .milliseconds(250))
                        continue
                    }
                    if automaticallyWaitForTransitions, emailState.kind == .emailCode,
                       emailState.displayedEmail?.caseInsensitiveCompare(account.email) != .orderedSame {
                        return .manual("Код входа отправлен на другой адрес. Проверьте аккаунт в браузере.", proof)
                    }
                    if emailState.kind == .emailCode, externalMail != nil || emailCodeHandler != nil {
                        let submitted = if let externalMail {
                            try await externalMail.submit(in: session, state: emailState)
                        } else {
                            try await emailCodeHandler?(session) == true
                        }
                        if submitted {
                            submittedStages.insert(stage + ":emailCode")
                            if automaticallyWaitForTransitions {
                                deadline = min(limit, clock.now.advanced(by: .seconds(loginTimeoutSeconds)))
                            }
                            await waitAfterSubmission(in: session)
                            continue
                        }
                        try Task.checkCancellation()
                        // A mailbox wait can end because the user or provider moved to another screen.
                        if session.webView.url != emailState.pageURL { continue }
                        let current = try await RegistrationForm.inspect(in: session)
                        if current.kind != .emailCode || current.pageURL != emailState.pageURL { continue }
                        if automaticallyWaitForTransitions {
                            try await Task.sleep(for: .milliseconds(350))
                            continue
                        }
                    }
                    return .manual("Подтвердите вход кодом из почты. Код из письма не является кодом 2FA.", proof)
                }
                if externalMail != nil,
                   pageURL?.host?.lowercased() == "auth.openai.com", path.hasPrefix("/mfa-challenge/"),
                   Self.isEmailLoginChallenge(try await authenticationPageText(in: session)) {
                    return .manual("Подтвердите вход кодом из письма в браузере.", proof)
                }
                if pageURL?.host?.lowercased() == "auth.openai.com", ["/log-in", "/log-in-or-create-account"].contains(path),
                   !proof.passwordSubmitted, !account.password.isEmpty {
                    if !submittedStages.contains(stage + ":passwordChoice"),
                       try await RegistrationForm.selectPasswordLogin(in: session) {
                        submittedStages.insert(stage + ":passwordChoice")
                        deadline = min(limit, clock.now.advanced(by: .seconds(loginTimeoutSeconds)))
                        await waitAfterSubmission(in: session)
                        continue
                    }
                    if submittedStages.contains(stage + ":passwordChoice") {
                        try await Task.sleep(for: .milliseconds(250))
                        continue
                    }
                }
                let recoveryAllowsEmail = !isRegistrationRecovery ||
                    (recoveryPageURL?.host?.lowercased() == "auth.openai.com" &&
                     ["/", "/log-in", "/log-in-or-create-account"].contains(recoveryPageURL?.path ?? "")) ||
                    (recoveryPageURL?.host?.lowercased() == "chatgpt.com" &&
                     ["/", "/auth/login"].contains(recoveryPageURL?.path ?? ""))
                let externalEmailRoute = (pageURL?.host?.lowercased() == "auth.openai.com" && ["/", "/log-in", "/log-in-or-create-account"].contains(path)) ||
                    (pageURL?.host?.lowercased() == "chatgpt.com" && ["", "/", "/auth/login"].contains(path))
                let emailResult: FormResult
                if !recoveryAllowsEmail || (externalMail != nil && !externalEmailRoute) ||
                    (automaticallyWaitForTransitions && submittedStages.contains(stage + ":email")) {
                    emailResult = .notFound
                } else {
                    emailResult = try await ExternalLoginMailRequest.performTrigger(
                        request: externalMail, in: session, from: pageURL, skipped: .notFound,
                        wasSubmitted: { $0 == .submitted }
                    ) {
                        try await fillAndSubmit(selectors: emailSelectors, value: account.email, context: .authentication,
                                                in: session, expectedPageURL: externalMail == nil ? recoveryPageURL : pageURL)
                    }
                }
                if emailResult == .ambiguous || emailResult == .noForm {
                    return .manual("The login page is ambiguous. Continue in the browser.", proof)
                }
                if emailResult == .submitted {
                    submittedStages.insert(stage + ":email")
                    if automaticallyWaitForTransitions {
                        deadline = min(limit, clock.now.advanced(by: .seconds(loginTimeoutSeconds)))
                    }
                    if requireExplicitProof {
                        session.setOperationMessage("Проверочный вход: ожидается форма пароля…")
                    }
                    await waitAfterSubmission(in: session)
                    continue
                }
                if session.webView.url?.host?.lowercased() == "auth.openai.com",
                   session.webView.url?.path.lowercased() == "/choose-an-account",
                   !automaticallyWaitForTransitions || !submittedStages.contains(stage + ":account")
                {
                    let choice: ControlResult = try await ExternalLoginMailRequest.performTrigger(
                        request: externalMail, in: session, from: pageURL, skipped: .notFound,
                        wasSubmitted: { $0 == .clicked }
                    ) {
                        try await clickUniqueControl(labels: [account.email], click: true, in: session,
                                                     expectedPageURL: externalMail == nil ? recoveryPageURL : pageURL)
                    }
                    if choice == .ambiguous {
                        return .manual("The account chooser is ambiguous. Continue in the browser.", proof)
                    }
                    if choice == .clicked {
                        submittedStages.insert(stage + ":account")
                        if automaticallyWaitForTransitions {
                            deadline = min(limit, clock.now.advanced(by: .seconds(loginTimeoutSeconds)))
                        }
                        await waitAfterSubmission(in: session)
                        continue
                    }
                }
                if emailResult == .notFound, pageURL?.host?.lowercased() == "chatgpt.com", ["/", "/auth/login"].contains(path),
                   !submittedStages.contains(stage + ":remembered"),
                   try await ExternalLoginMailRequest.performTrigger(request: externalMail, in: session, from: pageURL,
                                                                    skipped: false, wasSubmitted: { $0 }, submit: {
                       try await RegistrationForm.selectRememberedAccount(account.email, in: session)
                   }) {
                    submittedStages.insert(stage + ":remembered")
                    deadline = min(limit, clock.now.advanced(by: .seconds(loginTimeoutSeconds)))
                    await waitAfterSubmission(in: session)
                    continue
                }
                if emailResult == .notFound,
                   !automaticallyWaitForTransitions || !submittedStages.contains(stage + ":login") {
                    let login = try await clickUniqueControl(
                        labels: loginLabels,
                        click: true,
                        in: session,
                        expectedPageURL: recoveryPageURL)
                    if login == .ambiguous {
                        return .manual("The login controls are ambiguous. Continue in the browser.", proof)
                    }
                    if login == .clicked {
                        submittedStages.insert(stage + ":login")
                        if automaticallyWaitForTransitions {
                            deadline = min(limit, clock.now.advanced(by: .seconds(loginTimeoutSeconds)))
                        }
                        await waitAfterSubmission(in: session)
                        continue
                    }
                }

                let passwordResult: FormResult
                if automaticallyWaitForTransitions && submittedStages.contains(stage + ":password") {
                    passwordResult = .notFound
                } else if (requireExplicitProof || isRegistrationRecovery || passwordLoginRequest != nil || externalMail != nil) && (session.webView.url?.host?.lowercased() != "auth.openai.com" ||
                    session.webView.url?.path.lowercased() != "/log-in/password") {
                    passwordResult = .notFound
                } else {
                    let passwordPageURL = session.webView.url
                    if let beforePasswordSubmission,
                       let pageURL = passwordPageURL,
                       pageURL.scheme == "https", pageURL.host?.lowercased() == "auth.openai.com",
                       pageURL.path == "/log-in/password",
                       !preparedPasswordStages.contains(stage) {
                        try await beforePasswordSubmission(session)
                        guard !operationIsCancelled, generation == session.cancellationGeneration else {
                            return .failure("Stopped")
                        }
                        guard session.webView.url == pageURL,
                              try await session.evaluate("location.href") as? String == pageURL.absoluteString else {
                            continue
                        }
                        guard !operationIsCancelled, generation == session.cancellationGeneration else {
                            return .failure("Stopped")
                        }
                        preparedPasswordStages.insert(stage)
                    }
                    passwordResult = try await ExternalLoginMailRequest.performTrigger(
                        request: externalMail, in: session, from: passwordPageURL, skipped: .notFound,
                        wasSubmitted: { $0 == .submitted }
                    ) {
                        try await fillAndSubmit(
                            selectors: passwordSelectors, value: account.password, context: .authentication, in: session,
                            expectedPageURL: passwordLoginRequest != nil || beforePasswordSubmission != nil || externalMail != nil ? passwordPageURL : recoveryPageURL,
                            expectedEmail: isRegistrationRecovery || passwordLoginRequest != nil || beforePasswordSubmission != nil || externalMail != nil ? account.email : nil)
                    }
                }
                if passwordResult == .ambiguous || passwordResult == .noForm {
                    return .manual("The password page is ambiguous. Continue in the browser.", proof)
                }
                if passwordResult == .submitted {
                    submittedStages.insert(stage + ":password")
                    if automaticallyWaitForTransitions {
                        deadline = min(limit, clock.now.advanced(by: .seconds(loginTimeoutSeconds)))
                    }
                    proof.passwordSubmitted = true
                    if requireExplicitProof {
                        session.setOperationMessage("Проверочный вход: ожидается запрос нового кода 2FA…")
                    }
                    await waitAfterSubmission(in: session)
                    continue
                }

                guard automaticallySubmitOTP else {
                    session.setVisible(true)
                    if waitForManualFactor {
                        if !waitingForManualFactor,
                           pageURL?.host?.lowercased() == "auth.openai.com", path.hasPrefix("/mfa-challenge/") {
                            waitingForManualFactor = true
                            deadline = min(limit, clock.now.advanced(by: .seconds(humanChallengeTimeoutSeconds)))
                            session.setOperationMessage("Подтвердите вход в браузере. Смена 2FA продолжится автоматически.")
                        }
                        try await Task.sleep(for: .milliseconds(250))
                        continue
                    }
                    return .manual(
                        "Введите действующий одноразовый код вручную и нажмите «Продолжить».",
                        proof)
                }

                if requireExplicitProof {
                    let mfaRoute = session.webView.url?.host?.lowercased() == "auth.openai.com" &&
                        session.webView.url?.path.lowercased().hasPrefix("/mfa-challenge/") == true
                    if mfaRoute, !proof.passwordSubmitted {
                        guard let href = try? await session.evaluate("location.href") as? String,
                              URL(string: href) == session.webView.url else {
                            try await Task.sleep(for: .milliseconds(250))
                            continue
                        }
                        session.setVisible(true)
                        return .manual(
                            "OpenAI запросил 2FA до ввода пароля. Вход с сохранённым паролем не подтверждён. Проверьте пароль в настройках аккаунта и повторите проверочный вход.",
                            proof)
                    }
                    guard mfaRoute && proof.passwordSubmitted else {
                        if !automaticallyWaitForTransitions,
                           try await visibleFieldState(selectors: otpSelectors, in: session) != .notFound {
                            return .manual("Не подтверждён отдельный запрос 2FA после входа с паролем. Продолжите в браузере.", proof)
                        }
                        try await Task.sleep(for: .milliseconds(250))
                        continue
                    }
                }
                if automaticallyWaitForTransitions, submittedStages.contains(stage + ":otp") {
                    try await Task.sleep(for: .milliseconds(250))
                    continue
                }
                if passwordLoginRequest != nil || externalMail != nil,
                   session.webView.url?.host?.lowercased() != "auth.openai.com" ||
                    session.webView.url?.path.lowercased().hasPrefix("/mfa-challenge/") != true {
                    try await Task.sleep(for: .milliseconds(250))
                    continue
                }
                if externalMail != nil, !TOTPService.isValidSecret(secret) {
                    return .manual("OpenAI запросил код приложения-аутентификатора. Введите его в браузере.", proof)
                }
                if isRegistrationRecovery {
                    guard recoveryPageURL?.host?.lowercased() == "auth.openai.com",
                          recoveryPageURL?.path.lowercased().hasPrefix("/mfa-challenge/") == true else {
                        try await Task.sleep(for: .milliseconds(250))
                        continue
                    }
                    guard TOTPService.isValidSecret(secret) else {
                        return .failure("OpenAI запросил 2FA, но ключ сохранённой регистрации отсутствует. Подтвердите вход вручную и продолжите.")
                    }
                }
                let safeDelay = TOTPService.safeSubmissionDelay()
                if safeDelay > 0 {
                    if requireExplicitProof {
                        session.setOperationMessage("Проверочный вход: ожидается свежий код нового 2FA…")
                    }
                    try? await Task.sleep(for: .seconds(safeDelay + 0.15))
                }
                if automaticallyWaitForTransitions,
                   operationIsCancelled || generation != session.cancellationGeneration {
                    return .failure("Stopped")
                }
                let otpPageURL = session.webView.url
                let isMFAChallenge = otpPageURL?.host?.lowercased() == "auth.openai.com" &&
                    otpPageURL?.path.lowercased().hasPrefix("/mfa-challenge/") == true
                if (requireExplicitProof || externalMail != nil) && !isMFAChallenge { continue }
                if Self.isPasswordEmailCodeRoute(otpPageURL) { continue }
                if externalMail != nil {
                    let text = try await authenticationPageText(in: session)
                    guard otpPageURL == session.webView.url else { continue }
                    if Self.isEmailLoginChallenge(text) {
                        return .manual("Подтвердите вход кодом из письма в браузере.", proof)
                    }
                }
                let code = try TOTPService.code(secret: secret)
                var otpResult = try await submitAuthenticationOTP(value: code, in: session,
                                                                  expectedPageURL: externalMail == nil ? recoveryPageURL : otpPageURL)
                if externalMail != nil, otpPageURL != session.webView.url, otpResult != .submitted { continue }
                if Self.needsKeyboardMFAFallback(
                    url: session.webView.url,
                    formResult: otpResult)
                {
                    if !automaticallyWaitForTransitions {
                        _ = await session.waitUntilAttached(seconds: 2)
                    }
                    if await session.submitMFAUsingKeyboard(code) {
                        otpResult = .submitted
                    } else if !automaticallyWaitForTransitions {
                        return .manual(
                            "Не удалось автоматически отправить код 2FA. Откройте поле в браузере и продолжите.",
                            proof)
                    }
                }
                if automaticallyWaitForTransitions, otpResult == .notFound {
                    try await Task.sleep(for: .milliseconds(250))
                    continue
                }
                if otpResult == .ambiguous || otpResult == .noForm {
                    return .manual("The 2FA page is ambiguous. Continue in the browser.", proof)
                }
                if otpResult == .submitted {
                    submittedStages.insert(stage + ":otp")
                    if automaticallyWaitForTransitions {
                        deadline = min(limit, clock.now.advanced(by: .seconds(loginTimeoutSeconds)))
                    }
                    if isMFAChallenge { proof.pendingOTPSubmitted = true }
                    if requireExplicitProof {
                        session.setOperationMessage("Проверочный вход: новый код отправлен, ожидается подтверждение OpenAI…")
                        if automaticallyWaitForTransitions {
                            await waitAfterSubmission(in: session)
                            continue
                        }
                        if let snapshot = await waitForImmediateAuthentication(
                            in: session,
                            seconds: immediateAuthenticationWaitSeconds
                        ) {
                            proof.authenticatedImmediatelyAfterPendingOTP = true
                            return .success(snapshot, proof)
                        }
                        session.setVisible(true)
                        return .manual(
                            "Вход ещё не завершён. Закончите CAPTCHA или текущий шаг и нажмите «Продолжить».",
                            proof)
                    }
                    await waitAfterSubmission(in: session)
                    continue
                }
            } catch {
                if operationIsCancelled || (automaticallyWaitForTransitions && generation != session.cancellationGeneration) {
                    return .failure("Stopped")
                }
                if error is RegistrationForm.ProfileRetryError {
                    return .failure(RegistrationForm.rejectionMessage)
                }
                if let error = error as? ExternalLoginMailError {
                    return .manual(error.localizedDescription, proof)
                }
                if emailCodeHandler != nil,
                   error is PasswordEmailAutomationError || error is MailVerificationError {
                    return .manual(error.localizedDescription, proof)
                }
                if automaticallyWaitForTransitions, session.webView.isLoading {
                    try? await Task.sleep(for: .milliseconds(250))
                    continue
                }
                return .manual("Automatic login stopped. Continue in the browser.", proof)
            }

            try? await Task.sleep(for: .milliseconds(500))
        }

        if operationIsCancelled || (automaticallyWaitForTransitions && generation != session.cancellationGeneration) {
            return .failure("Stopped")
        }
        if case .success(let snapshot) = try? await metadata(in: session) {
            if isRegistrationRecovery,
               snapshot.signedInEmail.caseInsensitiveCompare(account.email) != .orderedSame {
                return .failure("В браузере открыт другой аккаунт. Продолжение сохранённой регистрации остановлено.")
            }
            if requireExplicitProof {
                proof = Self.manualMFACompletionProof(
                    proof: proof,
                    challengeObserved: manualMFAChallenges[account.id] == ObjectIdentifier(session),
                    authenticated: true)
                switch Self.explicitLoginDecision(authenticated: true, proof: proof) {
                case .acceptAuthenticated:
                    return .success(snapshot, proof)
                case .restartFreshSession:
                    return .restart(
                        "The verification browser was already signed in. Continue to retry in a fresh isolated login.")
                case .continueLogin:
                    break
                }
            } else {
                return .success(snapshot, proof)
            }
        }
        if operationIsCancelled || (automaticallyWaitForTransitions && generation != session.cancellationGeneration) {
            return .failure("Stopped")
        }
        return .manual("Automatic login timed out. Continue in the browser.", proof)
    }

    private func waitForImmediateAuthentication(
        in session: BrowserSession,
        seconds: Int
    ) async -> SubscriptionSnapshot? {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(seconds))
        while clock.now < deadline {
            if operationIsCancelled { return nil }
            if case .success(let snapshot) = try? await metadata(in: session) {
                return snapshot
            }
            if (try? await hasSecurityChallenge(in: session)) == true {
                return nil
            }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return nil
    }

    private func metadata(in session: BrowserSession) async throws -> MetadataResult {
        guard TrustedChatGPTOrigin.allowsMetadata(session.webView.url), let url = session.webView.url else {
            throw BrowserSessionError.untrustedOrigin
        }
        let generation = session.cancellationGeneration
        for attempt in 0..<3 {
            try Task.checkCancellation()
            guard !operationIsCancelled, generation == session.cancellationGeneration, session.webView.url == url else {
                throw CancellationError()
            }
            // Session and subscription GETs each have a six-second abort budget.
            let value = try await session.evaluate(Self.subscriptionScript, timeout: .seconds(15))
            guard generation == session.cancellationGeneration, session.webView.url == url else { throw CancellationError() }
            guard let dictionary = value as? [String: Any], let state = dictionary["state"] as? String else { return .unavailable }
            switch state {
            case "success": return .success(try SubscriptionSnapshot(javaScriptValue: dictionary))
            case "loginRequired": return .loginRequired
            default:
                guard attempt < 2, dictionary["retryable"] as? Bool == true else { return .unavailable }
                let hint = (dictionary["retryAfterSeconds"] as? Double) ?? 0
                guard hint.isFinite, hint <= 30 else { return .unavailable }
                let delay = max(Double(1 << attempt), max(0, hint))
                try await Task.sleep(for: .seconds(delay))
            }
        }
        return .unavailable
    }

    func pricingDetails(in session: BrowserSession) async throws -> PricingDetails? {
        guard TrustedChatGPTOrigin.allowsMetadata(session.webView.url),
              session.webView.url?.fragment?.lowercased() == "pricing"
        else { throw BrowserSessionError.untrustedOrigin }
        let value = try await session.evaluate(Self.pricingDetailsScript)
        guard let dictionary = value as? [String: Any],
              dictionary["state"] as? String == "success",
              let activeUntilText = dictionary["activeUntilText"] as? String,
              !activeUntilText.isEmpty
        else { return nil }
        return PricingDetails(
            activeUntilText: activeUntilText,
            localeIdentifier: (dictionary["locale"] as? String).flatMap {
                $0.isEmpty ? nil : $0
            } ?? "en-US")
    }

    func submitAuthenticationOTP(
        value: String,
        in session: BrowserSession,
        expectedPageURL: URL? = nil
    ) async throws -> FormResult {
        if let expectedPageURL, session.webView.url != expectedPageURL { return .notFound }
        var selectors = otpSelectors
        let isMFAChallenge = session.webView.url?.host?.lowercased() == "auth.openai.com" &&
            session.webView.url?.path.lowercased().hasPrefix("/mfa-challenge/") == true
        if isMFAChallenge {
            selectors.append("input:not([type='hidden'])")
            return try await fillAndClickMFAChallenge(
                selectors: selectors,
                value: value,
                in: session,
                expectedPageURL: expectedPageURL)
        }
        return try await fillAndSubmit(
            selectors: selectors,
            value: value,
            context: .authentication,
            in: session,
            expectedPageURL: expectedPageURL)
    }

    private func fillAndClickMFAChallenge(
        selectors: [String],
        value: String,
        in session: BrowserSession,
        expectedPageURL: URL? = nil
    ) async throws -> FormResult {
        guard session.webView.url?.host?.lowercased() == "auth.openai.com",
              session.webView.url?.path.lowercased().hasPrefix("/mfa-challenge/") == true
        else { throw BrowserSessionError.untrustedOrigin }
        let selectorsJSON = try Self.json(selectors)
        let valueJSON = try Self.json(value)
        let expectedPageURLJSON = try Self.json(expectedPageURL?.absoluteString ?? "")
        let probeScript = Self.mfaChallengeScript(
            selectorsJSON: selectorsJSON,
            valueJSON: valueJSON,
            expectedPageURLJSON: expectedPageURLJSON,
            submit: false)
        let submitScript = Self.mfaChallengeScript(
            selectorsJSON: selectorsJSON,
            valueJSON: valueJSON,
            expectedPageURLJSON: expectedPageURLJSON,
            submit: true)
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))

        while clock.now < deadline {
            if let expectedPageURL, session.webView.url != expectedPageURL { return .notFound }
            let mainRaw = try await session.evaluate(probeScript) as? String
            let main = mainRaw.flatMap(MFAFrameResult.init(rawValue:)) ?? .ambiguous
            let children = await session.evaluateInTrustedChildFrames(probeScript)
            let childStates = children.map { evaluation in
                (
                    frame: evaluation.frame,
                    state: (evaluation.value as? String)
                        .flatMap(MFAFrameResult.init(rawValue:)) ?? .ambiguous
                )
            }
            let readyChildren = childStates.filter { $0.state == .ready }
            let readyCount = (main == .ready ? 1 : 0) + readyChildren.count

            if readyCount > 1 { return .ambiguous }
            if main == .ready {
                return try await Self.formResult(
                    from: session.evaluate(submitScript))
            }
            if let child = readyChildren.first {
                return try await Self.formResult(
                    from: session.evaluate(submitScript, in: child.frame))
            }
            if main == .ambiguous || childStates.contains(where: { $0.state == .ambiguous }) {
                return .ambiguous
            }
            if main == .noForm || childStates.contains(where: { $0.state == .noForm }) {
                return .noForm
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return .notFound
    }

    private static func formResult(from value: Any) -> FormResult {
        guard let raw = value as? String,
              let result = FormResult(rawValue: raw)
        else { return .ambiguous }
        return result
    }

    private static func mfaChallengeScript(
        selectorsJSON: String,
        valueJSON: String,
        expectedPageURLJSON: String,
        submit: Bool
    ) -> String {
        """
        (() => {
          const expectedPageURL = \(expectedPageURLJSON);
          const samePage = () => {
            if (!expectedPageURL) return true;
            try { return window.top.location.href === expectedPageURL; } catch { return false; }
          };
          if (!samePage()) return "notFound";
          const selectors = \(selectorsJSON);
          const roots = [];
          const collectRoots = root => {
            roots.push(root);
            for (const element of root.querySelectorAll("*")) {
              const view = element.ownerDocument?.defaultView || window;
              const shadowRoot = element.shadowRoot ||
                view.__gptAccountManagerShadowRoot?.(element);
              if (shadowRoot) collectRoots(shadowRoot);
            }
          };
          collectRoots(document);
          const visible = element => {
            const view = element.ownerDocument?.defaultView || window;
            const style = view.getComputedStyle(element);
            const rect = element.getBoundingClientRect();
            return style.visibility !== "hidden" && style.display !== "none" &&
              rect.width > 0 && rect.height > 0 && !element.disabled;
          };
          const fields = [...new Set(selectors.flatMap(selector =>
            roots.flatMap(root => [...root.querySelectorAll(selector)])))].filter(visible);
          if (fields.length === 0) return "notFound";
          if (fields.length !== 1) return "ambiguous";
          const field = fields[0];
          const form = field.form;
          const controls = roots.flatMap(root => [...root.querySelectorAll(
            "button, [role='button'], input[type='button'], input[type='submit']")])
            .filter(visible)
            .filter(element => {
              const label = String(
                element.innerText || element.value ||
                element.getAttribute("aria-label") || "")
                .replace(/\\s+/g, " ").trim().toLowerCase();
              return label === "continue" || label === "продолжить";
          });
          if (controls.length === 0 && !form) return "noForm";
          if (controls.length > 1) return "ambiguous";
          if (!\(submit ? "true" : "false")) return "ready";
          const fieldView = field.ownerDocument?.defaultView || window;
          const setter = Object.getOwnPropertyDescriptor(
            fieldView.HTMLInputElement.prototype, "value")?.set;
          if (!setter) return "ambiguous";
          setter.call(field, \(valueJSON));
          field.dispatchEvent(new fieldView.Event("input", { bubbles: true }));
          field.dispatchEvent(new fieldView.Event("change", { bubbles: true }));
          if (!samePage()) return "notFound";
          if (controls.length === 1) controls[0].click();
          else if (typeof form.requestSubmit === "function") form.requestSubmit();
          else form.submit();
          return "submitted";
        })()
        """
    }

    func fillAndSubmit(
        selectors: [String],
        value: String,
        context: AutomationContext,
        in session: BrowserSession,
        expectedPageURL: URL? = nil,
        expectedEmail: String? = nil
    ) async throws -> FormResult {
        if let expectedPageURL, session.webView.url != expectedPageURL { return .notFound }
        switch context {
        case .authentication:
            guard TrustedChatGPTOrigin.allowsAuthentication(session.webView.url) else {
                throw BrowserSessionError.untrustedOrigin
            }
        case .security:
            guard TrustedChatGPTOrigin.allowsSecurityAutomation(session.webView.url) else {
                throw BrowserSessionError.untrustedOrigin
            }
        }
        let selectorsJSON = try Self.json(selectors)
        let valueJSON = try Self.json(value)
        let expectedPageURLJSON = try Self.json(expectedPageURL?.absoluteString ?? "")
        let expectedEmailJSON = try Self.json(expectedEmail?.lowercased() ?? "")
        let authenticatorLabelsJSON = try Self.json(authenticatorLabels.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        })
        let setupDialogLabelsJSON = try Self.json(setupDialogLabels.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        })
        let requiresAuthenticatorScope = context == .security
        let allowsPasswordLoginSubmitter = context == .authentication && selectors == passwordSelectors
        let script = """
        (() => {
          const expectedPageURL = \(expectedPageURLJSON);
          const expectedEmail = \(expectedEmailJSON);
          if (expectedPageURL && location.href !== expectedPageURL) return "notFound";
          const selectors = \(selectorsJSON);
          const authenticatorLabels = new Set(\(authenticatorLabelsJSON));
          const setupDialogLabels = new Set(\(setupDialogLabelsJSON));
          const requiresAuthenticatorScope = \(requiresAuthenticatorScope ? "true" : "false");
          const normalize = value => String(value || "")
            .replace(/\\s+/g, " ").trim().toLowerCase();
          const visible = element => {
            const style = getComputedStyle(element);
            const rect = element.getBoundingClientRect();
            return style.visibility !== "hidden" && style.display !== "none" &&
              rect.width > 0 && rect.height > 0 && !element.disabled;
          };
          const displayed = element => {
            for (let current = element; current; current = current.parentElement) {
              const style = getComputedStyle(current);
              if (current.hidden || current.getAttribute("aria-hidden") === "true" ||
                  style.visibility === "hidden" || style.display === "none") return false;
            }
            const rect = element.getBoundingClientRect();
            return rect.width > 0 || rect.height > 0;
          };
          const collectRoots = scopes => {
            const collected = [];
            const seen = new Set();
            const visit = root => {
              if (!root || seen.has(root)) return;
              seen.add(root);
              collected.push(root);
              for (const element of root.querySelectorAll("*")) {
                const view = element.ownerDocument?.defaultView || window;
                const shadowRoot = element.shadowRoot ||
                  view.__gptAccountManagerShadowRoot?.(element);
                if (shadowRoot) visit(shadowRoot);
              }
            };
            scopes.forEach(visit);
            return collected;
          };
          let scopes = [document];
          if (requiresAuthenticatorScope) {
            const setupHeadings = [...document.querySelectorAll("h1, h2, h3, h4")]
              .filter(displayed)
              .filter(element => setupDialogLabels.has(normalize(element.innerText)));
            const setupRoots = [...new Set(setupHeadings.map(element =>
              element.closest("[role='dialog'], [data-state='open']") ||
                element.parentElement?.parentElement).filter(Boolean))];
            if (setupRoots.length > 1) return "ambiguous";
            if (setupRoots.length === 1) scopes = setupRoots;
            else {
            const labelled = [...document.querySelectorAll(
              "h1, h2, h3, h4, p, span, div, button, a, [role='button'], [aria-label]")]
              .filter(visible)
              .filter(element => authenticatorLabels.has(normalize(
                element.getAttribute("aria-label") || element.getAttribute("title") ||
                element.innerText || element.value)));
            scopes = [...new Set(labelled.map(element =>
              element.closest("[role='dialog'], section, article, li, [data-testid]") ||
                element.parentElement).filter(Boolean))];
            if (scopes.length === 0) return "notFound";
            if (scopes.length !== 1) return "ambiguous";
            }
          }
          const roots = collectRoots(scopes);
          const fields = [...new Set(selectors.flatMap(selector =>
            roots.flatMap(root => [...root.querySelectorAll(selector)])))].filter(visible);
          if (fields.length === 0) return "notFound";
          if (fields.length !== 1) return "ambiguous";
          const field = fields[0];
          const form = field.form;
          if (!form) return "noForm";
          const matchesEmail = () => {
            if (!expectedEmail) return true;
            let scope = form;
            while (scope) {
              const walker = document.createTreeWalker(scope, NodeFilter.SHOW_TEXT);
              const parts = [];
              while (walker.nextNode()) if (displayed(walker.currentNode.parentElement)) parts.push(walker.currentNode.textContent);
              const values = [...scope.querySelectorAll('input[type="email"], input[name="username"]')]
                .filter(displayed).map(input => input.value);
              const addresses = [...new Set((parts.concat(values).join(' ').match(/[a-z0-9.!#$%&'*+\\x2f=?^_`{|}~-]+@[a-z0-9-]+(?:\\.[a-z0-9-]+)+/gi) || [])
                .map(value => value.toLowerCase()))];
              if (addresses.length) return addresses.length === 1 && addresses[0] === expectedEmail;
              if (scope === document.body) break;
              scope = scope.parentElement;
            }
            return true;
          };
          if (!matchesEmail()) return "ambiguous";
          let submitters = [...form.querySelectorAll(
            "button:not([type]), button[type='submit'], input[type='submit']")]
            .filter(visible);
          if (submitters.length > 1 && \(allowsPasswordLoginSubmitter ? "true" : "false") &&
              location.origin === "https://auth.openai.com" &&
              location.pathname === "/log-in/password" && field.type === "password") {
            const label = element => normalize(
              element.innerText || element.value || element.getAttribute("aria-label"));
            const primary = submitters.filter(element =>
              ["continue", "продолжить"].includes(label(element)));
            const alternatives = submitters.filter(element =>
              ["log in with a one-time code", "вход с одноразовым кодом"].includes(label(element)));
            if (primary.length === 1 && alternatives.length === submitters.length - 1 &&
                primary[0].form === form &&
                new URL(form.action, location.href).origin === location.origin &&
                new URL(primary[0].formAction || form.action, location.href).origin === location.origin) {
              submitters = primary;
            }
          }
          if (submitters.length > 1) return "ambiguous";
          const setter = Object.getOwnPropertyDescriptor(
            window.HTMLInputElement.prototype, "value")?.set;
          if (!setter) return "ambiguous";
          setter.call(field, \(valueJSON));
          field.dispatchEvent(new Event("input", { bubbles: true }));
          field.dispatchEvent(new Event("change", { bubbles: true }));
          if (expectedPageURL && location.href !== expectedPageURL) return "notFound";
          if (!matchesEmail()) return "ambiguous";
          if (submitters.length === 1) submitters[0].click();
          else if (typeof form.requestSubmit === "function") form.requestSubmit();
          else form.submit();
          return "submitted";
        })()
        """
        guard let raw = try await session.evaluate(script) as? String,
              let result = FormResult(rawValue: raw)
        else { return .ambiguous }
        if result == .notFound, expectedPageURL == nil {
            for evaluation in await session.evaluateInTrustedChildFrames(script) {
                guard let childRaw = evaluation.value as? String,
                      let childResult = FormResult(rawValue: childRaw)
                else { return .ambiguous }
                if childResult != .notFound { return childResult }
            }
        }
        return result
    }

    private func visibleFieldState(
        selectors: [String],
        in session: BrowserSession
    ) async throws -> FormResult {
        guard TrustedChatGPTOrigin.allowsSecurityAutomation(session.webView.url) else {
            throw BrowserSessionError.untrustedOrigin
        }
        let selectorsJSON = try Self.json(selectors)
        let authenticatorLabelsJSON = try Self.json(authenticatorLabels.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        })
        let setupDialogLabelsJSON = try Self.json(setupDialogLabels.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        })
        let script = """
        (() => {
          const selectors = \(selectorsJSON);
          const authenticatorLabels = new Set(\(authenticatorLabelsJSON));
          const setupDialogLabels = new Set(\(setupDialogLabelsJSON));
          const normalize = value => String(value || "")
            .replace(/\\s+/g, " ").trim().toLowerCase();
          const visible = element => {
            const style = getComputedStyle(element);
            const rect = element.getBoundingClientRect();
            return style.visibility !== "hidden" && style.display !== "none" &&
              rect.width > 0 && rect.height > 0 && !element.disabled;
          };
          const displayed = element => {
            for (let current = element; current; current = current.parentElement) {
              const style = getComputedStyle(current);
              if (current.hidden || current.getAttribute("aria-hidden") === "true" ||
                  style.visibility === "hidden" || style.display === "none") return false;
            }
            const rect = element.getBoundingClientRect();
            return rect.width > 0 || rect.height > 0;
          };
          const setupHeadings = [...document.querySelectorAll("h1, h2, h3, h4")]
            .filter(displayed)
            .filter(element => setupDialogLabels.has(normalize(element.innerText)));
          const setupRoots = [...new Set(setupHeadings.map(element =>
            element.closest("[role='dialog'], [data-state='open']") ||
              element.parentElement?.parentElement).filter(Boolean))];
          if (setupRoots.length > 1) return "ambiguous";
          const labelled = [...document.querySelectorAll(
            "h1, h2, h3, h4, p, span, div, button, a, [role='button'], [aria-label]")]
            .filter(visible)
            .filter(element => authenticatorLabels.has(normalize(
              element.getAttribute("aria-label") || element.getAttribute("title") ||
              element.innerText || element.value)));
          const authenticatorRoots = [...new Set(labelled.map(element =>
            element.closest("[role='dialog'], section, article, li, [data-testid]") ||
              element.parentElement).filter(Boolean))];
          const roots = setupRoots.length === 1 ? setupRoots : authenticatorRoots;
          if (roots.length === 0) return "notFound";
          if (roots.length !== 1) return "ambiguous";
          const fields = [...new Set(selectors.flatMap(selector =>
            [...roots[0].querySelectorAll(selector)]))].filter(visible);
          if (fields.length === 0) return "notFound";
          return fields.length === 1 ? "submitted" : "ambiguous";
        })()
        """
        guard let raw = try await session.evaluate(script) as? String,
              let result = FormResult(rawValue: raw)
        else { return .ambiguous }
        return result
    }

    func clickUniqueControl(
        labels: [String],
        click: Bool,
        in session: BrowserSession,
        expectedPageURL: URL? = nil
    ) async throws -> ControlResult {
        if let expectedPageURL, session.webView.url != expectedPageURL { return .notFound }
        let requiresAuthenticatorScope = TrustedChatGPTOrigin.allowsSecurityAutomation(
            session.webView.url)
        guard requiresAuthenticatorScope ||
                TrustedChatGPTOrigin.allowsAuthentication(session.webView.url)
        else {
            throw BrowserSessionError.untrustedOrigin
        }
        let labelsJSON = try Self.json(labels.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        })
        let expectedPageURLJSON = try Self.json(expectedPageURL?.absoluteString ?? "")
        let normalizedLabels = Set(labels.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        })
        let removalLabels = Set(removalConfirmLabels.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        })
        let action = session.webView.url.flatMap {
            URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems?
                .first(where: { $0.name.caseInsensitiveCompare("action") == .orderedSame })?
                .value?.lowercased()
        }
        let waitsForVerifiedRemoval = requiresAuthenticatorScope &&
            action == "disable" && !normalizedLabels.isDisjoint(with: removalLabels)
        let isAccountChooser = session.webView.url?.host?.lowercased() == "auth.openai.com" &&
            session.webView.url?.path.lowercased() == "/choose-an-account" &&
            normalizedLabels.count == 1 && normalizedLabels.first?.contains("@") == true
        let isLoginEntry = !requiresAuthenticatorScope &&
            session.webView.url?.host?.lowercased() == "chatgpt.com" &&
            normalizedLabels == Set(loginLabels.map { $0.lowercased() })
        let authenticatorLabelsJSON = try Self.json(authenticatorLabels.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        })
        let setupDialogLabelsJSON = try Self.json(setupDialogLabels.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        })
        let removalDialogLabelsJSON = try Self.json(removalDialogLabels.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        })
        let script = """
        (() => {
          const expectedPageURL = \(expectedPageURLJSON);
          if (expectedPageURL && location.href !== expectedPageURL) return "notFound";
          const labels = new Set(\(labelsJSON));
          const authenticatorLabels = new Set(\(authenticatorLabelsJSON));
          const setupDialogLabels = new Set(\(setupDialogLabelsJSON));
          const removalDialogLabels = new Set(\(removalDialogLabelsJSON));
          const requiresAuthenticatorScope = \(requiresAuthenticatorScope ? "true" : "false");
          const isAccountChooser = \(isAccountChooser ? "true" : "false");
          const isLoginEntry = \(isLoginEntry ? "true" : "false");
          if (isLoginEntry) { labels.add("sign in"); labels.add("вход"); }
          const normalize = value => String(value || "")
            .replace(/\\s+/g, " ").trim().toLowerCase();
          const visible = element => {
            if (isLoginEntry) {
              if (element.getAttribute("aria-disabled") === "true") return false;
              for (let node = element; node; node = node.parentElement) {
                const style = getComputedStyle(node);
                if (node.hidden || node.inert || node.getAttribute("aria-hidden") === "true" ||
                    style.visibility === "hidden" || style.visibility === "collapse" ||
                    style.display === "none" || style.opacity === "0") return false;
              }
            }
            const style = getComputedStyle(element);
            const rect = element.getBoundingClientRect();
            return style.visibility !== "hidden" && style.display !== "none" &&
              rect.width > 0 && rect.height > 0 && !element.disabled;
          };
          const displayed = element => {
            for (let current = element; current; current = current.parentElement) {
              const style = getComputedStyle(current);
              if (current.hidden || current.getAttribute("aria-hidden") === "true" ||
                  style.visibility === "hidden" || style.display === "none") return false;
            }
            const rect = element.getBoundingClientRect();
            return rect.width > 0 || rect.height > 0;
          };
          let scopes = [document];
          if (requiresAuthenticatorScope) {
            const currentURL = new URL(location.href);
            const securityPage = currentURL.origin === "https://chatgpt.com" &&
              !currentURL.username && !currentURL.password &&
              (currentURL.pathname.toLowerCase() === "/settings/security" ||
                (currentURL.pathname === "/" && currentURL.hash.toLowerCase() === "#settings/security"));
            if (!securityPage) return "notFound";
            // This dialog also removes SMS and passkeys. Check the live TOTP
            // action on every poll; the SPA can change factors without loading.
            const query = currentURL.searchParams;
            const uniqueValue = key => query.getAll(key).length === 1 ? query.get(key) : null;
            if (uniqueValue("action") === "disable" && uniqueValue("factor") === "totp" &&
                uniqueValue("factor_id")) {
              removalDialogLabels.add("remove authentication method?");
              removalDialogLabels.add("удалить способ аутентификации?");
            }
            const dialogRoots = labels => [...new Set(
              [...document.querySelectorAll("h1, h2, h3, h4")]
                .filter(displayed)
                .filter(element => labels.has(normalize(element.innerText)))
                .map(element => element.closest("[role='dialog'], [data-state='open']") ||
                  element.parentElement?.parentElement)
                .filter(Boolean))];
            const modalScopes = [
              ...dialogRoots(setupDialogLabels),
              ...dialogRoots(removalDialogLabels),
            ];
            if (modalScopes.length > 1) return "ambiguous";
            if (modalScopes.length === 1) scopes = modalScopes;
            else {
            const labelled = [...document.querySelectorAll(
              "h1, h2, h3, h4, p, span, div, button, a, [role='button'], [aria-label]")]
              .filter(visible)
              .filter(element => {
                const name = normalize(
                  element.getAttribute("aria-label") || element.getAttribute("title") ||
                  element.innerText || element.value);
                return authenticatorLabels.has(name);
              });
            scopes = [...new Set(labelled.map(element =>
              element.closest("[role='dialog'], section, article, li, [data-testid]") ||
                element.parentElement).filter(Boolean))];
            if (scopes.length === 0) return "notFound";
            if (scopes.length !== 1) return "ambiguous";
            }
          }
          let controls = [...scopes[0].querySelectorAll(
            "button, a, [role='button'], [role='switch'], input[type='button'], " +
            "input[type='submit'], input[type='checkbox']")]
            .filter(visible)
            .filter(element => {
              const labelledBy = isLoginEntry ? (element.getAttribute("aria-labelledby") || "")
                .split(/\\s+/).filter(Boolean).map(id => document.getElementById(id)?.textContent || "").join(" ") : "";
              const name = normalize(
                element.getAttribute("aria-label") || labelledBy || element.getAttribute("title") ||
                element.innerText || element.value);
              if (isAccountChooser) {
                const matchesEmail = [...labels].some(label => name.includes(label));
                return matchesEmail && !/(^|\\s)(remove|delete|удалить)/.test(name);
              }
              return labels.has(name);
            });
          if (isLoginEntry && controls.length > 1) {
            const primary = controls.filter(element => element.matches(
              "[data-login-button], [data-testid='login-button']"));
            if (primary.length === 1) controls = primary;
          }
          if (controls.length === 0) return "notFound";
          if (controls.length !== 1) return "ambiguous";
          if (\(click ? "true" : "false")) {
            controls[0].click();
            return "clicked";
          }
          return "found";
        })()
        """
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while true {
            guard let raw = try await session.evaluate(script) as? String,
                  let result = ControlResult(rawValue: raw)
            else { return .ambiguous }
            if result != .notFound || !waitsForVerifiedRemoval || clock.now >= deadline {
                return result
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    func authenticatorSwitch(
        click: Bool,
        in session: BrowserSession,
        expectedState: AuthenticatorSwitchResult? = nil
    ) async throws -> AuthenticatorSwitchResult {
        guard TrustedChatGPTOrigin.allowsSecurityAutomation(session.webView.url) else {
            throw BrowserSessionError.untrustedOrigin
        }
        let expectedStateJSON = try Self.json(expectedState?.rawValue ?? "")
        let labelsJSON = try Self.json(authenticatorLabels.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        })
        let script = """
        (() => {
          const labels = new Set(\(labelsJSON));
          const normalize = value => String(value || "")
            .replace(/\\s+/g, " ").trim().toLowerCase();
          const visible = element => {
            const style = getComputedStyle(element);
            const rect = element.getBoundingClientRect();
            return style.visibility !== "hidden" && style.display !== "none" &&
              rect.width > 0 && rect.height > 0 && !element.disabled;
          };
          const accessibleName = element => {
            const labelledBy = (element.getAttribute("aria-labelledby") || "")
              .split(/\\s+/).filter(Boolean)
              .map(id => document.getElementById(id)?.innerText || "").join(" ");
            const enclosingLabel = element.closest("label")?.innerText || "";
            return normalize(
              element.getAttribute("aria-label") || labelledBy ||
              element.getAttribute("title") || enclosingLabel || element.innerText ||
              element.value);
          };
          const switches = [...document.querySelectorAll(
            "[role='switch'], input[type='checkbox']")]
            .filter(visible)
            .filter(element => labels.has(accessibleName(element)));
          if (switches.length === 0) return "notFound";
          if (switches.length !== 1) return "ambiguous";
          const control = switches[0];
          const rawState = control.matches("input[type='checkbox']")
            ? control.checked
            : control.getAttribute("aria-checked") === "true"
              ? true
              : control.getAttribute("aria-checked") === "false" ? false : null;
          if (rawState === null) return "ambiguous";
          const state = rawState ? "on" : "off";
          const expectedState = \(expectedStateJSON);
          if (expectedState && state !== expectedState) return "ambiguous";
          if (\(click ? "true" : "false")) {
            control.click();
            return "clicked";
          }
          return state;
        })()
        """
        guard let raw = try await session.evaluate(script) as? String,
              let result = AuthenticatorSwitchResult(rawValue: raw)
        else { return .ambiguous }
        return result
    }

    static func logoutAllowsRotationCompletion(
        _ result: LogoutAllSessionsResult
    ) -> Bool {
        result == .completed
    }

    func logOutAllSessions(
        in session: BrowserSession,
        navigateToSecurityRoot: Bool = true,
        confirmationSeconds: Int = 12
    ) async -> LogoutAllSessionsResult {
        if navigateToSecurityRoot {
            _ = session.load(Self.securitySettingsURL)
        }

        let activeSessions = await sessionLogoutControl(
            labels: activeSessionsLabels,
            dialogPhrases: [],
            allowsPrefixMatch: true,
            in: session,
            seconds: 30)
        guard activeSessions == .clicked else {
            return activeSessions == .notFound ? .notFound : .ambiguous
        }

        let initial = await sessionLogoutControl(
            labels: logoutAllSessionsLabels,
            dialogPhrases: [],
            allowsPrefixMatch: false,
            in: session,
            seconds: 15)
        guard initial == .clicked else {
            return initial == .notFound ? .notFound : .ambiguous
        }

        let confirmationPhrases = [
            "log out of all devices",
            "log out all devices",
            "log out of all sessions",
            "sign out of all devices",
            "sign out all devices",
            "выйти из всех",
            "выйти со всех устройств",
            "выйти на всех устройствах",
            "завершить все сеансы",
        ]
        let confirmation = await sessionLogoutControl(
            labels: logoutAllConfirmationLabels,
            dialogPhrases: confirmationPhrases,
            allowsPrefixMatch: false,
            in: session,
            seconds: 10)
        switch confirmation {
        case .clicked:
            return await waitForLogoutConfirmationDismissal(
                phrases: confirmationPhrases,
                in: session,
                seconds: confirmationSeconds) ? .completed : .ambiguous
        case .notFound:
            return .notFound
        case .ambiguous, .found:
            return .ambiguous
        }
    }

    private func waitForLogoutConfirmationDismissal(
        phrases: [String],
        in session: BrowserSession,
        seconds: Int
    ) async -> Bool {
        guard let phrasesJSON = try? Self.json(phrases.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }) else { return false }
        let script = """
        (() => {
          const phrases = \(phrasesJSON);
          const normalize = value => String(value || "")
            .replace(/\\s+/g, " ").trim().toLowerCase();
          const displayed = element => {
            for (let current = element; current; current = current.parentElement) {
              const view = current.ownerDocument?.defaultView || window;
              const style = view.getComputedStyle(current);
              if (current.hidden || current.getAttribute("aria-hidden") === "true" ||
                  style.visibility === "hidden" || style.display === "none") return false;
            }
            const rect = element.getBoundingClientRect();
            return rect.width > 0 || rect.height > 0;
          };
          const roots = [];
          const seen = new Set();
          const visit = root => {
            if (!root || seen.has(root)) return;
            seen.add(root);
            roots.push(root);
            for (const element of root.querySelectorAll("*")) {
              const view = element.ownerDocument?.defaultView || window;
              const shadow = element.shadowRoot ||
                view.__gptAccountManagerShadowRoot?.(element);
              if (shadow) visit(shadow);
            }
          };
          visit(document);
          const marked = [...new Set(roots.flatMap(root => [...root.querySelectorAll(
            "[data-gpt-account-manager-logout-confirmation='pending']")]))];
          if (marked.length > 1) return "ambiguous";
          if (marked.length === 1) {
            return displayed(marked[0]) ? "pending" : "dismissed";
          }
          const headings = [...new Set(roots.flatMap(root => [...root.querySelectorAll(
            "h1, h2, h3, h4")]))]
            .filter(displayed)
            .filter(element => {
              const text = normalize(element.innerText);
              return phrases.some(phrase => text.includes(phrase));
            });
          if (headings.length === 0) return "dismissed";
          return headings.length === 1 ? "pending" : "ambiguous";
        })()
        """

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(max(0, seconds)))
        repeat {
            if operationIsCancelled { return false }
            if let url = session.webView.url,
               TrustedChatGPTOrigin.allowsAuthentication(url),
               !TrustedChatGPTOrigin.allowsSecurityAutomation(url) {
                return true
            }
            if TrustedChatGPTOrigin.allowsSecurityAutomation(session.webView.url),
               let state = try? await session.evaluate(script) as? String {
                if state == "dismissed" { return true }
                if state == "ambiguous" { return false }
            }
            if clock.now >= deadline { return false }
            try? await Task.sleep(for: .milliseconds(150))
        } while true
    }

    private func sessionLogoutControl(
        labels: [String],
        dialogPhrases: [String],
        allowsPrefixMatch: Bool,
        in session: BrowserSession,
        seconds: Int
    ) async -> ControlResult {
        guard let labelsJSON = try? Self.json(labels.map {
                  $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
              }),
              let phrasesJSON = try? Self.json(dialogPhrases.map {
                  $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
              })
        else { return .ambiguous }

        let script = """
        (() => {
          const labels = new Set(\(labelsJSON));
          const dialogPhrases = \(phrasesJSON);
          const allowsPrefixMatch = \(allowsPrefixMatch ? "true" : "false");
          const normalize = value => String(value || "")
            .replace(/\\s+/g, " ").trim().toLowerCase();
          const visible = element => {
            const view = element.ownerDocument?.defaultView || window;
            const style = view.getComputedStyle(element);
            const rect = element.getBoundingClientRect();
            return style.visibility !== "hidden" && style.display !== "none" &&
              rect.width > 0 && rect.height > 0 && !element.disabled;
          };
          const displayed = element => {
            for (let current = element; current; current = current.parentElement) {
              const view = current.ownerDocument?.defaultView || window;
              const style = view.getComputedStyle(current);
              if (current.hidden || current.getAttribute("aria-hidden") === "true" ||
                  style.visibility === "hidden" || style.display === "none") return false;
            }
            const rect = element.getBoundingClientRect();
            return rect.width > 0 || rect.height > 0;
          };
          const roots = [];
          const seenRoots = new Set();
          const visit = root => {
            if (!root || seenRoots.has(root)) return;
            seenRoots.add(root);
            roots.push(root);
            for (const element of root.querySelectorAll("*")) {
              const view = element.ownerDocument?.defaultView || window;
              const shadow = element.shadowRoot ||
                view.__gptAccountManagerShadowRoot?.(element);
              if (shadow) visit(shadow);
            }
          };
          visit(document);

          const controlsIn = scopes => [...new Set(scopes.flatMap(scope =>
            [...scope.querySelectorAll(
              "button, [role='button'], input[type='button'], input[type='submit']")]))]
            .filter(visible)
            .filter(element => {
              const name = normalize(
                element.getAttribute("aria-label") || element.getAttribute("title") ||
                element.innerText || element.value);
              return labels.has(name) ||
                (allowsPrefixMatch && [...labels].some(label => name.startsWith(label)));
            });

          if (dialogPhrases.length > 0) {
            const matchesPhrase = element => {
              const text = normalize(element.innerText);
              return dialogPhrases.some(phrase => text.includes(phrase));
            };
            const headings = [...new Set(roots.flatMap(root => [...root.querySelectorAll(
              "h1, h2, h3, h4")])
              .filter(displayed).filter(matchesPhrase))];
            if (headings.length === 0) return "notFound";
            if (headings.length !== 1) return "ambiguous";

            let scope = headings[0].parentElement;
            while (scope) {
              const controls = controlsIn([scope]);
              if (controls.length === 1) {
                scope.setAttribute(
                  "data-gpt-account-manager-logout-confirmation", "pending");
                controls[0].click();
                return "clicked";
              }
              if (controls.length > 1) return "ambiguous";
              scope = scope.parentElement;
            }
            return "notFound";
          }

          const controls = controlsIn(roots);
          if (controls.length === 0) return "notFound";
          if (controls.length !== 1) return "ambiguous";
          controls[0].click();
          return "clicked";
        })()
        """

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(seconds))
        while !operationIsCancelled {
            if TrustedChatGPTOrigin.allowsSecurityAutomation(session.webView.url),
               let raw = try? await session.evaluate(script) as? String,
               let result = ControlResult(rawValue: raw) {
                if result != .notFound || clock.now >= deadline {
                    return result
                }
            } else if clock.now >= deadline {
                return .ambiguous
            }
            try? await Task.sleep(for: .milliseconds(150))
        }
        return .ambiguous
    }

    private func startAuthenticatorSetup(in session: BrowserSession) async throws -> ControlResult {
        switch try await authenticatorSwitch(click: false, in: session) {
        case .off:
            return try await authenticatorSwitch(click: true, in: session, expectedState: .off) == .clicked
                ? .clicked : .ambiguous
        case .notFound:
            return try await clickUniqueControl(labels: enableLabels, click: true, in: session)
        case .ambiguous, .clicked:
            return .ambiguous
        case .on:
            return .notFound
        }
    }

    private func authenticatorAppearsEnabled(in session: BrowserSession) async throws -> Bool {
        guard TrustedChatGPTOrigin.allowsSecurityAutomation(session.webView.url) else {
            throw BrowserSessionError.untrustedOrigin
        }
        switch try await authenticatorSwitch(click: false, in: session) {
        case .on:
            return true
        case .off, .ambiguous, .clicked:
            return false
        case .notFound:
            break
        }

        let disable = try await clickUniqueControl(labels: disableLabels, click: false, in: session)
        if disable == .found { return true }
        if disable == .ambiguous { return false }

        let manage = try await clickUniqueControl(labels: manageLabels, click: false, in: session)
        guard manage == .found else { return false }
        return try await visibleFieldState(selectors: otpSelectors, in: session) == .notFound
    }

    func hasSecurityChallenge(in session: BrowserSession) async throws -> Bool {
        guard TrustedChatGPTOrigin.allowsAuthentication(session.webView.url) else {
            throw BrowserSessionError.untrustedOrigin
        }
        let script = """
        (() => {
          const isVisible = element => {
            const style = getComputedStyle(element);
            const rect = element.getBoundingClientRect();
            return style.display !== 'none' &&
              style.visibility !== 'hidden' &&
              Number(style.opacity || 1) > 0 &&
              rect.width > 1 && rect.height > 1;
          };
          const frameText = [...document.querySelectorAll("iframe")]
            .filter(isVisible)
            .map(frame => `${frame.src || ""} ${frame.title || ""}`.toLowerCase())
            .join(" ");
          const pageText = (document.body?.innerText || "").toLowerCase();
          return `${frameText}\n${pageText}`;
        })()
        """
        let text = (try await session.evaluate(script) as? String) ?? ""
        return Self.detectsSecurityChallenge(url: session.webView.url, text: text)
    }

    private func hasAuthenticationServerError(in session: BrowserSession) async throws -> Bool {
        let text = try await authenticationPageText(in: session)
        return Self.detectsAuthenticationServerError(url: session.webView.url, text: text)
    }

    func hasDeactivatedAccount(in session: BrowserSession) async throws -> Bool {
        guard TrustedChatGPTOrigin.allowsAuthentication(session.webView.url) else {
            throw BrowserSessionError.untrustedOrigin
        }
        let text = (try await session.evaluate(
            "(document.body?.innerText || document.documentElement?.innerText || '')"
        ) as? String) ?? ""
        return Self.detectsDeactivatedAccount(url: session.webView.url, text: text)
    }

    private func hasRejectedAuthenticatorCode(in session: BrowserSession) async throws -> Bool {
        guard TrustedChatGPTOrigin.allowsAuthentication(session.webView.url) else {
            throw BrowserSessionError.untrustedOrigin
        }
        let text = (try await session.evaluate(
            "(document.body?.innerText || document.documentElement?.innerText || '')"
        ) as? String) ?? ""
        return Self.detectsRejectedAuthenticatorCode(url: session.webView.url, text: text)
    }

    private func authenticationPageText(in session: BrowserSession) async throws -> String {
        guard TrustedChatGPTOrigin.allowsAuthentication(session.webView.url) else {
            throw BrowserSessionError.untrustedOrigin
        }
        return (try await session.evaluate(
            """
            (() => {
              const roots = [];
              const seen = new Set();
              const collect = root => {
                if (!root || seen.has(root)) return;
                seen.add(root);
                roots.push(root);
                for (const element of root.querySelectorAll('*')) {
                  const view = element.ownerDocument?.defaultView || window;
                  const shadow = element.shadowRoot ||
                    view.__gptAccountManagerShadowRoot?.(element);
                  if (shadow) collect(shadow);
                }
              };
              collect(document.body || document.documentElement);
              return roots.map(root => root.innerText || root.textContent || '')
                .join(' ');
            })()
            """ ) as? String) ?? ""
    }

    private func loadAndWait(
        _ url: URL,
        in session: BrowserSession,
        seconds: Int
    ) async -> Bool {
        if operationIsCancelled { return false }
        if session.needsInitialPageLoad {
            let loaded = await session.loadInitialPage(url, seconds: seconds)
            return loaded && !operationIsCancelled
        }
        let navigation = session.load(url)
        guard await session.waitForNavigation(navigation, seconds: seconds) else {
            return false
        }
        return !operationIsCancelled &&
            TrustedChatGPTOrigin.allowsTopLevelNavigation(session.webView.url)
    }

    private func waitAfterSubmission(in session: BrowserSession) async {
        try? await Task.sleep(for: .milliseconds(700))
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while !operationIsCancelled, session.webView.isLoading, clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    private static func json(_ value: Any) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])
        guard let string = String(data: data, encoding: .utf8) else {
            throw SubscriptionSnapshotError.invalidPayload
        }
        return string
    }

    static let securitySettingsURL = URL(string: "https://chatgpt.com/settings/security")!
    private static let pricingURL = URL(string: "https://chatgpt.com/#pricing")!

    private static let pricingDetailsScript = #"""
    (() => {
      const normalize = value => String(value || "")
        .replace(/\s+/g, " ").trim().toLocaleLowerCase();
      const displayed = element => {
        if (!(element instanceof Element)) return false;
        for (let node = element; node instanceof Element; node = node.parentElement) {
          const style = getComputedStyle(node);
          if (style.display === "none" || style.visibility === "hidden" ||
              style.opacity === "0" || node.hidden) return false;
        }
        return element.getClientRects().length > 0;
      };
      const currentLabels = new Set(["your current plan", "ваш текущий план"]);
      const controls = [...document.querySelectorAll("button,[role='button']")]
        .filter(displayed)
        .filter(control => currentLabels.has(normalize(
          control.innerText || control.getAttribute("aria-label") || control.textContent)));
      if (controls.length !== 1) return { state: "unavailable" };

      const ownText = element => [...element.childNodes]
        .filter(node => node.nodeType === Node.TEXT_NODE)
        .map(node => node.textContent || "")
        .join(" ").replace(/\s+/g, " ").trim();
      const datePattern = /^(?:до|until|through|expires(?:\s+on)?|renews(?:\s+on)?)\s+.*\d{4}\s*(?:г\.?)?$/iu;
      for (let scope = controls[0].parentElement;
           scope && scope !== document.body;
           scope = scope.parentElement) {
        const candidates = [...scope.querySelectorAll("*")]
          .filter(displayed)
          .map(ownText)
          .filter(text => datePattern.test(text));
        const unique = [...new Set(candidates)];
        if (unique.length === 1) {
          return {
            state: "success",
            activeUntilText: unique[0],
            locale: document.documentElement.lang || "en-US"
          };
        }
        if (unique.length > 1) return { state: "unavailable" };
      }
      return { state: "unavailable" };
    })()
    """#

    private static let subscriptionScript = #"""
    (async () => {
      const documentAtStart = document, urlAtStart = location.href;
      const current = () => document === documentAtStart && location.href === urlAtStart;
      const read = async (url, options) => {
        const abort = new AbortController();
        const timer = setTimeout(() => abort.abort(), 6000);
        try { return await fetch(url, {...options,signal:abort.signal}); }
        finally { clearTimeout(timer); }
      };
      try {
        const response = await read("/api/auth/session", { credentials: "include", cache: "no-store" });
        if (!current()) return {state:'unavailable'};
        if (response.status === 401 || response.status === 403) return { state: "loginRequired" };
        if (!response.ok) {
          const hint = response.headers?.get?.('Retry-After');
          const parsed = hint ? Number(hint) : 0;
          return {state:'unavailable',retryable:response.status === 429 || response.status >= 500,
            retryAfterSeconds:Number.isFinite(parsed) ? parsed : Math.max(0,(Date.parse(hint)-Date.now())/1000) || 0};
        }
        const session = await response.json();
        if (!current()) return {state:'unavailable'};
        const email = session?.user?.email;
        const token = session?.accessToken;
        if (!email) return { state: "loginRequired" };

        let auth = {};
        if (token) {
          try {
            const part = token.split(".")[1];
            if (part) {
              const padded = part.replace(/-/g, "+").replace(/_/g, "/") +
                "=".repeat((4 - part.length % 4) % 4);
              const bytes = Uint8Array.from(atob(padded), c => c.charCodeAt(0));
              const claims = JSON.parse(new TextDecoder().decode(bytes));
              auth = claims["https://api.openai.com/auth"] || {};
            }
          } catch (_) {}
        }
        const accountID = auth.chatgpt_account_id || session?.account?.id ||
          session?.user?.account_id || null;

        let subscription = null;
        if (accountID) {
          const subResponse = await read(
            "/backend-api/subscriptions?account_id=" + encodeURIComponent(accountID),
            { credentials: "include", headers: token ? { Authorization: "Bearer " + token } : {} });
          if (subResponse.ok) {
            const payload = await subResponse.json();
            if (!current()) return {state:'unavailable'};
            if (Array.isArray(payload)) {
              subscription = payload.find(item =>
                String(item?.account_id || item?.accountId || "") === String(accountID)) || null;
            } else {
              const candidate = payload?.subscription || payload;
              const candidateAccountID = candidate?.account_id || candidate?.accountId || null;
              if (!candidateAccountID || String(candidateAccountID) === String(accountID)) {
                subscription = candidate;
              }
            }
          }
        }

        if (subscription) {
          return {
            state: "success",
            email,
            source: "subscription",
            plan: subscription.plan_type || "unknown",
            activeUntil: subscription.active_until || null,
            willRenew: typeof subscription.will_renew === "boolean" ?
              subscription.will_renew : null
          };
        }

        return {
          state: "success",
          email,
          source: "session",
          plan: auth.chatgpt_plan_type || session?.account?.planType || "unknown",
          activeUntil: null,
          willRenew: null
        };
      } catch (_) {
        return { state: "unavailable", retryable:current() };
      }
    })()
    """#
}

// Password changes precede the existing 2FA rotation; its checkpoints stay unchanged.
private final class PasswordEmailRequest {
    let accountID: UUID
    let email: String
    let purpose: MailVerificationPurpose
    let since: Date
    let baseline: Set<String>
    var submitted = false
    var submittedLoginStages: Set<String> = []
    var mail: MailVerificationCode?

    init(account: AccountRecord, purpose: MailVerificationPurpose, since: Date, baseline: Set<String>) {
        accountID = account.id
        email = account.email
        self.purpose = purpose
        self.since = since
        self.baseline = baseline
    }
}

enum PasswordEmailAutomationError: Error, LocalizedError {
    case baselineMissing, identityChanged, challengeChanged

    var errorDescription: String? {
        switch self {
        case .baselineMissing:
            "Код уже запрошен без подготовленной проверки почты. Введите его вручную; для нового входа начните проверку заново."
        case .identityChanged:
            "Адрес аккаунта или получателя кода изменился. Автоматическая смена пароля остановлена."
        case .challengeChanged:
            "Форма почтового кода изменилась. Проверьте страницу OpenAI и продолжите вручную."
        }
    }
}

extension ChatGPTAutomation {
    static func isPasswordEmailCodeRoute(_ url: URL?) -> Bool {
        TrustedChatGPTOrigin.allowsAuthentication(url) &&
            url?.host?.lowercased() == "auth.openai.com" &&
            ["/email-verification", "/verify-email"].contains(url?.path.lowercased() ?? "")
    }

    // Capture before the action that requests mail. Resuming never recaptures that baseline.
    func preparePasswordEmailRequest(
        account: AccountRecord, in session: BrowserSession, purpose: MailVerificationPurpose
    ) async throws {
        guard let passwordMailbox else { return }
        let key = ObjectIdentifier(session)
        if let request = passwordEmailRequests[key] {
            guard request.accountID == account.id,
                  request.email.caseInsensitiveCompare(account.email) == .orderedSame else {
                throw PasswordEmailAutomationError.identityChanged
            }
            if request.purpose == purpose { return }
        }
        guard !Self.isPasswordEmailCodeRoute(session.webView.url) else {
            throw PasswordEmailAutomationError.baselineMissing
        }
        let generation = passwordMailboxGeneration
        let sessionGeneration = session.cancellationGeneration
        let baseline = try await passwordMailbox.captureBaseline()
        guard !operationIsCancelled, generation == passwordMailboxGeneration,
              sessionGeneration == session.cancellationGeneration else { throw CancellationError() }
        passwordEmailRequests[key] = PasswordEmailRequest(
            account: account, purpose: purpose,
            since: Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970)), baseline: baseline)
    }

    func submitPasswordEmailCode(
        account: AccountRecord, in session: BrowserSession, purpose: MailVerificationPurpose
    ) async throws -> Bool {
        guard let passwordMailbox else { return false }
        guard !operationIsCancelled else { throw CancellationError() }
        let key = ObjectIdentifier(session)
        guard let request = passwordEmailRequests[key], request.purpose == purpose else {
            throw PasswordEmailAutomationError.baselineMissing
        }
        guard request.accountID == account.id,
              request.email.caseInsensitiveCompare(account.email) == .orderedSame else {
            throw PasswordEmailAutomationError.identityChanged
        }
        guard Self.isPasswordEmailCodeRoute(session.webView.url) else {
            throw PasswordEmailAutomationError.challengeChanged
        }
        let generation = passwordMailboxGeneration
        let sessionGeneration = session.cancellationGeneration
        let pageURL = session.webView.url
        var deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while ContinuousClock.now < deadline {
            guard !operationIsCancelled, generation == passwordMailboxGeneration,
                  sessionGeneration == session.cancellationGeneration,
                  passwordEmailRequests[key] === request else { throw CancellationError() }
            guard Self.isPasswordEmailCodeRoute(session.webView.url), session.webView.url == pageURL else {
                throw PasswordEmailAutomationError.challengeChanged
            }
            let state = try await RegistrationForm.inspect(in: session)
            if state.kind == .emailCode, state.pageURL == pageURL {
                guard state.displayedEmail?.caseInsensitiveCompare(account.email) == .orderedSame else {
                    throw PasswordEmailAutomationError.identityChanged
                }
                // A submitted challenge may remain visible while OpenAI processes it.
                if request.submitted { return true }
                if request.mail == nil {
                    request.mail = try await passwordMailbox.waitForCode(
                        alias: account.email, since: request.since, excluding: request.baseline, purpose: purpose)
                    deadline = ContinuousClock.now.advanced(by: .seconds(10))
                    continue // Recheck route, identity and cancellation after mailbox suspension.
                }
                guard let mail = request.mail, !request.baseline.contains(mail.messageID) else {
                    throw PasswordEmailAutomationError.challengeChanged
                }
                guard !operationIsCancelled, generation == passwordMailboxGeneration,
                      sessionGeneration == session.cancellationGeneration else { throw CancellationError() }
                if try await RegistrationForm.submitEmailCode(mail.code, expectedEmail: account.email, in: session) {
                    request.submitted = true
                    return true
                }
            }
            try await Task.sleep(for: .milliseconds(200))
        }
        throw PasswordEmailAutomationError.challengeChanged
    }

    func changePassword(
        account: AccountRecord,
        newPassword: String,
        onSubmission: @escaping @MainActor () throws -> Void
    ) async -> PasswordChangeOutcome {
        let newPassword = account.pendingPassword ?? newPassword
        PasswordChangeTelemetry.record(.started)
        var completed = false
        defer {
            if !completed { PasswordChangeTelemetry.record(operationIsCancelled ? .cancelled : .paused) }
        }
        guard !operationIsCancelled else { return .failure("Stopped") }
        if account.pendingPassword != nil && !passwordChangeRetries.contains(account.id) {
            let result = await verifyChangedPassword(account: account, newPassword: newPassword)
            if case .success = result { completed = true }
            return result
        }
        // Keep the account's signed-in session for mutation; candidate verification stays fresh.
        let session: BrowserSession
        if passwordChangeStarted.contains(account.id), let existing = rotationSessions[account.id] {
            session = existing
        } else {
            session = sessionManager.session(for: account)
            rotationSessions[account.id] = session
        }
        preparedRotationSessionIDs.remove(account.id)
        activeSession = session
        session.setVisible(true)
        session.setOperationMessage("Смена пароля: вход и подтверждение личности…")
        if let request = passwordEmailRequests[ObjectIdentifier(session)],
           request.accountID != account.id || request.email.caseInsensitiveCompare(account.email) != .orderedSame {
            return .failure(PasswordEmailAutomationError.identityChanged.localizedDescription)
        }
        if !passwordChangeStarted.contains(account.id) {
            do {
                try await preparePasswordEmailRequest(account: account, in: session, purpose: .login)
            } catch {
                return operationIsCancelled ? .failure("Stopped") : .manualActionRequired(error.localizedDescription)
            }
            let emailCodeHandler: (@MainActor (BrowserSession) async throws -> Bool)?
            if passwordMailbox != nil {
                emailCodeHandler = { @MainActor session in
                    try await self.submitPasswordEmailCode(account: account, in: session, purpose: .login)
                }
            } else {
                emailCodeHandler = nil
            }
            switch await authenticate(account: account, secret: account.totpSecret, in: session,
                                      emailCodeHandler: emailCodeHandler) {
            case .success: break
            case .manual(let message): return .manualActionRequired(message)
            case .failure(let message): return .failure(message)
            }
            passwordReauthentication[account.id] = PasswordReauthenticationState(
                originalIdentity: try? await EmailChangeAutomation.identity(in: session))
            do {
                try await preparePasswordEmailRequest(account: account, in: session, purpose: .passwordChange)
            } catch {
                return operationIsCancelled ? .failure("Stopped") : .manualActionRequired(error.localizedDescription)
            }
            passwordChangeStarted.insert(account.id)
            if !TrustedChatGPTOrigin.allowsSecurityAutomation(session.webView.url) {
                // The loop below waits for the actual password form, not unrelated subresources.
                _ = session.load(Self.securitySettingsURL)
            }
        }

        let clock = ContinuousClock()
        var deadline = clock.now.advanced(by: .seconds(60))
        var lastRoute: String?
        while clock.now < deadline {
            guard !operationIsCancelled else { return .failure("Stopped") }
            let route = PasswordChangeTelemetry.route(session.webView.url)
            if route != lastRoute {
                PasswordChangeTelemetry.recordRoute(route)
                lastRoute = route
            }
            guard TrustedChatGPTOrigin.allowsAuthentication(session.webView.url) else {
                return .manualActionRequired("Вернитесь на страницу OpenAI для смены пароля.")
            }
            if Self.detectsAuthenticationCallbackError(url: session.webView.url) {
                return .manualActionRequired("OpenAI не завершил подтверждение личности. Вернитесь в браузер и продолжите смену пароля.")
            }
            if session.webView.url?.host?.lowercased() == "auth.openai.com" {
                passwordReauthentication[account.id, default: .init()].authenticationObserved = true
            }
            let path = session.webView.url?.path.lowercased() ?? ""
            if (try? await hasSecurityChallenge(in: session)) == true {
                return .manualActionRequired("Пройдите проверку OpenAI в браузере и продолжите смену доступов.")
            }
            do {
                if Self.isPasswordEmailCodeRoute(session.webView.url) {
                    let alreadySubmitted = passwordEmailRequests[ObjectIdentifier(session)]?.submitted == true
                    guard try await submitPasswordEmailCode(account: account, in: session, purpose: .passwordChange) else {
                        return .manualActionRequired("Введите код из почты в браузере, затем нажмите «Продолжить смену доступов».")
                    }
                    if !alreadySubmitted { deadline = clock.now.advanced(by: .seconds(60)) }
                    await waitAfterSubmission(in: session)
                    continue
                }
                switch try await PasswordChangeForm.apply(in: session, currentPassword: account.password,
                                                          newPassword: newPassword, submit: false) {
                case .ready:
                    if session.webView.url?.host?.lowercased() == "chatgpt.com" {
                        guard case .success(let snapshot) = try await metadata(in: session),
                              snapshot.signedInEmail.caseInsensitiveCompare(account.email) == .orderedSame else {
                            return .failure("Аккаунт в форме смены пароля не совпадает с выбранным.")
                        }
                    }
                    // Persist before submitting: a crash must retain both old and candidate passwords.
                    try onSubmission()
                    guard try await PasswordChangeForm.apply(in: session, currentPassword: account.password,
                                                             newPassword: newPassword, submit: true) == .submitted else {
                        return .manualActionRequired("Форма пароля изменилась. Проверьте её вручную и продолжите.")
                    }
                    PasswordChangeTelemetry.record(.passwordSubmitted)
                    await waitAfterSubmission(in: session)
                    passwordChangeRetries.remove(account.id)
                    let result = await verifyChangedPassword(account: account, newPassword: newPassword)
                    if case .success = result { completed = true }
                    return result
                case .ambiguous:
                    return .manualActionRequired("Форма нового пароля неоднозначна. Заполните её вручную и продолжите смену доступов.")
                case .notFound, .submitted: break
                }
                if let reauthentication = passwordReauthentication[account.id], reauthentication.authenticationObserved,
                   !session.webView.isLoading, let url = session.webView.url,
                   TrustedChatGPTOrigin.allowsMetadata(url),
                   TrustedChatGPTOrigin.allowsSecurityAutomation(url) ||
                    ((url.path.isEmpty || url.path == "/") && url.fragment?.isEmpty != false),
                   case .success(let snapshot) = try await metadata(in: session) {
                    guard !operationIsCancelled else { return .failure("Stopped") }
                    guard session.webView.url == url, !session.webView.isLoading else { continue }
                    guard snapshot.signedInEmail.caseInsensitiveCompare(account.email) == .orderedSame else {
                        return .failure("После подтверждения личности открыт другой аккаунт. Пароль не отправлен.")
                    }
                    if let originalIdentity = reauthentication.originalIdentity {
                        let identity = try await EmailChangeAutomation.identity(in: session)
                        guard !operationIsCancelled else { return .failure("Stopped") }
                        guard session.webView.url == url, !session.webView.isLoading else { continue }
                        guard identity.email.caseInsensitiveCompare(account.email) == .orderedSame,
                              identity.userID == originalIdentity.userID else {
                            return .failure("После подтверждения личности открыт другой аккаунт. Пароль не отправлен.")
                        }
                    }
                    PasswordChangeTelemetry.record(.reauthenticationReturned)
                    guard !reauthentication.reopened else {
                        return .manualActionRequired("OpenAI снова вернул настройки или главную страницу после входа. Откройте форму нового пароля и продолжите.")
                    }
                    // A completed reauthentication may drop its callback. Reopen once,
                    // only after identity proof, and capture mail before the new click.
                    passwordEmailRequests.removeValue(forKey: ObjectIdentifier(session))
                    try await preparePasswordEmailRequest(account: account, in: session, purpose: .passwordChange)
                    guard !operationIsCancelled else { return .failure("Stopped") }
                    guard session.webView.url == url, !session.webView.isLoading else { continue }
                    // Mailbox work suspends; the same URL can now belong to another account.
                    guard case .success(let currentSnapshot) = try await metadata(in: session),
                          currentSnapshot.signedInEmail.caseInsensitiveCompare(account.email) == .orderedSame else {
                        return .failure("Во время чтения почты изменился аккаунт. Пароль не отправлен.")
                    }
                    if let originalIdentity = reauthentication.originalIdentity {
                        let identity = try await EmailChangeAutomation.identity(in: session)
                        guard identity.email.caseInsensitiveCompare(account.email) == .orderedSame,
                              identity.userID == originalIdentity.userID else {
                            return .failure("Во время чтения почты изменился аккаунт. Пароль не отправлен.")
                        }
                    }
                    guard !operationIsCancelled else { return .failure("Stopped") }
                    guard session.webView.url == url, !session.webView.isLoading else { continue }
                    passwordReauthentication[account.id]?.reopened = true
                    passwordReauthentication[account.id]?.authenticationObserved = false
                    passwordFormOpened.remove(account.id)
                    passwordReauthenticationStages.removeValue(forKey: account.id)
                    deadline = clock.now.advanced(by: .seconds(60))
                    session.setOperationMessage("Смена пароля: личность подтверждена, открываются настройки безопасности…")
                    if !TrustedChatGPTOrigin.allowsSecurityAutomation(url) {
                        PasswordChangeTelemetry.record(.reopeningSettings)
                        _ = session.load(Self.securitySettingsURL)
                    }
                    continue
                }
                if !passwordFormOpened.contains(account.id),
                   TrustedChatGPTOrigin.allowsSecurityAutomation(session.webView.url),
                   try await PasswordChangeForm.open(in: session) {
                    passwordFormOpened.insert(account.id)
                    PasswordChangeTelemetry.record(.passwordFormOpened)
                    deadline = clock.now.advanced(by: .seconds(60))
                    await waitAfterSubmission(in: session)
                    continue
                }
                // Never send a TOTP into an email-code form or an old password into a new-password field.
                if session.webView.url?.host == "auth.openai.com", path == "/log-in/password",
                   passwordReauthenticationStages[account.id]?.contains(path) != true {
                    let result = try await fillAndSubmit(selectors: passwordSelectors, value: account.password,
                                                        context: .authentication, in: session,
                                                        expectedPageURL: session.webView.url, expectedEmail: account.email)
                    if result == .submitted {
                        passwordReauthenticationStages[account.id, default: []].insert(path)
                        deadline = clock.now.advanced(by: .seconds(60))
                        await waitAfterSubmission(in: session); continue
                    }
                } else if session.webView.url?.host == "auth.openai.com", path.hasPrefix("/mfa-challenge/"),
                          passwordReauthenticationStages[account.id]?.contains(path) != true {
                    let delay = TOTPService.safeSubmissionDelay()
                    if delay > 0 { try await Task.sleep(for: .seconds(delay + 0.15)) }
                    guard !operationIsCancelled else { return .failure("Stopped") }
                    let code = try TOTPService.code(secret: account.totpSecret)
                    var result = try await submitAuthenticationOTP(value: code, in: session)
                    if Self.needsKeyboardMFAFallback(url: session.webView.url, formResult: result),
                       await session.submitMFAUsingKeyboard(code) { result = .submitted }
                    if result == .submitted {
                        passwordReauthenticationStages[account.id, default: []].insert(path)
                        deadline = clock.now.advanced(by: .seconds(60))
                        await waitAfterSubmission(in: session); continue
                    }
                }
            } catch {
                if operationIsCancelled { return .failure("Stopped") }
                if error is PasswordEmailAutomationError || error is MailVerificationError {
                    return .manualActionRequired(error.localizedDescription)
                }
                return .manualActionRequired("Не удалось безопасно продолжить смену пароля. Проверьте открытую форму.")
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return .manualActionRequired("OpenAI ожидает действие. Завершите подтверждение личности или откройте форму нового пароля и продолжите.")
    }

    func resetPasswordChange(for id: UUID) {
        passwordChangeStarted.remove(id)
        passwordFormOpened.remove(id)
        passwordChangeRetries.remove(id)
        passwordReauthenticationStages.removeValue(forKey: id)
        passwordReauthentication.removeValue(forKey: id)
        passwordEmailRequests = passwordEmailRequests.filter { $0.value.accountID != id }
        passwordVerificationSessions.removeValue(forKey: id)?.cancelLoading()
    }

    func retryPasswordChange(for id: UUID) {
        resetPasswordChange(for: id)
        passwordChangeRetries.insert(id)
        rotationSessions.removeValue(forKey: id)?.cancelLoading()
        preparedRotationSessionIDs.remove(id)
    }

    private func verifyChangedPassword(account: AccountRecord, newPassword: String) async -> PasswordChangeOutcome {
        PasswordChangeTelemetry.record(.verificationStarted)
        guard !operationIsCancelled else { return .failure("Stopped") }
        // Each attempt starts clean. A manually completed login cannot certify the candidate password.
        let session = sessionManager.verificationSession(for: account)
        passwordVerificationSessions[account.id] = session
        activeSession = session
        session.setVisible(true)
        session.setOperationMessage("Смена пароля: проверочный вход с новым паролем…")
        var accepted = false
        defer {
            passwordVerificationSessions.removeValue(forKey: account.id)
            passwordEmailRequests.removeValue(forKey: ObjectIdentifier(session))
            if !accepted {
                session.cancelLoading()
                session.setVisible(false)
                activeSession = rotationSessions[account.id]
                activeSession?.setVisible(true)
                activeSession?.setOperationMessage("Новый пароль ещё не подтверждён. Проверьте исходную форму и продолжите смену доступов.")
            }
        }
        do {
            try await preparePasswordEmailRequest(account: account, in: session, purpose: .login)
        } catch {
            return operationIsCancelled ? .failure("Stopped") : .manualActionRequired(error.localizedDescription)
        }
        let generation = session.cancellationGeneration
        _ = await session.waitUntilAttached(seconds: 3)
        guard await loadAndWait(URL(string: "https://chatgpt.com/")!, in: session, seconds: 30) else {
            return .manualActionRequired("Проверочная страница не загрузилась. Продолжите для повторной попытки.")
        }
        let clock = ContinuousClock()
        var deadline = clock.now.advanced(by: .seconds(60))
        var passwordSubmitted = false
        var otpSubmitted = false
        var submittedStages: Set<String> = []
        while clock.now < deadline {
            guard !operationIsCancelled, generation == session.cancellationGeneration else { return .failure("Stopped") }
            guard TrustedChatGPTOrigin.allowsAuthentication(session.webView.url) else {
                return .manualActionRequired("Вернитесь на доверенную страницу OpenAI для проверки нового пароля.")
            }
            if await dismissCookieConsent(in: session) == .clicked { continue }
            let path = session.webView.url?.path.lowercased() ?? ""
            let pageText = (try? await session.evaluate("document.body?.innerText || ''")) as? String ?? ""
            if PasswordChangeForm.rejectsPassword(pageText) {
                return .manualActionRequired("OpenAI отклонил новый пароль. Завершите смену в исходной форме и повторите проверку. Старый пароль сохранён.")
            }
            if (try? await hasSecurityChallenge(in: session)) == true {
                return .manualActionRequired("OpenAI запросил дополнительную проверку. Новый пароль не сохранён как основной; повторите проверочный вход позже.")
            }
            if case .success(let snapshot) = try? await metadata(in: session) {
                guard passwordSubmitted,
                      snapshot.signedInEmail.caseInsensitiveCompare(account.email) == .orderedSame else {
                    return .failure("Чистый вход с новым паролем в выбранный аккаунт не подтверждён.")
                }
                do {
                    try await persistVerifiedSession(from: session, for: account)
                } catch {
                    return .manualActionRequired("Новый пароль проверен, но сессия ещё не сохранена. Продолжите для повторной проверки.")
                }
                rotationSessions[account.id]?.setVisible(false)
                session.setVisible(false)
                session.setOperationMessage(nil)
                let persistent = accountSession(for: account)
                rotationSessions[account.id] = persistent
                activeSession = persistent
                persistent.setVisible(true)
                preparedRotationSessionIDs.insert(account.id)
                passwordChangeStarted.remove(account.id)
                passwordFormOpened.remove(account.id)
                passwordChangeRetries.remove(account.id)
                passwordReauthenticationStages.removeValue(forKey: account.id)
                passwordReauthentication.removeValue(forKey: account.id)
                passwordEmailRequests = passwordEmailRequests.filter { $0.value.accountID != account.id }
                persistent.setOperationMessage("Новый пароль проверен входом.")
                accepted = true
                PasswordChangeTelemetry.record(.verified)
                return .success(signedInEmail: snapshot.signedInEmail)
            }
            do {
                if Self.isPasswordEmailCodeRoute(session.webView.url) {
                    if !passwordSubmitted, !submittedStages.contains("passwordChoice"),
                       try await RegistrationForm.selectPasswordLogin(in: session) {
                        submittedStages.insert("passwordChoice")
                        deadline = clock.now.advanced(by: .seconds(60))
                        await waitAfterSubmission(in: session)
                        continue
                    }
                    if !passwordSubmitted, submittedStages.contains("passwordChoice") {
                        try await Task.sleep(for: .milliseconds(250))
                        continue
                    }
                    let alreadySubmitted = passwordEmailRequests[ObjectIdentifier(session)]?.submitted == true
                    guard try await submitPasswordEmailCode(account: account, in: session, purpose: .login) else {
                        return .manualActionRequired("Для проверки нового пароля OpenAI требует код из почты. Откройте Mail.ru и повторите проверку.")
                    }
                    if !alreadySubmitted { deadline = clock.now.advanced(by: .seconds(60)) }
                    await waitAfterSubmission(in: session)
                    continue
                }
                if !passwordSubmitted {
                    let email: FormResult = submittedStages.contains(path + ":email") ? .notFound : try await fillAndSubmit(selectors: emailSelectors, value: account.email,
                                                        context: .authentication, in: session)
                    if email == .submitted {
                        submittedStages.insert(path + ":email")
                        deadline = clock.now.advanced(by: .seconds(60))
                        await waitAfterSubmission(in: session); continue
                    }
                    if !submittedStages.contains(path + ":login"),
                       try await clickUniqueControl(labels: loginLabels, click: true, in: session) == .clicked {
                        submittedStages.insert(path + ":login")
                        deadline = clock.now.advanced(by: .seconds(60))
                        await waitAfterSubmission(in: session); continue
                    }
                    let result: FormResult = session.webView.url?.host?.lowercased() == "auth.openai.com" && path == "/log-in/password"
                        ? try await fillAndSubmit(selectors: passwordSelectors, value: newPassword,
                                                  context: .authentication, in: session,
                                                  expectedPageURL: session.webView.url, expectedEmail: account.email)
                        : .notFound
                    if result == .submitted {
                        passwordSubmitted = true
                        deadline = clock.now.advanced(by: .seconds(60))
                        await waitAfterSubmission(in: session)
                        continue
                    }
                }
                if passwordSubmitted && !otpSubmitted && session.webView.url?.host?.lowercased() == "auth.openai.com" && path.hasPrefix("/mfa-challenge/") {
                    let delay = TOTPService.safeSubmissionDelay()
                    if delay > 0 { try await Task.sleep(for: .seconds(delay + 0.15)) }
                    guard !operationIsCancelled, generation == session.cancellationGeneration else { return .failure("Stopped") }
                    let code = try TOTPService.code(secret: account.totpSecret)
                    var result = try await submitAuthenticationOTP(value: code, in: session)
                    if Self.needsKeyboardMFAFallback(url: session.webView.url, formResult: result),
                       await session.submitMFAUsingKeyboard(code) { result = .submitted }
                    if result == .submitted {
                        otpSubmitted = true
                        deadline = clock.now.advanced(by: .seconds(60))
                        await waitAfterSubmission(in: session); continue
                    }
                }
            } catch {
                if operationIsCancelled || generation != session.cancellationGeneration { return .failure("Stopped") }
                if error is PasswordEmailAutomationError || error is MailVerificationError {
                    return .manualActionRequired(error.localizedDescription)
                }
                return .manualActionRequired("Проверочный вход прерван. Проверьте исходную форму смены пароля и продолжите.")
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return .manualActionRequired("Проверочный вход не завершён. Проверьте исходную форму смены пароля и продолжите.")
    }
}
