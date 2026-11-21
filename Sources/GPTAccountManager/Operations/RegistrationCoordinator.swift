import Foundation
import Observation
import WebKit

enum RegistrationBatchError: Error, LocalizedError, Equatable {
    case invalidCount
    case insufficientEmails(available: Int)
    case invalidSavedBatch
    case persistenceFailed
    case pendingBatchExists
    case passwordNotConfigured

    var errorDescription: String? {
        switch self {
        case .invalidCount: "Укажите количество аккаунтов больше нуля."
        case .insufficientEmails(let available): "Недостаточно свободной почты. Доступно для этой очереди: \(available)."
        case .invalidSavedBatch: "Сохранённая очередь не совпадает с базой аккаунтов. Регистрация остановлена."
        case .persistenceFailed: "Не удалось сохранить очередь на диск. Регистрация остановлена; проверьте доступ к файлу очереди."
        case .pendingBatchExists: "Сначала продолжите текущую очередь или сбросьте её кнопкой «Новая регистрация»."
        case .passwordNotConfigured: NewPasswordConfiguration.unavailableMessage
        }
    }
}

/// One registration at a time, with the account's own persistent browser store.
@MainActor
@Observable
final class RegistrationCoordinator {
    private let store: AccountStore
    private let browser: ChatGPTAutomation
    private let mailbox: MailRuMailbox
    private let proxyStore: ProxyStore?
    private let configuredPassword: String?
    private let advanceRegistration: (@MainActor (UUID) async throws -> Void)?
    private let transitionWaitInterval: Duration
    private(set) var isRunning = false
    private(set) var totalCount = 0
    private(set) var completedCount = 0
    private(set) var blockedAccountIDs: [UUID] = []
    var blockedCount: Int { blockedAccountIDs.count }
    private(set) var skippedAccountIDs: [UUID] = []
    var skippedCount: Int { skippedAccountIDs.count }
    private(set) var removedBlockedAccountIDs: [UUID] = []
    static let deactivatedAccountMessage = "Аккаунт OpenAI удалён или деактивирован."
    private var remainingEmails: [String] = []
    private var batchAccountID: UUID?
    var hasPendingBatch: Bool { !remainingEmails.isEmpty }
    var canCreateDraft: Bool { configuredPassword != nil }
    private(set) var accountID: UUID?
    private(set) var activeSession: BrowserSession?
    private(set) var message = "Новый аккаунт появится в new-novoreg после подключения 2FA и сохранения сессии."
    @ObservationIgnored private var operation: Task<Void, Never>?
    @ObservationIgnored private var verificationFailure: String?
    @ObservationIgnored private var restoredBatchNeedsValidation = false
    @ObservationIgnored private var batchLoadFailed = false

    init(store: AccountStore, browser: ChatGPTAutomation, mailbox: MailRuMailbox, proxyStore: ProxyStore? = nil,
         configuredPassword: String? = NewPasswordConfiguration.configuredPassword,
         transitionWaitInterval: Duration = .seconds(45),
         advanceRegistration: (@MainActor (UUID) async throws -> Void)? = nil) {
        self.store = store
        self.browser = browser
        self.mailbox = mailbox
        self.proxyStore = proxyStore
        self.configuredPassword = NewPasswordConfiguration.validated(configuredPassword)
        self.advanceRegistration = advanceRegistration
        self.transitionWaitInterval = transitionWaitInterval
        let url = RegistrationBatchState.fileURL(for: store.fileURL)
        if FileManager.default.fileExists(atPath: url.path) {
            do {
                let saved = try JSONDecoder().decode(RegistrationBatchState.self, from: Data(contentsOf: url))
                try saved.validate()
                applyBatch(saved)
                accountID = saved.batchAccountID
                restoredBatchNeedsValidation = true
                if hasPendingBatch { message = "Очередь восстановлена. Нажмите «Возобновить» для продолжения." }
                else if totalCount > 0 { updateFinishedBatchMessage() }
            } catch {
                batchLoadFailed = true
                message = RegistrationBatchError.invalidSavedBatch.localizedDescription
            }
        }
    }

    static func randomProfile() -> (name: String, age: Int) {
        let first = ["Alex", "Sam", "Daniel", "Chris", "Max", "Robin", "Taylor", "Morgan"]
        let last = ["Parker", "Reed", "Hayes", "Bennett", "Walker", "Brooks", "Miller", "Lane"]
        return ("\(first.randomElement()!) \(last.randomElement()!)", Int.random(in: 21...45))
    }

    func registrationEmails(startingWith email: String, count: Int) throws -> [String] {
        guard count > 0 else { throw RegistrationBatchError.invalidCount }
        let first = try availableEmail(email)
        var seen: Set<String> = [first]
        let others = store.emailAliases.compactMap { alias -> String? in
            guard alias.status == .available, let value = try? availableEmail(alias.email),
                  seen.insert(value).inserted else { return nil }
            return value
        }
        let choices = [first] + others
        guard count <= choices.count else { throw RegistrationBatchError.insufficientEmails(available: choices.count) }
        return Array(choices.prefix(count))
    }

    private func availableEmail(_ email: String) throws -> String {
        guard let normalized = MailVerificationMatcher.normalizedAddress(email) else { throw AccountStoreError.invalidRegistration }
        guard !store.accounts.contains(where: {
            $0.email.caseInsensitiveCompare(normalized) == .orderedSame ||
            $0.pendingEmailChange?.newEmail.caseInsensitiveCompare(normalized) == .orderedSame
        }) else { throw AccountStoreError.duplicateAccountEmail }
        guard !store.emailAliases.contains(where: {
            $0.email.caseInsensitiveCompare(normalized) == .orderedSame && $0.status != .available
        }) else { throw AccountStoreError.emailAliasUnavailable }
        return normalized
    }

    func start(email: String, count: Int = 1) throws {
        guard !isRunning else { return }
        guard !batchLoadFailed else { throw RegistrationBatchError.invalidSavedBatch }
        try validateRestoredBatch()
        guard !hasPendingBatch else { throw RegistrationBatchError.pendingBatchExists }
        let emails = try registrationEmails(startingWith: email, count: count)
        guard let configuredPassword else { throw RegistrationBatchError.passwordNotConfigured }
        try saveBatch(.init(totalCount: emails.count, completedCount: 0, remainingEmails: emails))
        // Keep the immediate single-account draft behavior when no proxy preflight is needed.
        let first = proxyStore?.isEnabled == true ? nil : try makeDraft(email: emails[0], password: configuredPassword, proxy: nil)
        activeSession?.setVisible(false)
        activeSession = nil
        accountID = nil
        if let first { selectDraft(first); batchAccountID = first.id }
        try persistBatch()
        runBatch(recheckCurrentProxy: false)
    }

    private func makeDraft(email: String, password: String, proxy: AccountProxy?, requirePoolAlias: Bool = false) throws -> AccountRecord {
        let normalized = try availableEmail(email)
        if requirePoolAlias {
            guard store.emailAliases.contains(where: {
                $0.status == .available && $0.email.caseInsensitiveCompare(normalized) == .orderedSame
            }) else { throw AccountStoreError.emailAliasUnavailable }
        }
        let profile = Self.randomProfile()
        return try store.beginRegistration(email: normalized, fullName: profile.name, age: profile.age,
                                           password: password, proxy: proxy)
    }

    private func selectDraft(_ account: AccountRecord) {
        if accountID != account.id { verificationFailure = nil }
        activeSession?.setVisible(false)
        accountID = account.id
        store.selectedID = account.id
        activeSession = browser.accountSession(for: account)
        activeSession?.setVisible(true)
    }

    private var batchState: RegistrationBatchState {
        .init(totalCount: totalCount, completedCount: completedCount,
              remainingEmails: remainingEmails, batchAccountID: batchAccountID,
              blockedAccountIDs: blockedAccountIDs.isEmpty ? nil : blockedAccountIDs,
              skippedAccountIDs: skippedAccountIDs.isEmpty ? nil : skippedAccountIDs,
              removedBlockedAccountIDs: removedBlockedAccountIDs.isEmpty ? nil : removedBlockedAccountIDs)
    }

    private func applyBatch(_ state: RegistrationBatchState) {
        totalCount = state.totalCount
        completedCount = state.completedCount
        remainingEmails = state.remainingEmails
        batchAccountID = state.batchAccountID
        blockedAccountIDs = state.blockedAccountIDs ?? []
        skippedAccountIDs = state.skippedAccountIDs ?? []
        removedBlockedAccountIDs = state.removedBlockedAccountIDs ?? []
    }

    private func saveBatch(_ state: RegistrationBatchState) throws {
        do { try state.save(to: RegistrationBatchState.fileURL(for: store.fileURL)) }
        catch { throw RegistrationBatchError.persistenceFailed }
        applyBatch(state)
        batchLoadFailed = false
    }

    private func persistBatch() throws { try saveBatch(batchState) }

    private func resetBatch() throws {
        try saveBatch(.init(totalCount: 0, completedCount: 0, remainingEmails: []))
        restoredBatchNeedsValidation = false
    }

    private func validateRestoredBatch() throws {
        guard !batchLoadFailed else { throw RegistrationBatchError.invalidSavedBatch }
        guard restoredBatchNeedsValidation else { return }
        var saved = batchState
        guard Set(saved.skippedAccountIDs ?? []).isDisjoint(with: store.accounts.map(\.id)) else {
            throw RegistrationBatchError.invalidSavedBatch
        }
        for id in saved.blockedAccountIDs ?? [] {
            if (saved.removedBlockedAccountIDs ?? []).contains(id),
               !store.accounts.contains(where: { $0.id == id }) { continue }
            guard let account = store.accounts.first(where: { $0.id == id }),
                  account.pendingRegistration != nil, account.status != .ready,
                  account.lastError == Self.deactivatedAccountMessage,
                  !saved.remainingEmails.contains(account.email)
            else { throw RegistrationBatchError.invalidSavedBatch }
        }
        if let first = saved.remainingEmails.first {
            let matches = store.accounts.filter { $0.email == first }
            if let id = saved.batchAccountID {
                guard matches.count == 1, matches[0].id == id,
                      matches[0].pendingRegistration != nil || matches[0].status == .ready
                else { throw RegistrationBatchError.invalidSavedBatch }
            } else if !matches.isEmpty {
                // Crash between AccountStore's draft commit and saving its UUID.
                guard matches.count == 1, matches[0].pendingRegistration != nil else {
                    throw RegistrationBatchError.invalidSavedBatch
                }
                saved.batchAccountID = matches[0].id
            }
            let tail = saved.batchAccountID == nil ? saved.remainingEmails : Array(saved.remainingEmails.dropFirst())
            for email in tail {
                guard (try? availableEmail(email)) == email,
                      (saved.completedCount + (saved.blockedAccountIDs?.count ?? 0) + (saved.skippedAccountIDs?.count ?? 0) == 0 && email == first) || store.emailAliases.contains(where: {
                          $0.email == email && $0.status == .available
                      }) else { throw RegistrationBatchError.invalidSavedBatch }
            }
        }
        try saveBatch(saved)
        accountID = saved.batchAccountID
        restoredBatchNeedsValidation = false
    }

    func canDeleteBlockedAccount(id: UUID, protectedIDs: Set<UUID>) -> Bool {
        guard !batchLoadFailed, blockedAccountIDs.contains(id), !protectedIDs.contains(id),
              id != batchAccountID, id != accountID,
              let account = store.accounts.first(where: { $0.id == id }),
              account.pendingRegistration != nil, account.status != .ready,
              account.lastError == Self.deactivatedAccountMessage,
              !remainingEmails.contains(account.email),
              !account.hasPendingEmailChange, !account.hasPendingAccessChange,
              account.rotationStage == nil, account.pendingTOTPSecret == nil
        else { return false }
        return true
    }

    func deleteBlockedAccount(id: UUID, protectedIDs: Set<UUID>) throws {
        try validateRestoredBatch()
        guard canDeleteBlockedAccount(id: id, protectedIDs: protectedIDs) else {
            throw AccountStoreError.accountBusy
        }
        // Save intent first: a crash may leave the exact blocked draft present, never an unexplained missing ID.
        if !removedBlockedAccountIDs.contains(id) {
            var saved = batchState
            saved.removedBlockedAccountIDs = removedBlockedAccountIDs + [id]
            try saveBatch(saved)
        }
        try store.deleteDeactivatedRegistration(id: id, expectedError: Self.deactivatedAccountMessage,
                                               protectedIDs: protectedIDs)
    }

    private func recordCompletedBatchAccount() throws {
        var saved = batchState
        saved.completedCount += 1
        saved.remainingEmails.removeFirst()
        saved.batchAccountID = nil
        try saveBatch(saved)
    }

    private func recordBlockedBatchAccount(_ account: AccountRecord) throws {
        guard account.id == batchAccountID, account.email == remainingEmails.first,
              account.pendingRegistration != nil, account.status != .ready,
              account.lastError == Self.deactivatedAccountMessage,
              !blockedAccountIDs.contains(account.id) else { throw RegistrationBatchError.invalidSavedBatch }
        var saved = batchState
        saved.blockedAccountIDs = blockedAccountIDs + [account.id]
        saved.remainingEmails.removeFirst()
        saved.batchAccountID = nil
        try saveBatch(saved)
        activeSession?.setVisible(false)
        activeSession = nil
        accountID = nil
    }

    private func updateFinishedBatchMessage() {
        if skippedCount > 0 {
            message = "Очередь обработана: готово \(completedCount) из \(totalCount), заблокировано OpenAI: \(blockedCount), пропущено пользователем: \(skippedCount). Пропущенные и заблокированные не засчитаны готовыми."
        } else if blockedCount > 0 {
            message = "Очередь обработана: готово \(completedCount) из \(totalCount), заблокировано OpenAI: \(blockedCount). Заблокированные не засчитаны готовыми."
        } else if totalCount > 1 {
            message = "Регистрация завершена: \(completedCount) из \(totalCount). Аккаунты и сессии сохранены в new-novoreg."
        }
    }

    func resumeBatch() {
        guard !isRunning, hasPendingBatch else { return }
        do { try validateRestoredBatch(); try persistBatch() }
        catch { message = safeError(error); return }
        runBatch(recheckCurrentProxy: true)
    }

    private func runBatch(recheckCurrentProxy: Bool) {
        isRunning = true
        operation = Task { [weak self] in
            guard let self else { return }
            defer { self.isRunning = false; self.operation = nil }
            var recheck = recheckCurrentProxy
            do {
                while let email = self.remainingEmails.first {
                    try Task.checkCancellation()
                    if self.batchAccountID == nil {
                        guard let password = self.configuredPassword else { throw RegistrationBatchError.passwordNotConfigured }
                        try self.persistBatch()
                        _ = try self.availableEmail(email)
                        var proxy: AccountProxy?
                        if let proxies = self.proxyStore, proxies.isEnabled {
                            self.message = "Проверяется случайный прокси перед регистрацией…"
                            proxy = try await proxies.chooseForNewAccount()
                            try Task.checkCancellation()
                            guard proxy != nil else { throw RegistrationFailure.proxyUnavailable }
                        }
                        let account = try self.makeDraft(email: email, password: password, proxy: proxy,
                                                         requirePoolAlias: self.completedCount + self.blockedCount + self.skippedCount > 0)
                        self.batchAccountID = account.id
                        try self.persistBatch()
                        self.selectDraft(account)
                        recheck = false
                    }
                    guard let id = self.batchAccountID,
                          let account = self.store.accounts.first(where: { $0.id == id }) else {
                        throw RegistrationFailure.missingDraft
                    }
                    guard account.email == email else { throw RegistrationBatchError.invalidSavedBatch }
                    // Explicit server deactivation is terminal for this identity. Preserve its draft.
                    if account.lastError == Self.deactivatedAccountMessage, account.pendingRegistration != nil {
                        try self.recordBlockedBatchAccount(account)
                        recheck = false
                        continue
                    }
                    // AccountStore can commit readiness before the queue checkpoint reaches disk.
                    if account.pendingRegistration == nil, account.status == .ready {
                        _ = try self.store.writeRegistrationAccessTokenExport()
                        try self.recordCompletedBatchAccount()
                        continue
                    }
                    guard account.pendingRegistration != nil else {
                        throw RegistrationBatchError.invalidSavedBatch
                    }
                    self.selectDraft(account)
                    try self.persistBatch()
                    if recheck { try await self.ensureWorkingProxy(id: id) }
                    recheck = false
                    if let advanceRegistration = self.advanceRegistration {
                        try await advanceRegistration(id)
                    } else {
                        try await self.advance(id: id)
                    }
                    // A manual step returns normally too. Advance only after durable completion.
                    guard let finished = self.store.accounts.first(where: { $0.id == id }) else { return }
                    if finished.lastError == Self.deactivatedAccountMessage, finished.pendingRegistration != nil {
                        try self.recordBlockedBatchAccount(finished)
                        continue
                    }
                    guard finished.pendingRegistration == nil, finished.status == .ready else { return }
                    _ = try self.store.writeRegistrationAccessTokenExport()
                    try self.recordCompletedBatchAccount()
                }
                self.updateFinishedBatchMessage()
            } catch is CancellationError {
                self.message = "Остановлено. Этап, сессия и оставшаяся очередь сохранены; можно продолжить."
            } catch {
                self.message = "Регистрация приостановлена: \(self.safeError(error)) Этап и очередь сохранены."
            }
        }
    }

    func newRegistration() {
        guard !isRunning else { return }
        verificationFailure = nil
        do { try resetBatch() }
        catch { message = safeError(error); return }
        activeSession?.setVisible(false)
        activeSession = nil
        accountID = nil
        message = "Новый аккаунт появится в new-novoreg после подключения 2FA и сохранения сессии."
    }

    func resume(id: UUID) {
        guard !isRunning, let account = store.accounts.first(where: { $0.id == id }),
              account.pendingRegistration != nil else { return }
        guard account.lastError != Self.deactivatedAccountMessage || batchAccountID == id else {
            message = Self.deactivatedAccountMessage
            return
        }
        do { try validateRestoredBatch() }
        catch { message = safeError(error); return }
        guard !hasPendingBatch || batchAccountID == id else {
            message = RegistrationBatchError.pendingBatchExists.localizedDescription
            return
        }
        if batchAccountID != id || !hasPendingBatch {
            do { try saveBatch(.init(totalCount: 1, completedCount: 0,
                                    remainingEmails: [account.email], batchAccountID: id)) }
            catch { message = safeError(error); return }
        }
        selectDraft(account)
        resumeBatch()
    }

    func show(id: UUID) {
        guard !isRunning, let account = store.accounts.first(where: { $0.id == id }),
              account.pendingRegistration != nil else { return }
        do {
            try validateRestoredBatch()
            guard !hasPendingBatch || batchAccountID == id else {
                message = RegistrationBatchError.pendingBatchExists.localizedDescription
                return
            }
            if batchAccountID != id { try resetBatch() }
        } catch { message = safeError(error); return }
        if accountID != id { verificationFailure = nil }
        if verificationFailure == nil { verificationFailure = account.lastError }
        accountID = id
        activeSession = browser.accountSession(for: account)
        activeSession?.setVisible(true)
        message = "Незавершённая регистрация сохранена. Нажмите «Возобновить»."
    }

    func verifyInstalledPassword(id: UUID, password: String) throws {
        guard !isRunning else { throw AccountStoreError.accountBusy }
        try store.updateRegistrationPassword(id: id, password: password)
        resume(id: id)
    }

    func saveRegisteredAccountWithoutVerification(id: UUID) throws {
        guard !isRunning, accountID == id else { throw AccountStoreError.accountBusy }
        try store.saveRegistrationAsUnverifiedAccount(id: id, failure: verificationFailure)
        verificationFailure = nil
        try resetBatch()
        if let account = store.accounts.first(where: { $0.id == id }) { selectDraft(account) }
        message = "Аккаунт сохранён в менеджере без отметки «Готов». Регистрация закрыта; данные и постоянная сессия сохранены."
    }

    func stop() {
        operation?.cancel()
        mailbox.cancel()
        activeSession?.cancelLoading()
    }

    func proxyDidChange(id: UUID) {
        guard !isRunning, accountID == id else { return }
        show(id: id)
    }

    private func current(_ id: UUID) throws -> AccountRecord {
        try Task.checkCancellation()
        guard let account = store.accounts.first(where: { $0.id == id }),
              account.pendingRegistration != nil else { throw RegistrationFailure.missingDraft }
        return account
    }

    /// Reassign only before resuming; never replay a possibly submitted form on network failure.
    private func ensureWorkingProxy(id: UUID) async throws {
        let account = try current(id)
        guard let proxyStore, proxyStore.isEnabled, let assigned = account.proxy else { return }
        message = "Проверяется закреплённый прокси…"
        let checked = try await proxyStore.checkedProxy(replacing: assigned)
        try Task.checkCancellation()
        guard let checked else { throw RegistrationFailure.proxyUnavailable }
        guard checked != assigned else { return }
        let updated = try store.replaceAccountProxy(id: id, expectedProxy: assigned, proxy: checked)
        // Retain the persistent cookie store; the saved checkpoint restores the account's page.
        activeSession?.cancelLoading()
        activeSession?.setVisible(false)
        activeSession = browser.accountSession(for: updated)
        activeSession?.setVisible(true)
        message = "Недоступный прокси заменён: \(checked.displayName). Продолжается прежний аккаунт."
    }

    private func checkpoint(_ id: UUID, _ change: (inout PendingRegistration) -> Void) throws {
        var pending = try current(id).pendingRegistration!
        change(&pending)
        try store.checkpointRegistration(id: id, registration: pending)
    }

    @discardableResult
    private func prepareMail(_ id: UUID, in session: BrowserSession? = nil,
                             expectedPageURL: URL? = nil) async throws -> Bool {
        let email = try current(id).email
        let generation = session?.cancellationGeneration
        let baseline = try await mailBaseline()
        try Task.checkCancellation()
        if let session, let expectedPageURL {
            guard session.cancellationGeneration == generation, session.webView.url == expectedPageURL,
                  try await session.evaluate("location.href") as? String == expectedPageURL.absoluteString else { return false }
            guard session.cancellationGeneration == generation else { return false }
        }
        guard try current(id).email == email else { throw RegistrationFailure.wrongAccount }
        try checkpoint(id) {
            $0.baselineMessageIDs = baseline
            $0.requestedAt = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
        }
        return true
    }

    private func mailBaseline() async throws -> Set<String> {
        try await waitForMailbox { try await self.mailbox.captureBaseline() }
    }

    // Only repeat mailbox reads. Keep the original timestamp/exclusions and
    // submitted-stage state in the caller; never resend a registration form.
    func waitForMailbox<Value>(_ read: () async throws -> Value) async throws -> Value {
        while true {
            try Task.checkCancellation()
            do {
                let value = try await read()
                try Task.checkCancellation()
                return value
            } catch MailVerificationError.timedOut {
                try Task.checkCancellation()
                message = "Почта отвечает дольше обычного. Поиск кода продолжается автоматически; повторный запрос не отправляется…"
                try await Task.sleep(for: .milliseconds(350))
            }
        }
    }

    // Mail can remain unavailable while the user completes or changes the browser step.
    // Keep observing that exact document, and join both tasks before returning to the flow.
    func waitForEmailCode(in session: BrowserSession, expectedEmail: String,
                          read: @escaping @MainActor @Sendable () async throws -> MailVerificationCode) async throws -> MailVerificationCode? {
        try Task.checkCancellation()
        let state = try await RegistrationForm.inspect(in: session)
        guard state.kind == .emailCode, let pageURL = state.pageURL,
              pageURL == session.webView.url else { return nil }
        guard state.displayedEmail?.caseInsensitiveCompare(expectedEmail) == .orderedSame else {
            throw RegistrationFailure.wrongAccount
        }
        let generation = session.cancellationGeneration
        let token = UUID().uuidString
        guard try await RegistrationForm.emailCodeScreenMatches(in: session, expectedEmail: expectedEmail,
                                                               pageURL: pageURL, token: token, capture: true) else { return nil }
        let isCurrentScreen: @MainActor @Sendable () async throws -> Bool = {
            try Task.checkCancellation()
            guard session.cancellationGeneration == generation, session.webView.url == pageURL else { return false }
            do {
                guard try await RegistrationForm.emailCodeScreenMatches(in: session, expectedEmail: expectedEmail,
                                                                       pageURL: pageURL, token: token) else { return false }
                let current = try await RegistrationForm.inspect(in: session)
                guard current.kind == .emailCode, current.pageURL == pageURL else { return false }
                guard current.displayedEmail?.caseInsensitiveCompare(expectedEmail) == .orderedSame else {
                    throw RegistrationFailure.wrongAccount
                }
                guard session.cancellationGeneration == generation, session.webView.url == pageURL else { return false }
                return try await RegistrationForm.emailCodeScreenMatches(in: session, expectedEmail: expectedEmail,
                                                                        pageURL: pageURL, token: token)
            } catch let error as RegistrationFailure {
                throw error
            } catch {
                try Task.checkCancellation()
                // A navigation may invalidate an in-flight DOM inspection.
                return false
            }
        }
        guard try await isCurrentScreen() else { return nil }
        return try await withThrowingTaskGroup(of: MailVerificationCode?.self) { group in
            defer { group.cancelAll(); mailbox.cancel() }
            group.addTask { @MainActor @Sendable in
                do {
                    let code = try await self.waitForMailbox(read)
                    return try await isCurrentScreen() ? code : nil
                } catch MailVerificationError.cancelled {
                    try Task.checkCancellation()
                    guard session.cancellationGeneration == generation else { throw CancellationError() }
                    if try await !isCurrentScreen() { return nil }
                    throw MailVerificationError.cancelled
                }
            }
            group.addTask { @MainActor @Sendable in
                while true {
                    try await Task.sleep(for: .milliseconds(350))
                    if try await !isCurrentScreen() { return nil }
                }
            }
            let code = try await group.next()!
            try Task.checkCancellation()
            return code
        }
    }

    private func advance(id: UUID) async throws {
        let account = try current(id)
        let persistent = browser.accountSession(for: account)
        activeSession = persistent
        persistent.setVisible(true)
        if persistent.needsInitialPageLoad {
            message = "Открывается регистрация ChatGPT…"
            let awaitingCode = account.pendingRegistration?.passwordWasSubmitted == true &&
                (account.pendingRegistration?.phase == .awaitingEmailCode ||
                 (account.pendingRegistration?.phase == .enablingTwoFA && account.pendingRegistration?.mfaEmailVerificationPending == true))
            let initialURL = awaitingCode ? "https://auth.openai.com/email-verification" : "https://chatgpt.com/"
            let loaded = await persistent.loadInitialPage(URL(string: initialURL)!, seconds: 25)
            try Task.checkCancellation()
            guard loaded else { throw RegistrationFailure.pageUnavailable }
        }
        var transitionDeadline = ContinuousClock.now.advanced(by: transitionWaitInterval)
        var waitingForHuman = false
        var observedStep: String?
        var lastSubmitted: String?
        var preparedMailStep: String?
        var pendingEmailCode: MailVerificationCode?
        while true {
            let account = try current(id)
            if !waitingForHuman, ContinuousClock.now >= transitionDeadline {
                message = "Страница отвечает дольше обычного. Проверка продолжается автоматически…"
                // Retain this loop's submitted-stage and mailbox state. Restarting
                // advance would replay forms that may already have been accepted.
                try await Task.sleep(for: .seconds(2))
                try Task.checkCancellation()
            }
            var authenticated = false
            if TrustedChatGPTOrigin.allowsMetadata(persistent.webView.url) {
                do {
                    authenticated = try await browser.hasAuthenticatedSession(for: account, in: persistent)
                } catch is CancellationError {
                    throw CancellationError()
                } catch ChatGPTAutomation.SavedSessionError.wrongAccount {
                    throw RegistrationFailure.wrongAccount
                } catch {
                    try Task.checkCancellation()
                    // Redirects can replace the document during the identity probe.
                    // Keep observing this session; never infer signed-out state from a failed probe.
                    message = "Ожидается ответ страницы входа…"
                    try await Task.sleep(for: .milliseconds(500))
                    continue
                }
            }
            if authenticated {
                let identity = try await EmailChangeAutomation.identity(in: persistent)
                guard identity.email.caseInsensitiveCompare(account.email) == .orderedSame else {
                    throw RegistrationFailure.wrongAccount
                }
                guard account.pendingRegistration?.passwordWasSubmitted == true else {
                    message = "Вход выполнен, но пароль ещё не установлен. Установите пароль в аккаунте и продолжите; сгенерированный пароль не считается рабочим."
                    return
                }
                try await secureAndVerify(id: id, persistent: persistent)
                return
            }
            _ = await browser.dismissCookieConsent(in: persistent)
            // A navigation can replace the document while it is being inspected.
            let state: RegistrationForm.State
            do { state = try await RegistrationForm.inspect(in: persistent) }
            catch {
                try Task.checkCancellation()
                guard TrustedChatGPTOrigin.allowsAuthentication(persistent.webView.url) else { throw error }
                try await Task.sleep(for: .milliseconds(350))
                continue
            }
            // WKWebView can expose the next URL before the old document's inspection returns.
            guard let pageURL = state.pageURL, pageURL == persistent.webView.url else {
                try await Task.sleep(for: .milliseconds(350))
                continue
            }
            if state.kind == .emailCode, account.pendingRegistration?.phase == .enablingTwoFA {
                try await secureAndVerify(id: id, persistent: persistent)
                return
            }
            let step = "\(pageURL.host ?? "")\(pageURL.path)|\(state.kind)"
            if observedStep != step {
                observedStep = step
                transitionDeadline = ContinuousClock.now.advanced(by: transitionWaitInterval)
            }
            if state.kind == .registrationRejected {
                guard pageURL.host == "auth.openai.com", pageURL.path == "/about-you" else {
                    message = RegistrationForm.rejectionMessage
                    return
                }
                if try await submitSavedProfile(id: id, in: persistent) {
                    lastSubmitted = "\(pageURL.host ?? "")\(pageURL.path)|profile"
                    transitionDeadline = ContinuousClock.now.advanced(by: transitionWaitInterval)
                } else {
                    try await Task.sleep(for: .milliseconds(500))
                }
                continue
            }
            if state.kind == .challenge {
                if !waitingForHuman {
                    waitingForHuman = true
                    message = "Пройдите проверку в открытой странице. После неё регистрация продолжится автоматически."
                }
                try await Task.sleep(for: .milliseconds(500))
                continue
            }
            if waitingForHuman {
                waitingForHuman = false
                transitionDeadline = ContinuousClock.now.advanced(by: transitionWaitInterval)
            }
            if step == lastSubmitted {
                try await Task.sleep(for: .milliseconds(350))
                continue
            }
            let needsLogin = state.kind == .entry || state.kind == .email ||
                (state.kind == .password && !state.isCreatingPassword) ||
                (state.kind == .password && state.isCreatingPassword &&
                    [.profile, .enablingTwoFA, .verifyingLogin].contains(account.pendingRegistration!.phase)) ||
                (pageURL.host == "auth.openai.com" &&
                    (pageURL.path.hasPrefix("/mfa-challenge/") ||
                     ["/choose-an-account", "/log-in-or-create-account"].contains(pageURL.path)))
            if account.pendingRegistration?.passwordWasSubmitted == true && needsLogin {
                if try await recoverLogin(id: id, in: persistent) {
                    try await secureAndVerify(id: id, persistent: persistent)
                }
                return
            }
            switch state.kind {
            case .entry:
                message = "Открывается форма регистрации…"
                guard try await RegistrationForm.clickSignUp(in: persistent) else {
                    try await Task.sleep(for: .milliseconds(500))
                    continue
                }
            case .email:
                guard account.pendingRegistration?.phase == .signingUp else { throw RegistrationFailure.unsupportedForm }
                message = "Подготавливается почта и отправляется адрес…"
                if preparedMailStep != step {
                    try await prepareMail(id)
                    preparedMailStep = step
                    transitionDeadline = ContinuousClock.now.advanced(by: transitionWaitInterval)
                }
                guard try await RegistrationForm.submitEmail(account.email, in: persistent) else {
                    try await Task.sleep(for: .milliseconds(500))
                    continue
                }
            case .password:
                guard state.isCreatingPassword else {
                    message = "Этот адрес ведёт на вход существующего аккаунта. Новая регистрация остановлена."
                    return
                }
                guard account.pendingRegistration?.passwordWasSubmitted != true else {
                    message = "Пароль уже отправлен. Ожидается следующий этап регистрации…"
                    try await Task.sleep(for: .milliseconds(350))
                    continue
                }
                message = "Устанавливается пароль нового аккаунта…"
                if preparedMailStep != step {
                    try await prepareMail(id)
                    preparedMailStep = step
                    transitionDeadline = ContinuousClock.now.advanced(by: transitionWaitInterval)
                }
                guard try await RegistrationForm.submitPassword(account.password, in: persistent) else {
                    try await Task.sleep(for: .milliseconds(500))
                    continue
                }
                try checkpoint(id) { $0.passwordWasSubmitted = true; $0.phase = .awaitingEmailCode }
            case .emailCode:
                guard state.displayedEmail?.caseInsensitiveCompare(account.email) == .orderedSame else {
                    throw RegistrationFailure.wrongAccount
                }
                if account.pendingRegistration?.passwordWasSubmitted != true {
                    guard try await RegistrationForm.selectPasswordSignup(in: persistent) else {
                        message = "Ожидается выбор «Продолжить с паролем» для установки пароля…"
                        try await Task.sleep(for: .milliseconds(500))
                        continue
                    }
                    break
                }
                guard let pending = account.pendingRegistration, let since = pending.requestedAt else {
                    throw RegistrationFailure.missingMailRequest
                }
                message = "Ожидается письмо OpenAI для \(account.email)…"
                if pendingEmailCode == nil {
                    pendingEmailCode = try await waitForEmailCode(in: persistent, expectedEmail: account.email) {
                        try await self.mailbox.waitForCode(
                            alias: account.email, since: since, excluding: pending.baselineMessageIDs, purpose: .registration)
                    }
                    transitionDeadline = ContinuousClock.now.advanced(by: transitionWaitInterval)
                }
                guard let code = pendingEmailCode else { continue }
                guard try await RegistrationForm.submitEmailCode(code.code, expectedEmail: account.email, observedScreenOnly: true, in: persistent) else {
                    pendingEmailCode = nil
                    try await Task.sleep(for: .milliseconds(500))
                    continue
                }
                try checkpoint(id) {
                    $0.baselineMessageIDs.insert(code.messageID)
                    if $0.phase == .awaitingEmailCode { $0.phase = .profile }
                }
                pendingEmailCode = nil
            case .profile:
                guard try await submitSavedProfile(id: id, in: persistent) else {
                    try await Task.sleep(for: .milliseconds(500))
                    continue
                }
            case .challenge, .registrationRejected:
                continue
            case .authenticated, .unknown:
                try await Task.sleep(for: .milliseconds(500))
                continue
            }
            // Switching to password setup may briefly preserve the old email-code DOM.
            lastSubmitted = step
            transitionDeadline = ContinuousClock.now.advanced(by: transitionWaitInterval)
            try await Task.sleep(for: .milliseconds(500))
        }
    }

    private func submitSavedProfile(id: UUID, in session: BrowserSession) async throws -> Bool {
        var profile = try current(id).pendingRegistration!
        guard profile.termsAccepted else { throw RegistrationFailure.termsRequired }
        guard profile.passwordWasSubmitted else { throw RegistrationFailure.passwordNotSet }
        let formState = try await RegistrationForm.inspect(in: session)
        if formState.kind == .registrationRejected {
            guard profile.profileRetryUsed != true else { throw RegistrationForm.ProfileRetryError.exhausted }
            message = "Повторно нажимается «Продолжить» с сохранёнными именем и возрастом…"
            let submitted = try await RegistrationForm.retryRejectedProfile(fullName: profile.fullName, age: profile.age, in: session) {
                try self.checkpoint(id) { $0.profileRetryUsed = true }
            }
            if submitted { try await Task.sleep(for: .seconds(2)) }
            return submitted
        }
        guard profile.profileRetryUsed != true else { return false }
        if formState.profileRequiresBirthDate, profile.birthDate == nil {
            guard let birthDate = PendingRegistration.birthDate(forAge: profile.age) else {
                throw AccountStoreError.invalidRegistration
            }
            try checkpoint(id) { $0.birthDate = birthDate }
            profile = try current(id).pendingRegistration!
        }
        message = "Заполняется профиль: \(profile.fullName), \(profile.age)."
        return try await RegistrationForm.submitProfile(fullName: profile.fullName, age: profile.age,
                                                       birthDate: profile.birthDate, in: session)
    }

    /// Recover only when the same draft's existing saved session actually needs sign-in.
    private func recoverLogin(id: UUID, in session: BrowserSession) async throws -> Bool {
        message = "Восстанавливается вход сохранённого аккаунта…"
        // Refresh before a new login request. An existing MFA challenge needs only its saved key.
        if !(session.webView.url?.host == "auth.openai.com" &&
             (session.webView.url?.path.hasPrefix("/mfa-challenge/") == true ||
              ["/email-verification", "/verify-email"].contains(session.webView.url?.path ?? ""))) {
            try await prepareMail(id)
        }
        let account = try current(id)
        var pendingCode: MailVerificationCode?
        let result = await browser.signIn(
            account: account, secret: account.pendingRegistration?.pendingSecret ?? "", in: session,
            loginTimeoutSeconds: 45, automaticallyWaitForTransitions: true,
            continueWaitingOnTimeout: true,
            registrationProfileHandler: { page in
                try await self.submitSavedProfile(id: id, in: page)
            }, beforePasswordSubmission: { page in
                guard let pageURL = page.webView.url else { return }
                if try await self.prepareMail(id, in: page, expectedPageURL: pageURL) { pendingCode = nil }
            }, emailCodeHandler: { page in
                let pending = try self.current(id).pendingRegistration!
                guard let since = pending.requestedAt else { throw RegistrationFailure.missingMailRequest }
                self.message = "Ожидается код входа OpenAI для \(account.email)…"
                if pendingCode == nil {
                    pendingCode = try await self.waitForEmailCode(in: page, expectedEmail: account.email) {
                        try await self.mailbox.waitForCode(
                            alias: account.email, since: since, excluding: pending.baselineMessageIDs, purpose: .login)
                    }
                }
                guard let code = pendingCode else { return false }
                let deadline = ContinuousClock.now.advanced(by: .seconds(45))
                while ContinuousClock.now < deadline {
                    try Task.checkCancellation()
                    guard page.webView.url?.host == "auth.openai.com",
                          ["/email-verification", "/verify-email"].contains(page.webView.url?.path ?? "") else { return false }
                    if try await RegistrationForm.submitEmailCode(code.code, expectedEmail: account.email, observedScreenOnly: true, in: page) {
                        try self.checkpoint(id) { $0.baselineMessageIDs.insert(code.messageID) }
                        pendingCode = nil
                        return true
                    }
                    pendingCode = nil
                    return false
                }
                return false
            })
        try Task.checkCancellation()
        switch result {
        case .success(let snapshot, _):
            let identity = try await EmailChangeAutomation.identity(in: session)
            guard identity.email.caseInsensitiveCompare(account.email) == .orderedSame,
                  snapshot.signedInEmail.caseInsensitiveCompare(account.email) == .orderedSame else {
                throw RegistrationFailure.wrongAccount
            }
            return true
        case .failure(let text):
            if text == Self.deactivatedAccountMessage {
                try store.mutate(id: id) { $0.lastError = text }
            }
            message = text
            return false
        case .manual(let text, _), .restart(let text):
            message = text
            return false
        }
    }

    private func secureAndVerify(id: UUID, persistent: BrowserSession) async throws {
        var account = try current(id)
        verificationFailure = nil
        if account.pendingRegistration!.phase != .verifyingLogin {
            try checkpoint(id) { $0.phase = .enablingTwoFA }
            message = "Подключается приложение-аутентификатор…"
            if !TrustedChatGPTOrigin.allowsSecurityAutomation(persistent.webView.url) {
                // Preserve an email challenge already sent by OpenAI; navigation would lose its exact stage.
                if try await RegistrationForm.inspect(in: persistent).kind != .emailCode {
                    try await prepareMail(id)
                    let opened = await browser.openSecuritySettings(in: persistent, seconds: 20)
                    try Task.checkCancellation()
                    if !opened && !TrustedChatGPTOrigin.allowsAuthentication(persistent.webView.url) {
                        message = "Настройки безопасности не открылись. Откройте их в браузере и продолжите."
                        return
                    }
                }
            }
            var pendingReauthenticationCode: MailVerificationCode?
            let result = await browser.enrollNewAuthenticator(
                in: persistent, pendingSecret: account.pendingRegistration?.pendingSecret,
                automaticallyWaitForTransitions: true,
                beforeSetup: { page in
                    guard let pageURL = page.webView.url else { return false }
                    let prepared = try await self.prepareMail(id, in: page, expectedPageURL: pageURL)
                    if prepared {
                        pendingReauthenticationCode = nil
                        try self.checkpoint(id) { $0.mfaEmailVerificationPending = nil }
                    }
                    return prepared
                },
                reauthenticationHandler: { page in
                    let account = try self.current(id)
                    let pending = account.pendingRegistration!
                    guard let since = pending.requestedAt else { throw RegistrationFailure.missingMailRequest }
                    if pending.mfaEmailVerificationPending != true {
                        try self.checkpoint(id) { $0.mfaEmailVerificationPending = true }
                    }
                    self.message = "Подтверждается вход кодом из почты перед подключением 2FA…"
                    if pendingReauthenticationCode == nil {
                        pendingReauthenticationCode = try await self.waitForEmailCode(in: page, expectedEmail: account.email) {
                            try await self.mailbox.waitForCode(alias: account.email, since: since,
                                                              excluding: pending.baselineMessageIDs, purpose: .login)
                        }
                    }
                    guard let code = pendingReauthenticationCode else { return false }
                    guard try await RegistrationForm.submitEmailCode(code.code, expectedEmail: account.email, observedScreenOnly: true, in: page) else {
                        pendingReauthenticationCode = nil
                        return false
                    }
                    try self.checkpoint(id) {
                        $0.baselineMessageIDs.insert(code.messageID)
                        $0.mfaEmailVerificationPending = nil
                    }
                    pendingReauthenticationCode = nil
                    return true
                },
                onSecret: { secret in try self.checkpoint(id) { $0.pendingSecret = secret } })
            try Task.checkCancellation()
            switch result {
            case .enabled:
                try checkpoint(id) { $0.phase = .verifyingLogin; $0.mfaEmailVerificationPending = nil }
            case .manual(let text), .failure(let text):
                message = text
                return
            }
        }
        account = try current(id)
        guard let secret = account.pendingRegistration?.pendingSecret else { throw RegistrationFailure.missingSecret }
        message = "Сохраняются аккаунт, текущая сессия и accessToken…"
        if !TrustedChatGPTOrigin.allowsSecurityAutomation(persistent.webView.url) {
            guard await browser.openSecuritySettings(in: persistent, seconds: 20) else {
                message = "Ожидаются настройки безопасности в сохранённой сессии. Продолжите после загрузки."
                return
            }
        }
        try Task.checkCancellation()
        let generation = persistent.cancellationGeneration
        let pageURL = persistent.webView.url
        let token: String
        let snapshot: SubscriptionSnapshot
        do {
            token = try await browser.accessToken(for: account, in: persistent)
            snapshot = try await browser.registrationSetupSnapshot(for: account, in: persistent)
        } catch is CancellationError {
            throw CancellationError()
        } catch ChatGPTAutomation.SavedSessionError.wrongAccount {
            throw RegistrationFailure.wrongAccount
        } catch {
            message = "Не удалось подтвердить текущую сессию, включённый 2FA или получить accessToken. Черновик сохранён; можно продолжить."
            return
        }
        try Task.checkCancellation()
        guard generation == persistent.cancellationGeneration, persistent.webView.url == pageURL,
              try current(id) == account else { throw CancellationError() }
        try persistBatch()
        try store.completeRegistrationAfterSetup(id: id, verifiedEmail: snapshot.signedInEmail, secret: secret,
                                                 authenticatorEnabled: true, snapshot: snapshot, accessToken: token)
        _ = try store.writeRegistrationAccessTokenExport()
        try persistBatch()
        activeSession = persistent
        persistent.setVisible(true)
        message = "Готово: аккаунт, 2FA, текущая сессия и accessToken сохранены в new-novoreg."
    }

    private func safeError(_ error: Error) -> String {
        if let failure = error as? RegistrationBatchError { return failure.localizedDescription }
        if let failure = error as? AccountStoreError,
           [.duplicateAccountEmail, .emailAliasUnavailable].contains(failure) {
            return "Следующая почта уже занята. Текущий аккаунт сохранён; выберите свободные адреса для новой очереди."
        }
        if error is RegistrationForm.ProfileRetryError { return RegistrationForm.rejectionMessage }
        if let failure = error as? RegistrationFailure { return failure.localizedDescription }
        if let failure = error as? MailVerificationError { return failure.localizedDescription }
        if let failure = error as? ProxyStoreError { return failure.localizedDescription }
        return "Не удалось подтвердить текущий этап. Проверьте страницу и подключение почты."
    }
}

private enum RegistrationFailure: Error, LocalizedError {
    case missingDraft, pageUnavailable, wrongAccount, unsupportedForm, missingMailRequest, missingSecret, termsRequired, proxyUnavailable, passwordNotSet
    var errorDescription: String? {
        switch self {
        case .missingDraft: "Черновик регистрации не найден."
        case .pageUnavailable: "Страница ChatGPT не загрузилась."
        case .wrongAccount: "В браузере открыт другой аккаунт."
        case .unsupportedForm: "Форма изменилась или требует ручного действия."
        case .missingMailRequest: "Не сохранён момент запроса письма."
        case .missingSecret: "Ключ нового 2FA не сохранён."
        case .passwordNotSet: "Пароль аккаунта ещё не установлен. Сохранённый пароль нельзя использовать для входа."
        case .termsRequired: "Подтвердите условия перед завершением регистрации."
        case .proxyUnavailable: "Рабочий прокси не найден. Прямое подключение не использовалось."
        }
    }
}
