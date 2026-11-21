import Foundation
import Observation

@MainActor
@Observable
final class CodexAccImportCoordinator {
    struct Dependencies {
        var start: @MainActor (AccountRecord) async throws -> CodexAccImportStart
        var status: @MainActor (String) async throws -> CodexAccImportStatus
        var cancel: @MainActor (String) async throws -> CodexAccImportStatus
        var prepare: @MainActor (AccountRecord, URL) async throws -> BrowserSession
        var advance: @MainActor (AccountRecord, BrowserSession) async throws -> CodexAccAuthorization.State
        var now: @MainActor () -> Date = Date.init
        var wait: @MainActor () async throws -> Void = { try await Task.sleep(for: .milliseconds(500)) }
    }

    private(set) var isRunning = false
    private(set) var isPaused = false
    private(set) var completedCount = 0
    private(set) var totalCount = 0
    private(set) var message: String?
    private(set) var protectedAccountIDs: Set<UUID> = []
    private var queue: [AccountRecord] = []
    private var attempt: CodexAccImportAttempt?
    private var deadline: Date?
    private var session: BrowserSession?
    private var sessionAccountID: UUID?
    private var restartOnResume = false
    private var stopping = false
    private var worker: Task<Void, Never>?
    private let dependencies: Dependencies
    private let onSelect: @MainActor (UUID) -> Void

    convenience init(browser: ChatGPTAutomation, onSelect: @escaping @MainActor (UUID) -> Void) {
        let client = CodexAccImportClient()
        let authorization = CodexAccAuthorization(browser: browser)
        self.init(dependencies: .init(
            start: { try await client.start(account: $0) },
            status: { try await client.status(attemptID: $0) },
            cancel: { try await client.cancel(attemptID: $0) },
            prepare: { try await authorization.prepare(account: $0, authorizationURL: $1) },
            advance: { try await authorization.advance(account: $0, in: $1) }), onSelect: onSelect)
    }

    init(dependencies: Dependencies, onSelect: @escaping @MainActor (UUID) -> Void = { _ in }) {
        self.dependencies = dependencies
        self.onSelect = onSelect
    }

    func browserSession(for accountID: UUID) -> BrowserSession? {
        sessionAccountID == accountID ? session : nil
    }

    func start(accounts: [AccountRecord]) async {
        guard !isRunning, !isPaused, !stopping, protectedAccountIDs.isEmpty else { return }
        var seen: Set<UUID> = []
        let snapshot = accounts.filter { seen.insert($0.id).inserted }
        guard !snapshot.isEmpty else { message = "Нет аккаунтов для импорта в CodexAcc."; return }
        guard snapshot.allSatisfy({
            !$0.hasPendingCredentialChange && $0.rotationStage == nil && $0.pendingTOTPSecret == nil
        }) else {
            message = "Сначала завершите смену почты, пароля или 2FA выбранных аккаунтов."
            return
        }
        queue = snapshot
        protectedAccountIDs = Set(snapshot.map(\.id))
        totalCount = snapshot.count
        completedCount = 0
        restartOnResume = false
        await run()
    }

    func resume() async {
        guard isPaused, !isRunning, !stopping, !queue.isEmpty else { return }
        await run()
    }

    /// Waits for an in-flight start before cancelling its returned attempt.
    /// Protection remains in place until CodexAcc acknowledges cancellation.
    func stop() async {
        guard !stopping, !protectedAccountIDs.isEmpty else { return }
        stopping = true
        isRunning = true
        isPaused = false
        message = "Остановка импорта в CodexAcc…"
        session?.cancelLoading()
        // Cancelling /start's task could discard an attempt that CodexAcc has already created.
        await worker?.value
        do {
            var wrongIdentity = false
            if let attempt {
                let status = try await dependencies.cancel(attempt.id)
                if case .pending = status { throw CodexAccImportError.invalidResponse }
                if case .complete(let email, _) = status, let account = queue.first {
                    if email.caseInsensitiveCompare(account.email) == .orderedSame {
                        try complete(email: email, account: account)
                    } else {
                        wrongIdentity = true
                    }
                }
            }
            clearAttempt()
            queue.removeAll()
            protectedAccountIDs.removeAll()
            isPaused = false
            message = wrongIdentity
                ? "CodexAcc подтвердил другой аккаунт. Импорт остановлен; результат не засчитан."
                : "Импорт в CodexAcc остановлен."
        } catch {
            isPaused = true
            restartOnResume = true
            message = "CodexAcc не подтвердил остановку. Повторите остановку или продолжите импорт."
        }
        stopping = false
        isRunning = false
    }

    private func run() async {
        isRunning = true
        isPaused = false
        message = "Импорт в CodexAcc…"
        let task = Task { await runQueue() }
        worker = task
        await task.value
        worker = nil
        if !stopping { isRunning = false }
    }

    private func runQueue() async {
        while let account = queue.first, !stopping {
            onSelect(account.id)
            do {
                if restartOnResume {
                    if let attempt {
                        let result = try await dependencies.cancel(attempt.id)
                        if case .pending = result { throw CodexAccImportError.invalidResponse }
                        if case .complete(let email, _) = result {
                            try complete(email: email, account: account)
                            continue
                        }
                    }
                    clearAttempt()
                    restartOnResume = false
                    guard !stopping else { return }
                }
                if attempt == nil {
                    switch try await dependencies.start(account) {
                    case .complete(let email, _):
                        try complete(email: email, account: account)
                        continue
                    case .pending(let started):
                        attempt = started
                        deadline = dependencies.now().addingTimeInterval(min(300, started.expiresInSeconds))
                    }
                    guard !stopping else { return }
                }
                guard let attempt else { throw CodexAccImportError.invalidResponse }
                guard CodexAccAuthorization.isAllowedAuthorizationURL(attempt.authorizationURL) else {
                    restartOnResume = true
                    throw CodexAccImportError.invalidResponse
                }
                // Poll first: duplicates and callbacks completed during a manual pause need no browser work.
                let status = try await dependencies.status(attempt.id)
                guard !stopping else { return }
                switch status {
                case .complete(let email, _):
                    try complete(email: email, account: account)
                    continue
                case .failed, .cancelled:
                    pause("CodexAcc не завершил авторизацию. Продолжите импорт, чтобы начать новую попытку.", restart: true)
                    return
                case .pending: break
                }
                guard let deadline, dependencies.now() < deadline else {
                    pause("Время авторизации CodexAcc истекло. Продолжите импорт, чтобы начать новую попытку.", restart: true)
                    return
                }
                if session == nil {
                    let prepared = try await dependencies.prepare(account, attempt.authorizationURL)
                    guard !stopping else { prepared.cancelLoading(); prepared.endOAuth(); return }
                    session = prepared
                    sessionAccountID = account.id
                }
                guard let session else { throw CodexAccImportError.invalidResponse }
                switch try await dependencies.advance(account, session) {
                case .waiting: break
                case .manual(let reason):
                    guard !stopping else { return }
                    pause(safeManualMessage(reason, account: account), restart: false)
                    return
                }
                guard !stopping else { return }
                try await dependencies.wait()
            } catch {
                guard !stopping else { return }
                // Do not surface browser or transport errors: their text can contain credentials or URLs.
                let reason = (error as? CodexAccImportError)?.errorDescription ?? "Не удалось продолжить авторизацию CodexAcc. Проверьте браузер и повторите импорт."
                pause(reason, restart: false)
                return
            }
        }
        if !stopping, queue.isEmpty {
            isPaused = false
            message = "Импорт в CodexAcc завершён: \(completedCount) из \(totalCount)."
        }
    }

    private func complete(email: String, account: AccountRecord) throws {
        guard email.caseInsensitiveCompare(account.email) == .orderedSame else {
            restartOnResume = true
            throw CodexAccImportError.wrongAccount
        }
        completedCount += 1
        queue.removeFirst()
        protectedAccountIDs.remove(account.id)
        clearAttempt()
        restartOnResume = false
    }

    private func pause(_ reason: String, restart: Bool) {
        isPaused = true
        restartOnResume = restartOnResume || restart
        message = reason
    }

    private func clearAttempt() {
        session?.cancelLoading()
        session?.endOAuth()
        session = nil
        sessionAccountID = nil
        attempt = nil
        deadline = nil
    }

    private func safeManualMessage(_ message: String, account: AccountRecord) -> String {
        var redacted = message
        for secret in [account.password, account.totpSecret, account.pendingPassword, account.pendingTOTPSecret].compactMap({ $0 }) where !secret.isEmpty {
            redacted = redacted.replacingOccurrences(of: secret, with: "[скрыто]")
        }
        if redacted.contains("://") { return "Продолжите авторизацию Codex в браузере." }
        return String(redacted.prefix(240))
    }
}
