import Foundation
import Observation
import OSLog
import WebKit

@MainActor
protocol EmailCodeReceiving: AnyObject {
    func captureBaseline() async throws -> Set<String>
    func waitForCode(alias: String, since: Date, excluding: Set<String>) async throws -> MailVerificationCode
    func waitForCode(alias: String, since: Date, excluding: Set<String>, purpose: MailVerificationPurpose) async throws -> MailVerificationCode
    func cancel()
}

extension EmailCodeReceiving {
    func waitForCode(alias: String, since: Date, excluding: Set<String>, purpose: MailVerificationPurpose) async throws -> MailVerificationCode {
        guard purpose == .emailChange else { throw MailVerificationError.unsupportedLayout }
        return try await waitForCode(alias: alias, since: since, excluding: excluding)
    }
}

extension EmailChanging {
    func returnToConfirmation(for account: AccountRecord) {}
    func resetVerificationSession(for account: AccountRecord) -> Bool { false }
    func originalIdentityForAliasReplacement(account: AccountRecord) async throws -> EmailChangeProof {
        throw EmailAutomationError.aliasReplacementUnavailable
    }
    func resetAfterAliasReplacement(for account: AccountRecord) { prepareSession(for: account) }
}

extension MailRuMailbox: EmailCodeReceiving {}

enum EmailChangeOutcome {
    case success(EmailChangeProof)
    case manual(String)
    case failure(String)
}

@MainActor
protocol EmailChanging: AnyObject {
    func prepareSession(for account: AccountRecord)
    func browserSession(for account: AccountRecord) -> BrowserSession?
    func changeEmail(account: AccountRecord, onCheckpoint: @escaping @MainActor (PendingEmailChange) throws -> Void) async -> EmailChangeOutcome
    func cancel()
    func returnToConfirmation(for account: AccountRecord)
    func resetVerificationSession(for account: AccountRecord) -> Bool
    func originalIdentityForAliasReplacement(account: AccountRecord) async throws -> EmailChangeProof
    func resetAfterAliasReplacement(for account: AccountRecord)
}

@MainActor
@Observable
final class EmailChangeAutomation: EmailChanging {
    private static let logger = Logger(subsystem: "local.wemakecode.gptaccountmanager", category: "email-change-flow")
    private enum ObservationStage: String {
        case preparing, openingForm, identityBeforeBaseline, mailBaseline, identityAfterBaseline, requestCheckpoint, emailSubmit
    }
    private var observedStage: ObservationStage?
    private var observedPageKind: EmailChangeForm.Kind?

    private func observe(_ stage: ObservationStage, in session: BrowserSession) {
        if observedStage != stage {
            Self.logger.notice("Stage: \(stage.rawValue, privacy: .public)")
            observedStage = stage
        }
        switch stage {
        case .identityBeforeBaseline: session.setOperationMessage("Смена email: проверяется исходный аккаунт перед чтением почты…")
        case .mailBaseline: session.setOperationMessage("Смена email: фиксируется исходное состояние почты…")
        case .identityAfterBaseline: session.setOperationMessage("Смена email: повторно проверяется исходный аккаунт…")
        default: break
        }
    }

    private func observe(_ kind: EmailChangeForm.Kind) {
        if observedPageKind != kind {
            Self.logger.notice("Page kind: \(kind.rawValue, privacy: .public)")
            observedPageKind = kind
        }
    }
    private let browser: ChatGPTAutomation
    private let mailbox: EmailCodeReceiving
    private let waitNoticeInterval: Duration
    private var sessions: [UUID: BrowserSession] = [:]
    private var verificationSessions: [UUID: BrowserSession] = [:]
    private var operationIDs: [UUID: UUID] = [:]
    private var showingConfirmation: Set<UUID> = []
    private var cancellationGeneration = 0
    private struct AuthenticationMailRequest {
        let email: String
        let baseline: Set<String>
        let requestedAt: Date
        var challengeURL: URL?
        var receivedCode: MailVerificationCode?
        var submittedURL: URL?
    }
    private var authenticationMailRequests: [ObjectIdentifier: AuthenticationMailRequest] = [:]

    init(browser: ChatGPTAutomation, mailbox: EmailCodeReceiving, waitNoticeInterval: Duration = .seconds(60)) {
        self.browser = browser
        self.mailbox = mailbox
        self.waitNoticeInterval = max(.milliseconds(1), waitNoticeInterval)
    }

    func prepareSession(for account: AccountRecord) {
        if operationIDs[account.id] != account.pendingEmailChange?.operationID {
            for session in [sessions[account.id], verificationSessions[account.id]].compactMap({ $0 }) {
                authenticationMailRequests.removeValue(forKey: ObjectIdentifier(session))
            }
            verificationSessions.removeValue(forKey: account.id)?.cancelLoading()
            sessions.removeValue(forKey: account.id)
            showingConfirmation.remove(account.id)
            operationIDs[account.id] = account.pendingEmailChange?.operationID
        }
        if sessions[account.id] == nil { sessions[account.id] = browser.accountSession(for: account) }
        sessions[account.id]?.endOAuth()
        sessions[account.id]?.setVisible(true)
    }

    func browserSession(for account: AccountRecord) -> BrowserSession? {
        if showingConfirmation.contains(account.id) { return sessions[account.id] }
        return verificationSessions[account.id] ?? sessions[account.id]
    }

    func returnToConfirmation(for account: AccountRecord) {
        showingConfirmation.insert(account.id)
        verificationSessions[account.id]?.setVisible(false)
        sessions[account.id]?.setVisible(true)
        if sessions[account.id]?.webView.url == nil {
            _ = sessions[account.id]?.load(URL(string: "https://chatgpt.com/settings/account")!)
        }
    }

    func resetVerificationSession(for account: AccountRecord) -> Bool {
        guard account.pendingEmailChange?.phase == .confirming else { return false }
        prepareSession(for: account)
        if let session = verificationSessions[account.id] {
            authenticationMailRequests.removeValue(forKey: ObjectIdentifier(session))
        }
        verificationSessions[account.id]?.cancelLoading()
        verificationSessions[account.id]?.setVisible(false)
        let replacement = BrowserSession(dataStore: .nonPersistent(), proxy: browser.accountSession(for: account).configuredProxy)
        replacement.setVisible(true)
        replacement.setOperationMessage("Новый проверочный вход с новым email…")
        verificationSessions[account.id] = replacement
        showingConfirmation.remove(account.id)
        return true
    }

    func cancel() {
        cancellationGeneration += 1
        mailbox.cancel()
        for session in Array(sessions.values) + Array(verificationSessions.values) { session.cancelLoading() }
    }

    func originalIdentityForAliasReplacement(account: AccountRecord) async throws -> EmailChangeProof {
        guard let change = account.pendingEmailChange, let originalUserID = change.originalUserID,
              !originalUserID.isEmpty,
              account.email.caseInsensitiveCompare(change.originalEmail) == .orderedSame else {
            throw EmailAutomationError.aliasReplacementUnavailable
        }
        let generation = cancellationGeneration
        prepareSession(for: account)
        showingConfirmation.insert(account.id)
        verificationSessions[account.id]?.setVisible(false)
        guard let session = sessions[account.id] else { throw EmailAutomationError.aliasReplacementUnavailable }
        session.setVisible(true)
        session.setOperationMessage("Замена алиаса: проверяется исходный аккаунт и прежний email…")
        do {
            guard generation == cancellationGeneration, !Task.isCancelled else { throw CancellationError() }
            if session.webView.url == nil {
                _ = await session.loadInitialPage(URL(string: "https://chatgpt.com/")!, seconds: 25)
                guard generation == cancellationGeneration, !Task.isCancelled else { throw CancellationError() }
            }
            let proof = try await authenticatedIdentity(account: account, in: session, generation: generation)
            guard generation == cancellationGeneration, !Task.isCancelled else { throw CancellationError() }
            guard proof.email.caseInsensitiveCompare(change.originalEmail) == .orderedSame,
                  proof.userID == originalUserID else { throw EmailAutomationError.aliasReplacementUnavailable }
            return proof
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw EmailAutomationError.aliasReplacementUnavailable
        }
    }

    func resetAfterAliasReplacement(for account: AccountRecord) {
        verificationSessions[account.id]?.setVisible(false)
        prepareSession(for: account)
        guard let session = sessions[account.id] else { return }
        session.cancelLoading()
        session.setOperationMessage("Алиас заменён. Открываются настройки аккаунта…")
        _ = session.load(URL(string: "https://chatgpt.com/#settings/Account")!)
    }

    func changeEmail(account: AccountRecord, onCheckpoint: @escaping @MainActor (PendingEmailChange) throws -> Void) async -> EmailChangeOutcome {
        guard var change = account.pendingEmailChange else { return .failure("Не выбран новый email.") }
        let generation = cancellationGeneration
        observedStage = nil
        observedPageKind = nil
        func checkCancellation() throws {
            guard generation == cancellationGeneration, !Task.isCancelled else { throw CancellationError() }
        }
        prepareSession(for: account)
        guard let session = sessions[account.id] else { return .failure("Браузер недоступен.") }
        do {
            try checkCancellation()
            if change.phase == .confirming {
                return await verify(account: account, change: change, generation: generation)
            }
            var reopenRequest = false
            if change.phase == .requested {
                if session.webView.url == nil {
                    session.setOperationMessage("Восстановление смены email: открывается сохранённая сессия…")
                    _ = await session.loadInitialPage(URL(string: "https://chatgpt.com/settings/account")!, seconds: 25)
                    try checkCancellation()
                    reopenRequest = true
                }
                if let identity = try? await Self.identity(in: session) {
                    guard identity.userID == change.originalUserID else {
                        return .failure("Открыта другая учётная запись. Повторный запрос смены email не отправлен.")
                    }
                    if identity.email.caseInsensitiveCompare(change.newEmail) == .orderedSame {
                        change.phase = .confirming
                        try onCheckpoint(change)
                        return await verify(account: account, change: change, generation: generation)
                    }
                    guard identity.email.caseInsensitiveCompare(change.originalEmail) == .orderedSame else {
                        return .failure("Текущий email не совпадает с сохранённой операцией.")
                    }
                    _ = try await dismissEmailNotice(in: session, generation: generation)
                    let kind = try await readPage(in: session, generation: generation) {
                        try await EmailChangeForm.inspect(in: session).kind
                    }
                    // A resumed operation may have lost its code dialog. Reopen only
                    // after the server proves the original account is still unchanged.
                    reopenRequest = reopenRequest || kind == .accountSettings || kind == .emailEntry
                    if kind == .emailCode { reopenRequest = false }
                }
            }
            if change.phase == .reserved || reopenRequest {
                observe(.preparing, in: session)
                session.setOperationMessage("Смена email: проверка Mail.ru и входа в аккаунт…")
                if session.webView.url != nil { _ = try await dismissEmailNotice(in: session, generation: generation) }
                let currentKind: EmailChangeForm.Kind? = session.webView.url == nil ? nil : try await readPage(in: session, generation: generation) {
                    try await EmailChangeForm.inspect(in: session).kind
                }
                // Preserve the original baseline when resuming an already requested login code.
                if currentKind != .emailChallenge {
                    try await prepareAuthenticationMail(account: account, in: session, generation: generation)
                }
                let continuingReauthentication = change.originalUserID != nil &&
                    (currentKind == .password || currentKind == .totp || currentKind == .emailChallenge)
                if !continuingReauthentication {
                    let identity = try await authenticatedIdentity(account: account, in: session, generation: generation)
                    guard identity.email.caseInsensitiveCompare(change.originalEmail) == .orderedSame,
                          change.originalUserID == nil || change.originalUserID == identity.userID else {
                        return .failure("Открытая сессия принадлежит другому аккаунту.")
                    }
                    change.originalUserID = identity.userID
                    try onCheckpoint(change)
                    let page = try await readPage(in: session, generation: generation) {
                        try await EmailChangeForm.inspect(in: session).kind
                    }
                    if page != .accountSettings && page != .emailEntry {
                        let nav = session.load(URL(string: "https://chatgpt.com/settings/account")!)
                        _ = await session.waitForNavigation(nav, seconds: 25)
                    }
                }
                var nextWaitNotice = ContinuousClock.now.advanced(by: waitNoticeInterval)
                var submittedChallenges: Set<String> = []
                var editorOpening = false
                var authenticationObserved = continuingReauthentication
                var reopenedAfterAuthentication = false
                observe(.openingForm, in: session)
                while true {
                    try checkCancellation()
                    reportContinuedWait(in: session, nextNotice: &nextWaitNotice)
                    _ = try await dismissEmailNotice(in: session, generation: generation)
                    let state = try await readPage(in: session, generation: generation) {
                        try await self.checkForManualAction(in: session)
                        return try await EmailChangeForm.inspect(in: session)
                    }
                    observe(state.kind)
                    if state.kind == .emailEntry {
                        session.setOperationMessage("Смена email: форма нового адреса открыта…")
                        break
                    }
                    if session.webView.url?.host?.lowercased() == "auth.openai.com" {
                        authenticationObserved = true
                        editorOpening = false
                    }
                    _ = try await reauthenticateIfNeeded(state.kind, account: account, in: session,
                                                          generation: generation, submitted: &submittedChallenges)
                    if state.kind == .accountSettings, !editorOpening {
                        if authenticationObserved {
                            authenticationMailRequests.removeValue(forKey: ObjectIdentifier(session))
                            authenticationObserved = false
                        }
                        try await prepareAuthenticationMail(account: account, in: session, generation: generation)
                        editorOpening = try await submitOnce(in: session, generation: generation) {
                            try await EmailChangeForm.open(in: session, currentEmail: change.originalEmail)
                        }
                        if editorOpening { session.setOperationMessage("Смена email: ожидается открытие формы или подтверждение личности…") }
                    } else if state.kind == .unknown, authenticationObserved, !session.webView.isLoading,
                              let url = session.webView.url,
                              TrustedChatGPTOrigin.allowsMetadata(url),
                              url.path.isEmpty || url.path == "/",
                              url.fragment?.isEmpty != false,
                              let identity = try? await Self.identity(in: session) {
                        try checkCancellation()
                        guard session.webView.url == url, !session.webView.isLoading else { continue }
                        guard identity.email.caseInsensitiveCompare(change.originalEmail) == .orderedSame,
                              identity.userID == change.originalUserID else {
                            return .failure("После подтверждения личности открыт другой аккаунт. Запрос смены email не отправлен.")
                        }
                        guard !reopenedAfterAuthentication else {
                            return .manual("OpenAI снова вернул главную страницу после входа. Откройте настройки аккаунта и продолжите смену email.")
                        }
                        // Reauthentication can leave callbackUrl as a query on the homepage.
                        // Reopen our fixed settings route only after proving the same identity.
                        reopenedAfterAuthentication = true
                        editorOpening = false
                        authenticationMailRequests.removeValue(forKey: ObjectIdentifier(session))
                        session.setOperationMessage("Смена email: личность подтверждена, открываются настройки аккаунта…")
                        let nav = session.load(URL(string: "https://chatgpt.com/#settings/Account")!)
                        _ = await session.waitForNavigation(nav, seconds: 15)
                    }
                    try await Task.sleep(for: .milliseconds(350))
                }
                observe(.identityBeforeBaseline, in: session)
                let identity = try await readIdentity(in: session, generation: generation)
                guard identity.email.caseInsensitiveCompare(change.originalEmail) == .orderedSame,
                      identity.userID == change.originalUserID else {
                    return .failure("После подтверждения личности открыт другой аккаунт. Запрос смены email не отправлен.")
                }
                observe(.mailBaseline, in: session)
                change.baselineMessageIDs = try await captureMailBaseline(in: session, generation: generation)
                try checkCancellation()
                observe(.identityAfterBaseline, in: session)
                let currentIdentity = try await readIdentity(in: session, generation: generation)
                try checkCancellation()
                guard currentIdentity.email.caseInsensitiveCompare(change.originalEmail) == .orderedSame,
                      currentIdentity.userID == change.originalUserID else {
                    return .failure("Во время чтения почты изменился аккаунт. Запрос смены email не отправлен.")
                }
                // Email Date headers have second precision; baseline excludes pre-request messages.
                let requestedAt = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
                change.requestedAt = requestedAt
                authenticationMailRequests[ObjectIdentifier(session)] = AuthenticationMailRequest(
                    email: account.email, baseline: change.baselineMessageIDs, requestedAt: requestedAt)
                change.phase = .requested
                change.requestAttemptID = UUID()
                observe(.requestCheckpoint, in: session)
                try onCheckpoint(change)
                observe(.emailSubmit, in: session)
                _ = try await dismissEmailNotice(in: session, generation: generation)
                var emailSubmitted = try await submitOnce(in: session, generation: generation) {
                    try await EmailChangeForm.submitEmail(change.newEmail, in: session)
                }
                // A false result proves no click was sent. A known notice can
                // arrive during the mailbox read and hide the unchanged editor.
                if !emailSubmitted, try await dismissEmailNotice(in: session, generation: generation) {
                    emailSubmitted = try await submitOnce(in: session, generation: generation) {
                        try await EmailChangeForm.submitEmail(change.newEmail, in: session)
                    }
                }
                guard emailSubmitted else {
                    return .manual("Форма email изменилась. Резерв сохранён; проверьте открытую форму и продолжите.")
                }
                try await Task.sleep(for: .seconds(1))
            }

            var nextWaitNotice = ContinuousClock.now.advanced(by: waitNoticeInterval)
            var submittedChallenges: Set<String> = []
            session.setOperationMessage("Смена email: ожидается подтверждение OpenAI…")
            while true {
                try checkCancellation()
                reportContinuedWait(in: session, nextNotice: &nextWaitNotice)
                _ = try await dismissEmailNotice(in: session, generation: generation)
                let state = try await readPage(in: session, generation: generation) {
                    try await self.checkForManualAction(in: session)
                    return try await EmailChangeForm.inspect(in: session)
                }
                _ = try await reauthenticateIfNeeded(state.kind, account: account, in: session,
                                                      generation: generation, submitted: &submittedChallenges)
                switch state.kind {
                case .emailCode:
                    guard let requestedAt = change.requestedAt else { return .failure("Не сохранено время запроса кода.") }
                    session.setOperationMessage("Смена email: ожидается свежее письмо на \(change.newEmail)…")
                    let mail: MailVerificationCode
                    do {
                        mail = try await mailbox.waitForCode(alias: change.newEmail, since: requestedAt, excluding: change.baselineMessageIDs)
                    } catch MailVerificationError.timedOut {
                        try checkCancellation()
                        session.setOperationMessage("Письмо ещё не пришло. Поиск продолжается автоматически с прежним временем запроса…")
                        try await Task.sleep(for: .milliseconds(350))
                        continue
                    }
                    try checkCancellation()
                    // A code submission may change the login even if the response never arrives.
                    change.phase = .confirming
                    try onCheckpoint(change)
                    _ = try await dismissEmailNotice(in: session, generation: generation)
                    var codeSubmitted = try await submitOnce(in: session, generation: generation) {
                        try await EmailChangeForm.submitCode(mail.code, expectedEmail: change.newEmail, in: session)
                    }
                    if !codeSubmitted, try await dismissEmailNotice(in: session, generation: generation) {
                        codeSubmitted = try await submitOnce(in: session, generation: generation) {
                            try await EmailChangeForm.submitCode(mail.code, expectedEmail: change.newEmail, in: session)
                        }
                    }
                    guard codeSubmitted else {
                        return .manual("Код получен, но форма подтверждения изменилась. Оба адреса сохранены. Завершите подтверждение вручную, затем продолжите проверку.")
                    }
                    try await Task.sleep(for: .seconds(2))
                    try checkCancellation()
                    return await verify(account: account, change: change, generation: generation)
                case .password, .totp, .emailChallenge: break
                case .accountSettings:
                    if let identity = try? await Self.identity(in: session) {
                        guard identity.userID == change.originalUserID else {
                            return .failure("Открыта другая учётная запись. Смена email остановлена.")
                        }
                        if identity.email.caseInsensitiveCompare(change.newEmail) == .orderedSame {
                            change.phase = .confirming
                            try onCheckpoint(change)
                            return await verify(account: account, change: change, generation: generation)
                        }
                        guard identity.email.caseInsensitiveCompare(change.originalEmail) == .orderedSame else {
                            return .failure("Текущий email не совпадает с сохранённой операцией.")
                        }
                    }
                case .emailEntry:
                    // Sending the request can leave this form visible while OpenAI responds.
                    // The persisted request is never sent again by this polling loop.
                    break
                case .unknown: break
                }
                try await Task.sleep(for: .milliseconds(350))
            }
        } catch is CancellationError {
            return .manual("Смена email остановлена. Адрес и этап сохранены; продолжите эту же операцию.")
        } catch let error as LocalizedError {
            return .manual(error.errorDescription ?? "Не удалось продолжить смену email. Проверьте Mail.ru и открытую форму.")
        } catch {
            return .manual("Не удалось продолжить смену email. Проверьте Mail.ru и открытую форму; текущий email сохранён.")
        }
    }

    private func reportContinuedWait(in session: BrowserSession, nextNotice: inout ContinuousClock.Instant) {
        guard ContinuousClock.now >= nextNotice else { return }
        session.setOperationMessage("OpenAI отвечает дольше обычного. Ожидание продолжается автоматически; этап и сессия сохранены. Для остановки нажмите «Остановить».")
        nextNotice = ContinuousClock.now.advanced(by: waitNoticeInterval)
    }

    private func dismissEmailNotice(in session: BrowserSession, generation: Int) async throws -> Bool {
        let dismissed = try await submitOnce(in: session, generation: generation) {
            try await EmailChangeForm.dismissEmailBlockingNotice(in: session)
        }
        if dismissed {
            session.setOperationMessage("Смена email: закрыто напоминание о подписке, продолжается текущий этап…")
            try await Task.sleep(for: .milliseconds(350))
        }
        return dismissed
    }

    private func checkForManualAction(in session: BrowserSession) async throws {
        if try await browser.hasSecurityChallenge(in: session) { throw EmailAutomationError.manualLogin }
        if let rejection = try await Self.authenticationRejection(in: session) {
            throw EmailAutomationError.rejected(rejection)
        }
    }

    private func captureMailBaseline(in session: BrowserSession, generation: Int) async throws -> Set<String> {
        while true {
            guard generation == cancellationGeneration, !Task.isCancelled else { throw CancellationError() }
            do {
                let baseline = try await mailbox.captureBaseline()
                guard generation == cancellationGeneration, !Task.isCancelled else { throw CancellationError() }
                return baseline
            } catch MailVerificationError.timedOut {
                guard generation == cancellationGeneration, !Task.isCancelled else { throw CancellationError() }
                session.setOperationMessage("Mail.ru загружается дольше обычного. Проверка почты продолжается автоматически…")
                try await Task.sleep(for: .milliseconds(350))
            }
        }
    }

    private func readIdentity(in session: BrowserSession, generation: Int) async throws -> EmailChangeProof {
        try await readPage(in: session, generation: generation) {
            try await Self.identity(in: session)
        }
    }

    private func interruptedEvaluation(_ error: Error, in session: BrowserSession, previousURL: URL?) -> Bool {
        if error as? BrowserSessionError == .evaluationTimedOut { return true }
        let details = error as NSError
        guard details.domain == WKError.errorDomain else { return false }
        return details.code == WKError.Code.javaScriptInvalidFrameTarget.rawValue ||
            ([WKError.Code.javaScriptExceptionOccurred.rawValue,
              WKError.Code.javaScriptResultTypeIsUnsupported.rawValue].contains(details.code) &&
             (session.webView.url != previousURL || session.webView.isLoading))
    }

    private func transientObservationFailure(_ error: Error) -> Bool {
        switch error {
        case ChatGPTAutomation.SavedSessionError.unavailable, EmailAutomationError.identityTemporarilyUnavailable:
            return true
        default: break
        }
        let details = error as NSError
        guard details.domain == WKError.errorDomain,
              details.code == WKError.Code.javaScriptExceptionOccurred.rawValue else { return false }
        let message = details.userInfo.values.compactMap { $0 as? String }.joined(separator: " ").lowercased()
        return ["load failed", "failed to fetch", "networkerror", "network request failed"].contains(where: message.contains)
    }

    // A navigation can destroy the JS frame after a click. Observe its result,
    // never repeat a mutation merely because WebKit lost its acknowledgement.
    private func submitOnce(in session: BrowserSession, generation: Int,
                            _ submit: () async throws -> Bool) async throws -> Bool {
        guard generation == cancellationGeneration, !Task.isCancelled else { throw CancellationError() }
        let pageURL = session.webView.url
        do { return try await submit() }
        catch {
            guard generation == cancellationGeneration, !Task.isCancelled else { throw CancellationError() }
            guard TrustedChatGPTOrigin.allowsAuthentication(session.webView.url),
                  error as? BrowserSessionError != .evaluationTimedOut || session.webView.url != pageURL,
                  interruptedEvaluation(error, in: session, previousURL: pageURL) else { throw error }
            session.setOperationMessage("Ответ формы задерживается. Ожидается следующий этап без повторной отправки…")
            return true
        }
    }

    // Retry only observations. A timed-out click/submission may already have
    // reached OpenAI and must never be replayed by this wait helper.
    private func readPage<Value>(in session: BrowserSession, generation: Int,
                                 _ read: () async throws -> Value) async throws -> Value {
        var nextWaitNotice = ContinuousClock.now.advanced(by: waitNoticeInterval)
        var unsupportedResultRetries = 0
        var failures = 0
        while true {
            guard generation == cancellationGeneration, !Task.isCancelled else { throw CancellationError() }
            let pageURL = session.webView.url
            do {
                let value = try await read()
                guard generation == cancellationGeneration, !Task.isCancelled else { throw CancellationError() }
                return value
            } catch {
                guard generation == cancellationGeneration, !Task.isCancelled else { throw CancellationError() }
                let details = error as NSError
                let unsupportedResult = details.domain == WKError.errorDomain &&
                    details.code == WKError.Code.javaScriptResultTypeIsUnsupported.rawValue
                // Retrying an observation cannot resend a form. WebKit can lose
                // a primitive result while the authentication document changes.
                // Persistent unsupported results still stop after three reads.
                if unsupportedResult {
                    guard unsupportedResultRetries < 2 else { throw error }
                    unsupportedResultRetries += 1
                }
                guard TrustedChatGPTOrigin.allowsAuthentication(session.webView.url),
                      unsupportedResult || transientObservationFailure(error) ||
                        interruptedEvaluation(error, in: session, previousURL: pageURL) else { throw error }
                failures += 1
                if failures == 1 || failures == 3 || failures == 10 {
                    let category = details.domain == WKError.errorDomain ? "webkit" :
                        (error as? BrowserSessionError != nil ? "browser" : "identity")
                    Self.logger.notice("Observation retry: \(category, privacy: .public), code: \(details.code), attempt: \(failures)")
                }
                reportContinuedWait(in: session, nextNotice: &nextWaitNotice)
                try await Task.sleep(for: .milliseconds(350))
            }
        }
    }

    private func reauthenticateIfNeeded(
        _ kind: EmailChangeForm.Kind, account: AccountRecord, in session: BrowserSession,
        generation: Int, submitted: inout Set<String>
    ) async throws -> Bool {
        guard generation == cancellationGeneration, !Task.isCancelled else { throw CancellationError() }
        let challengeURL = session.webView.url
        if kind == .emailChallenge {
            let preferPassword = !account.password.isEmpty && !submitted.contains { $0.hasPrefix("password:") }
            if preferPassword {
                if submitted.contains("passwordChoice") { return false }
                if try await submitOnce(in: session, generation: generation, {
                    try await RegistrationForm.selectPasswordLogin(in: session)
                }) {
                    submitted.insert("passwordChoice")
                    authenticationMailRequests.removeValue(forKey: ObjectIdentifier(session))
                    session.setOperationMessage("Смена email: ожидается форма входа с паролем…")
                    return true
                }
                guard session.webView.url == challengeURL else { return false }
            }
            return try await submitAuthenticationMailCode(account: account, in: session, generation: generation,
                                                          preferPassword: preferPassword)
        }
        guard kind == .password || kind == .totp else { return false }
        let challenge = "\(kind.rawValue):\(challengeURL?.absoluteString ?? "")"
        guard !submitted.contains(challenge) else { return false }
        if kind == .password {
            guard challengeURL?.host?.lowercased() == "auth.openai.com",
                  challengeURL?.path.lowercased() == "/log-in/password" else { return false }
            guard !account.password.isEmpty else { throw EmailAutomationError.manualLogin }
            let key = ObjectIdentifier(session)
            if authenticationMailRequests[key]?.challengeURL != nil {
                authenticationMailRequests.removeValue(forKey: key)
            }
        }
        try await prepareAuthenticationMail(account: account, in: session, generation: generation)
        guard session.webView.url == challengeURL else { return false }
        if kind == .password {
            session.setOperationMessage("Смена email: подтверждается текущий пароль…")
            if try await submitOnce(in: session, generation: generation, {
                try await browser.fillAndSubmit(selectors: ["input[type='password']"], value: account.password,
                                                context: .authentication, in: session,
                                                expectedPageURL: challengeURL, expectedEmail: account.email) == .submitted
            }) {
                submitted.insert(challenge)
            }
            return false
        }
        session.setOperationMessage("Смена email: подтверждается действующий код 2FA…")
        let delay = TOTPService.safeSubmissionDelay(minimumRemaining: 10)
        if delay > 0 { try await Task.sleep(for: .seconds(delay + 0.15)) }
        guard generation == cancellationGeneration, !Task.isCancelled else { throw CancellationError() }
        guard session.webView.url == challengeURL else { return false }
        let code = try TOTPService.code(secret: account.totpSecret)
        let sent = try await submitOnce(in: session, generation: generation) {
            let result = try await EmailChangeForm.submitAuthenticatorCode(code, expectedPageURL: challengeURL, in: session)
            if ChatGPTAutomation.needsKeyboardMFAFallback(url: session.webView.url, formResult: result) {
                return await session.submitMFAUsingKeyboard(code)
            }
            return result == .submitted
        }
        if sent { submitted.insert(challenge) }
        return false
    }

    private func authenticatedIdentity(account: AccountRecord, in session: BrowserSession, generation: Int) async throws -> EmailChangeProof {
        if TrustedChatGPTOrigin.allowsMetadata(session.webView.url),
           try await readPage(in: session, generation: generation, {
               guard TrustedChatGPTOrigin.allowsMetadata(session.webView.url) else { return false }
               return try await browser.hasAuthenticatedSession(for: account, in: session)
           }) {
            return try await readIdentity(in: session, generation: generation)
        }
        if session.webView.url == nil {
            try await prepareAuthenticationMail(account: account, in: session, generation: generation)
            _ = await session.loadInitialPage(URL(string: "https://chatgpt.com/")!, seconds: 25)
        }
        try await login(account: account, in: session, generation: generation)
        return try await readIdentity(in: session, generation: generation)
    }

    private func prepareAuthenticationMail(account: AccountRecord, in session: BrowserSession, generation: Int) async throws {
        let key = ObjectIdentifier(session)
        if authenticationMailRequests[key]?.email.caseInsensitiveCompare(account.email) == .orderedSame { return }
        let path = session.webView.url?.path.lowercased() ?? ""
        guard !path.contains("email-verification"), !path.contains("verify-email") else {
            throw EmailAutomationError.emailChallenge
        }
        let pageURL = session.webView.url
        let baseline = try await captureMailBaseline(in: session, generation: generation)
        guard generation == cancellationGeneration, !Task.isCancelled else { throw CancellationError() }
        guard session.webView.url == pageURL else { throw EmailAutomationError.emailChallenge }
        authenticationMailRequests[key] = AuthenticationMailRequest(
            email: account.email, baseline: baseline,
            requestedAt: Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970)))
    }

    private func submitAuthenticationMailCode(account: AccountRecord, in session: BrowserSession, generation: Int,
                                              preferPassword: Bool) async throws -> Bool {
        guard generation == cancellationGeneration, !Task.isCancelled else { throw CancellationError() }
        let state = try await readPage(in: session, generation: generation) {
            try await RegistrationForm.inspect(in: session)
        }
        guard let challengeURL = state.pageURL, challengeURL == session.webView.url else { return false }
        if state.kind == .unknown { return false }
        guard state.kind == .emailCode,
              state.displayedEmail?.caseInsensitiveCompare(account.email) == .orderedSame else {
            throw EmailAutomationError.emailChallenge
        }
        let key = ObjectIdentifier(session)
        guard var request = authenticationMailRequests[key],
              request.email.caseInsensitiveCompare(account.email) == .orderedSame else {
            // A restarted app cannot prove when this authentication code was requested.
            throw EmailAutomationError.emailChallenge
        }
        guard request.submittedURL != challengeURL else { return false }
        guard request.challengeURL == nil || request.challengeURL == challengeURL else {
            throw EmailAutomationError.emailChallenge
        }
        let token = UUID().uuidString
        let email = account.email
        let browserGeneration = session.cancellationGeneration
        guard try await RegistrationForm.emailCodeScreenMatches(
            in: session, expectedEmail: email, pageURL: challengeURL, token: token, capture: true
        ) else { return false }
        let isCurrentScreen: @MainActor @Sendable () async throws -> Bool = {
            guard generation == self.cancellationGeneration, !Task.isCancelled else { throw CancellationError() }
            guard session.cancellationGeneration == browserGeneration, session.webView.url == challengeURL else { return false }
            do {
                if preferPassword, try await RegistrationForm.selectPasswordLogin(in: session, click: false) { return false }
                return try await RegistrationForm.emailCodeScreenMatches(
                    in: session, expectedEmail: email, pageURL: challengeURL, token: token)
            } catch {
                guard generation == self.cancellationGeneration, !Task.isCancelled else { throw CancellationError() }
                return false
            }
        }
        guard try await isCurrentScreen() else { return false }
        session.setOperationMessage("Смена email: ожидается код входа на \(account.email)…")
        if request.receivedCode == nil {
            request.challengeURL = challengeURL
            authenticationMailRequests[key] = request
            let requestedAt = request.requestedAt
            let baseline = request.baseline
            do {
                request.receivedCode = try await withThrowingTaskGroup(of: MailVerificationCode?.self) { group in
                    defer { group.cancelAll(); mailbox.cancel() }
                    group.addTask { @MainActor @Sendable in
                        try await self.mailbox.waitForCode(alias: email, since: requestedAt,
                                                           excluding: baseline, purpose: .login)
                    }
                    group.addTask { @MainActor @Sendable in
                        while try await isCurrentScreen() { try await Task.sleep(for: .milliseconds(350)) }
                        return nil
                    }
                    return try await group.next() ?? nil
                }
            } catch MailVerificationError.timedOut {
                guard generation == cancellationGeneration, !Task.isCancelled else { throw CancellationError() }
                guard try await isCurrentScreen() else { return false }
                session.setOperationMessage("Код входа ещё не пришёл. Поиск продолжается автоматически с прежним временем запроса…")
                return false
            } catch {
                guard try await isCurrentScreen() else { return false }
                throw error
            }
        }
        guard let code = request.receivedCode, try await isCurrentScreen() else { return false }
        authenticationMailRequests[key] = request
        let readinessDeadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < readinessDeadline {
            guard generation == cancellationGeneration, !Task.isCancelled else { throw CancellationError() }
            guard try await isCurrentScreen() else { return false }
            let latest = try await readPage(in: session, generation: generation) {
                try await RegistrationForm.inspect(in: session)
            }
            guard latest.pageURL == challengeURL, session.webView.url == challengeURL else { return false }
            if latest.kind != .unknown {
                guard latest.kind == .emailCode,
                      latest.displayedEmail?.caseInsensitiveCompare(account.email) == .orderedSame else {
                    throw EmailAutomationError.emailChallenge
                }
                if try await submitOnce(in: session, generation: generation, {
                       try await RegistrationForm.submitEmailCode(code.code, expectedEmail: email, observedScreenOnly: true, in: session)
                   }) {
                    request.submittedURL = challengeURL
                    authenticationMailRequests[key] = request
                    return true
                }
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        return false
    }

    private func login(account: AccountRecord, in session: BrowserSession, generation: Int) async throws {
        var nextWaitNotice = ContinuousClock.now.advanced(by: waitNoticeInterval)
        var emailSent = false
        var loginOpened = false
        var accountChosen = false
        var submittedChallenges: Set<String> = []
        while true {
            guard generation == cancellationGeneration, !Task.isCancelled else { throw CancellationError() }
            reportContinuedWait(in: session, nextNotice: &nextWaitNotice)
            let authenticated = try await readPage(in: session, generation: generation) {
                try await self.checkForManualAction(in: session)
                guard TrustedChatGPTOrigin.allowsMetadata(session.webView.url) else { return false }
                return try await self.browser.hasAuthenticatedSession(for: account, in: session)
            }
            if authenticated {
                authenticationMailRequests.removeValue(forKey: ObjectIdentifier(session))
                return
            }
            guard TrustedChatGPTOrigin.allowsAuthentication(session.webView.url) else { throw EmailAutomationError.manualLogin }
            let kind = try await readPage(in: session, generation: generation) {
                try await EmailChangeForm.inspect(in: session).kind
            }
            if kind == .password || kind == .totp || kind == .emailChallenge {
                if kind == .emailChallenge || !submittedChallenges.contains(where: { $0.hasPrefix("\(kind.rawValue):") }) {
                    _ = try await reauthenticateIfNeeded(kind, account: account, in: session,
                                                         generation: generation, submitted: &submittedChallenges)
                }
                try await Task.sleep(for: .milliseconds(350))
                continue
            }
            try await prepareAuthenticationMail(account: account, in: session, generation: generation)
            let path = session.webView.url?.path.lowercased() ?? ""
            if path == "/choose-an-account", session.webView.url?.host == "auth.openai.com", !accountChosen {
                accountChosen = try await submitOnce(in: session, generation: generation) {
                    try await browser.clickUniqueControl(labels: [account.email], click: true, in: session) == .clicked
                }
            } else if ["/log-in", "/log-in-or-create-account"].contains(path), !emailSent {
                emailSent = try await submitOnce(in: session, generation: generation) {
                    try await Self.submitLoginEmail(account.email, in: session)
                }
            } else if session.webView.url?.host == "chatgpt.com" {
                if !emailSent {
                    emailSent = try await submitOnce(in: session, generation: generation) {
                        try await Self.submitLoginEmail(account.email, in: session)
                    }
                }
                if !emailSent, !loginOpened {
                    loginOpened = try await submitOnce(in: session, generation: generation) {
                        try await browser.clickUniqueControl(labels: ["Log in", "Войти"], click: true, in: session) == .clicked
                    }
                }
            }
            try await Task.sleep(for: .milliseconds(800))
        }
    }

    private func verify(account: AccountRecord, change: PendingEmailChange, generation: Int) async -> EmailChangeOutcome {
        showingConfirmation.remove(account.id)
        let session = verificationSessions[account.id] ?? BrowserSession(dataStore: .nonPersistent(), proxy: browser.accountSession(for: account).configuredProxy)
        verificationSessions[account.id] = session
        session.setVisible(true)
        session.setOperationMessage("Смена email: проверочный вход с новым адресом…")
        var candidate = account
        candidate.email = change.newEmail
        do {
            guard generation == cancellationGeneration else { throw CancellationError() }
            if session.needsInitialPageLoad {
                try await prepareAuthenticationMail(account: candidate, in: session, generation: generation)
                _ = await session.waitUntilAttached(seconds: 3)
                guard await session.loadInitialPage(URL(string: "https://chatgpt.com/")!, seconds: 10, attempts: 3) else {
                    return .manual("\(session.pageLoadMessage ?? "Проверочная страница не загрузилась.") Нажмите «Новый вход», чтобы открыть чистую проверочную сессию.")
                }
            }
            try await login(account: candidate, in: session, generation: generation)
            let proof = try await readIdentity(in: session, generation: generation)
            guard generation == cancellationGeneration, !Task.isCancelled else { throw CancellationError() }
            guard proof.email.caseInsensitiveCompare(change.newEmail) == .orderedSame,
                  proof.userID == change.originalUserID else { return .failure("Новый email не подтверждён для исходного аккаунта. Запись не изменена.") }
            let previous = change.originalUserID.map { EmailChangeProof(email: change.originalEmail, userID: $0) }
            while true {
                guard generation == cancellationGeneration, !Task.isCancelled else { throw CancellationError() }
                do {
                    // Promotion revalidates both identities and rolls back cookies on
                    // failure. Retrying it cannot resubmit the email-change form.
                    try await browser.persistVerifiedSession(from: session, for: candidate, originalIdentity: previous)
                    break
                } catch {
                    guard generation == cancellationGeneration, !Task.isCancelled else { throw CancellationError() }
                    guard TrustedChatGPTOrigin.allowsMetadata(session.webView.url),
                          transientObservationFailure(error) || interruptedEvaluation(error, in: session, previousURL: session.webView.url)
                    else { throw error }
                    session.setOperationMessage("Новый email подтверждён. Сохранение проверенной сессии продолжается автоматически…")
                    try await Task.sleep(for: .seconds(1))
                }
            }
            guard generation == cancellationGeneration, !Task.isCancelled else { throw CancellationError() }
            sessions[account.id]?.setOperationMessage("Новый email проверен входом.")
            return .success(proof)
        } catch EmailAutomationError.rejected(let message) {
            return .manual(message)
        } catch let error as MailVerificationError {
            return .manual("\(error.localizedDescription) Исходный email и алиас сохранены; продолжите проверочный вход.")
        } catch EmailAutomationError.emailChallenge {
            return .manual(EmailAutomationError.emailChallenge.localizedDescription)
        } catch is CancellationError {
            return .manual("Проверочный вход остановлен. Адреса и этап сохранены.")
        } catch let error as LocalizedError {
            return .manual(error.errorDescription ?? "Не удалось завершить проверочный вход. Адреса и этап сохранены.")
        } catch {
            let details = error as NSError
            return .manual("Проверочный вход прерван (\(details.domain), \(details.code)). Адреса и этап сохранены.")
        }
    }

    static func identity(in session: BrowserSession) async throws -> EmailChangeProof {
        guard TrustedChatGPTOrigin.allowsMetadata(session.webView.url) else { throw BrowserSessionError.untrustedOrigin }
        let raw = try await session.evaluate("""
        (async () => {
          let value;
          try {
            const response = await fetch('/api/auth/session', {credentials:'include', cache:'no-store'});
            if (!response.ok) return {temporarilyUnavailable:true};
            value = await response.json();
          } catch { return {temporarilyUnavailable:true}; }
          const user = value?.user;
          if (typeof user?.email !== 'string' || typeof user?.id !== 'string') return null;
          return {email:user.email, userID:user.id};
        })()
        """)
        if (raw as? [String: Any])?["temporarilyUnavailable"] as? Bool == true {
            throw EmailAutomationError.identityTemporarilyUnavailable
        }
        guard let data = raw as? [String: Any], let email = data["email"] as? String,
              let userID = data["userID"] as? String, !email.isEmpty, !userID.isEmpty else { throw EmailAutomationError.identityUnavailable }
        return EmailChangeProof(email: email, userID: userID)
    }

    static func submitLoginEmail(_ email: String, in session: BrowserSession) async throws -> Bool {
        guard TrustedChatGPTOrigin.allowsAuthentication(session.webView.url) else { throw BrowserSessionError.untrustedOrigin }
        func allowedLoginRoute() -> Bool {
            (session.webView.url?.host == "auth.openai.com" && ["/log-in", "/log-in-or-create-account"].contains(session.webView.url?.path ?? "")) ||
                (session.webView.url?.host == "chatgpt.com" && (session.webView.url?.path.isEmpty == true || session.webView.url?.path == "/"))
        }
        guard allowedLoginRoute() else { return false }
        let encoded = String(decoding: try JSONEncoder().encode(email), as: UTF8.self)
        let generation = session.cancellationGeneration
        let findForm = """
          const authLogin = location.protocol === 'https:' && location.hostname === 'auth.openai.com' && ['/log-in', '/log-in-or-create-account'].includes(location.pathname);
          const guestLogin = location.protocol === 'https:' && location.hostname === 'chatgpt.com' && location.pathname === '/';
          if (!authLogin && !guestLogin) return 'invalid';
          const shown = e => {
            const rect = e.getBoundingClientRect();
            return rect.width > 0 && rect.height > 0 && getComputedStyle(e).visibility !== 'hidden' &&
              !e.closest('[hidden], [aria-hidden="true"], [inert]');
          };
          let scope = document;
          if (guestLogin) {
            const dialogs = [...document.querySelectorAll('[role="dialog"], dialog')].filter(shown).filter(e =>
              [...e.querySelectorAll('h1,h2,[role="heading"]')].some(h => shown(h) &&
                /^(Войти или зарегистрироваться|Log in or sign up|Log in|Войти)$/i.test(h.innerText.trim())));
            if (dialogs.length !== 1) return 'invalid';
            scope = dialogs[0];
          }
          const fields = [...scope.querySelectorAll('input[type="email"]')].filter(shown)
            .filter(e => !e.disabled && !e.readOnly);
          if (fields.length !== 1 || (!fields[0].form && !guestLogin)) return 'invalid';
          const form = fields[0].form || scope;
          const buttons = [...form.querySelectorAll('button, input[type="submit"]')].filter(shown)
            .filter(e => /^(Continue|Продолжить)$/i.test((e.innerText || e.value || '').trim()));
          if (buttons.length !== 1) return 'invalid';
        """
        try Task.checkCancellation()
        let filled = try await session.evaluate("""
        (() => {
          \(findForm)
          Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set.call(fields[0], \(encoded));
          fields[0].dispatchEvent(new Event('input', {bubbles:true}));
          fields[0].dispatchEvent(new Event('change', {bubbles:true}));
          return 'filled';
        })()
        """) as? String
        guard filled == "filled" else { return false }
        for _ in 0..<20 {
            try Task.checkCancellation()
            guard generation == session.cancellationGeneration else { throw CancellationError() }
            guard TrustedChatGPTOrigin.allowsAuthentication(session.webView.url) else { throw BrowserSessionError.untrustedOrigin }
            guard allowedLoginRoute() else { return false }
            let result = try await session.evaluate("""
            (() => {
              \(findForm)
              if (fields[0].value !== \(encoded) || !fields[0].checkValidity()) return 'invalid';
              if (buttons[0].disabled || buttons[0].getAttribute('aria-disabled') === 'true') return 'waiting';
              buttons[0].click(); return 'submitted';
            })()
            """) as? String
            if result != "waiting" { return result == "submitted" }
            try await Task.sleep(for: .milliseconds(50))
        }
        return false
    }

    private static func authenticationRejection(in session: BrowserSession) async throws -> String? {
        let url = session.webView.url
        let callbackErrors = url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?
            .queryItems?.filter { $0.name == "error" } ?? []
        let loginCallbackError = url?.scheme == "https" && url?.host?.lowercased() == "chatgpt.com" &&
            url?.path == "/auth/login" && callbackErrors.count == 1 && callbackErrors[0].value == "OAuthCallback"
        if ChatGPTAutomation.detectsAuthenticationCallbackError(url: url) || loginCallbackError {
            return "OpenAI не завершил подтверждение личности. Проверьте страницу ошибки в браузере и продолжите смену email."
        }
        guard session.webView.url?.host == "auth.openai.com" else { return nil }
        let path = session.webView.url?.path.lowercased() ?? ""
        let text = try await session.evaluate("document.body?.innerText || ''") as? String ?? ""
        if ChatGPTAutomation.detectsAuthenticationServerError(url: session.webView.url, text: text) {
            return "OpenAI вернул ошибку сервера. Проверьте страницу в браузере и продолжите смену email."
        }
        if ChatGPTAutomation.detectsDeactivatedAccount(url: session.webView.url, text: text) {
            return "OpenAI сообщает, что аккаунт удалён или деактивирован. Смена email остановлена; данные сохранены."
        }
        if path == "/log-in/password", PasswordChangeForm.rejectsPassword(text) {
            return "OpenAI отклонил пароль. Проверьте сохранённый пароль и продолжите вход вручную."
        }
        if ChatGPTAutomation.detectsRejectedAuthenticatorCode(url: session.webView.url, text: text) {
            return "OpenAI отклонил код 2FA. Проверьте действующий код в браузере и продолжите смену email."
        }
        return nil
    }
}

private enum EmailAutomationError: LocalizedError {
    case manualLogin, identityUnavailable, identityTemporarilyUnavailable, emailChallenge, aliasReplacementUnavailable, rejected(String)
    var errorDescription: String? {
        switch self {
        case .manualLogin: "Завершите вход или дополнительную проверку OpenAI в браузере и продолжите смену email."
        case .identityUnavailable: "Не удалось подтвердить исходный идентификатор аккаунта. Смена email не отправлена."
        case .identityTemporarilyUnavailable: "OpenAI временно не отвечает на проверку аккаунта."
        case .emailChallenge: "Не удалось безопасно подставить код входа: нужны точный адрес аккаунта и сохранённое время запроса. Пройдите проверку в браузере и продолжите; исходный email и алиас сохранены."
        case .aliasReplacementUnavailable: "Не удалось подтвердить исходный аккаунт с прежним email. Алиас не заменён; проверьте вход в исходной сессии и повторите."
        case .rejected(let message): message
        }
    }
}
