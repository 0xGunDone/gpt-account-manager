import Foundation
import Observation

enum RotationVerificationError: Error, Equatable {
    case identityOrSecretMissing
}

enum ManualAuthenticatorRecoveryError: Error, Equatable {
    case invalidStage
    case invalidSecret
}

enum RotationState {
    static func markRemovalStarted(in account: inout AccountRecord) {
        account.rotationStage = .removingOldMethod
        account.status = .needsRecovery
    }

    static func markOldMethodDisabled(in account: inout AccountRecord) {
        account.rotationStage = .oldMethodDisabled
        account.status = .needsRecovery
    }

    static func capture(secret: String, in account: inout AccountRecord) {
        account.pendingTOTPSecret = secret
        account.rotationStage = .pendingSecretCaptured
        account.status = .needsRecovery
    }

    static func markSetupConfirmed(in account: inout AccountRecord) {
        account.rotationStage = .awaitingCleanLogin
        account.status = .needsRecovery
    }

    static func stageManuallyConfiguredSecret(
        _ secret: String,
        in account: inout AccountRecord
    ) throws {
        guard account.rotationStage == .oldMethodDisabled,
              account.pendingTOTPSecret == nil
        else { throw ManualAuthenticatorRecoveryError.invalidStage }

        let normalized = TOTPService.normalizedSecret(secret)
        guard TOTPService.isValidSecret(normalized),
              normalized != TOTPService.normalizedSecret(account.totpSecret)
        else { throw ManualAuthenticatorRecoveryError.invalidSecret }

        account.pendingTOTPSecret = normalized
        account.rotationStage = .awaitingCleanLogin
        account.status = .needsRecovery
        account.lastError = nil
    }

    static func markCleanLoginVerified(
        signedInEmail: String,
        proof: CleanLoginProof,
        in account: inout AccountRecord
    ) throws {
        guard signedInEmail.caseInsensitiveCompare(account.email) == .orderedSame,
              proof.isSufficient,
              let pending = account.pendingTOTPSecret
        else { throw RotationVerificationError.identityOrSecretMissing }
        account.totpSecret = pending
        account.pendingTOTPSecret = nil
        account.rotationStage = nil
        if account.pendingAccessChange == .passwordAndTwoFA {
            account.pendingAccessChange = nil
            account.accessChangePasswordVerified = nil
        }
        account.status = .ready
        account.lastError = nil
    }
}

@MainActor
@Observable
final class OperationCoordinator {
    static let missingRotationSessionMessage = "Исходная сессия недоступна. Выберите «Новый вход», чтобы продолжить с сохранённого этапа."

    private let store: AccountStore
    private let checker: SubscriptionChecking
    private let proxyStore: ProxyStore?
    private let rotator: TwoFARotating?
    private let passwordChanger: PasswordChanging?
    private let configuredPassword: String?
    private let emailChanger: EmailChanging?
    private(set) var changingEmailAccountID: UUID?
    private(set) var exitingEmailAccountID: UUID?
    private var displayedEmailAccountID: UUID?
    // ponytail: unstarted group work stays in memory; the current reservation and checkpoints persist in AccountStore.
    private(set) var emailQueueAccountIDs: [UUID] = []
    var emailQueueRemainingCount: Int { emailQueueAccountIDs.count }

    var pendingEmailAccountIDs: Set<UUID> { Set(store.accounts.filter(\.hasPendingEmailChange).map(\.id)) }
    var hasPendingEmailChange: Bool { !pendingEmailAccountIDs.isEmpty || !emailQueueAccountIDs.isEmpty }
    private(set) var accessChangeMode: AccessChangeMode = .twoFA
    private let rotationQueue = RotationQueue()
    private var remainingIDs: [UUID] = []
    private let maximumPendingChecks = 256
    private var checkQueueAccountIDs: Set<UUID> = []
    private var checkQueueWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var checkQueueActive = false
    private var checkQueueOverflowed = false
    private var stopRequested = false
    private(set) var checkingAccountID: UUID?
    private var displayedCheckAccountID: UUID?
    private var displayedCheckStoreID: UUID?
    private var displayedCheckProxy: AccountProxy?
    private var oauthAccountIDs: Set<UUID> = []
    private var authorizingAccountID: UUID?
    private let accountSessions: AccountSessionProviding?
    private var recoveringAccountID: UUID?
    private let browserRecovery: BrowserRecoveryHandling?

    private(set) var isRunning = false
    private(set) var completedCount = 0
    private(set) var totalCount = 0
    private(set) var pausedAccountID: UUID?
    private(set) var isRotating = false
    private(set) var message: String?

    var isCheckingAccounts: Bool { checkQueueActive }
    var pendingCheckCount: Int { max(0, remainingIDs.count - 1) }
    var canEnqueueChecks: Bool {
        pausedAccountID == nil && !hasPendingEmailChange && pausedRotationAccountIDs.isEmpty &&
            changingEmailAccountID == nil && exitingEmailAccountID == nil &&
            authorizingAccountID == nil && recoveringAccountID == nil && !isRotating &&
            (!isRunning || (checkQueueActive && !stopRequested))
    }

    var rotationStates: [UUID: RotationQueueItemState] { rotationQueue.states }
    var rotationAccountIDs: Set<UUID> { rotationQueue.accountIDs }
    var activeRotationAccountIDs: Set<UUID> { rotationQueue.activeAccountIDs }
    var pausedRotationAccountIDs: Set<UUID> { rotationQueue.pausedAccountIDs }
    var rotationCompletedCount: Int { rotationQueue.completedCount }
    var rotationTotalCount: Int { rotationQueue.totalCount }
    var pausedRotationAccountID: UUID? {
        store.accounts.first(where: { pausedRotationAccountIDs.contains($0.id) })?.id
    }
    var protectedAccountIDs: Set<UUID> {
        var ids = Set(rotationQueue.states.compactMap { id, state in
            state == .queued || state == .running ? id : nil
        }).union(pausedRotationAccountIDs).union(pendingEmailAccountIDs).union(emailQueueAccountIDs)
        ids.formUnion(remainingIDs)
        if let recoveringAccountID { ids.insert(recoveringAccountID) }
        if let authorizingAccountID { ids.insert(authorizingAccountID) }
        if let checkingAccountID { ids.insert(checkingAccountID) }
        if let pausedAccountID { ids.insert(pausedAccountID) }
        return ids
    }
    var maximumRotationConcurrency: Int {
        1
    }
    var activeSession: BrowserSession? {
        if let id = pausedRotationAccountID { return browserSession(for: id) }
        return checker.activeSession
    }

    init(
        store: AccountStore,
        checker: SubscriptionChecking,
        rotator: TwoFARotating? = nil,
        browserRecovery: BrowserRecoveryHandling? = nil,
        accountSessions: AccountSessionProviding? = nil,
        emailChanger: EmailChanging? = nil,
        proxyStore: ProxyStore? = nil,
        configuredPassword: String? = NewPasswordConfiguration.configuredPassword
    ) {
        self.store = store
        self.checker = checker
        self.proxyStore = proxyStore
        self.rotator = rotator
        self.passwordChanger = rotator as? PasswordChanging
        self.configuredPassword = NewPasswordConfiguration.validated(configuredPassword)
        self.browserRecovery = browserRecovery
        self.accountSessions = accountSessions
        self.emailChanger = emailChanger
    }

    func changeEmail(id: UUID, alias: String? = nil) async {
        guard !isRunning, exitingEmailAccountID == nil, pausedAccountID == nil, pausedRotationAccountIDs.isEmpty,
              emailQueueAccountIDs.isEmpty || emailQueueAccountIDs.first == id,
              emailChanger != nil,
              let account = store.accounts.first(where: { $0.id == id }),
              account.rotationStage == nil, account.pendingTOTPSecret == nil, !account.hasPendingAccessChange && account.pendingRegistration == nil,
              pendingEmailAccountIDs.isEmpty || pendingEmailAccountIDs == [id]
        else { return }
        do {
            if account.pendingEmailChange == nil { _ = try store.reserveEmailChange(id: id, alias: alias) }
        } catch {
            message = "Не удалось зарезервировать свободный алиас. Проверьте базу почт."
            return
        }
        await continueEmailChange(id: id)
    }

    func changeEmail(groupID: UUID) async {
        guard !isRunning, !hasPendingEmailChange, pausedAccountID == nil,
              pausedRotationAccountIDs.isEmpty, emailChanger != nil, !Task.isCancelled else { return }
        let ids = store.accounts(in: groupID).filter {
            $0.rotationStage == nil && $0.pendingTOTPSecret == nil && !$0.hasPendingCredentialChange
        }.map(\.id)
        guard !ids.isEmpty else {
            message = "В группе нет аккаунтов для новой смены email."
            return
        }
        let occupiedEmails = Set(store.accounts.map { $0.email.lowercased() })
        let availableAliases = Set(store.emailAliases.filter {
            $0.status == .available && !occupiedEmails.contains($0.email.lowercased())
        }.map { $0.email.lowercased() })
        guard availableAliases.count >= ids.count else {
            message = "Недостаточно свободных алиасов: нужно \(ids.count), доступно \(availableAliases.count). Добавьте адреса в базу почт."
            return
        }
        emailQueueAccountIDs = ids
        completedCount = 0
        totalCount = ids.count
        await resumeEmailGroup()
    }

    func resumeEmailGroup() async {
        guard !isRunning, exitingEmailAccountID == nil, pausedAccountID == nil, pausedRotationAccountIDs.isEmpty,
              emailChanger != nil, let firstID = emailQueueAccountIDs.first,
              pendingEmailAccountIDs.isEmpty || pendingEmailAccountIDs == [firstID]
        else { return }
        isRunning = true
        isRotating = false
        stopRequested = false
        defer { isRunning = false }
        while let id = emailQueueAccountIDs.first {
            guard !stopRequested, !Task.isCancelled else {
                message = "Смена email группы остановлена. Очередь и сохранённый этап можно продолжить."
                return
            }
            guard let account = store.accounts.first(where: { $0.id == id }),
                  account.rotationStage == nil, account.pendingTOTPSecret == nil,
                  !account.hasPendingAccessChange, account.pendingRegistration == nil else {
                message = "Очередь email приостановлена: аккаунт недоступен или требует завершения другой операции."
                return
            }
            do {
                if account.pendingEmailChange == nil { _ = try store.reserveEmailChange(id: id) }
            } catch {
                message = "Очередь email приостановлена: не удалось зарезервировать свободный алиас. Проверьте базу почт и продолжите."
                return
            }
            guard await performEmailChange(id: id) else { return }
            emailQueueAccountIDs.removeFirst()
            completedCount += 1
        }
        message = "Смена email группы завершена: \(completedCount) из \(totalCount). Новые логины проверены и сохранены."
    }

    func cancelEmailGroupQueue() {
        guard !isRunning, exitingEmailAccountID == nil, !emailQueueAccountIDs.isEmpty else { return }
        emailQueueAccountIDs.removeAll()
        emailChanger?.cancel()
        if pendingEmailAccountIDs.isEmpty {
            totalCount = completedCount
            message = "Очередь смены email отменена. Завершённые изменения сохранены."
        } else {
            completedCount = 0
            totalCount = 1
            message = "Очередь смены email отменена. Текущий резерв и этап сохранены; завершите смену email этого аккаунта отдельно."
        }
    }

    func continueEmailChange(id: UUID) async {
        guard !isRunning, exitingEmailAccountID == nil, pausedAccountID == nil, pausedRotationAccountIDs.isEmpty,
              emailQueueAccountIDs.isEmpty || emailQueueAccountIDs.first == id,
              emailChanger != nil,
              store.accounts.contains(where: { $0.id == id && $0.hasPendingEmailChange })
        else { return }
        if !emailQueueAccountIDs.isEmpty {
            await resumeEmailGroup()
            return
        }
        isRunning = true
        isRotating = false
        stopRequested = false
        completedCount = 0
        totalCount = 1
        defer { isRunning = false }
        if await performEmailChange(id: id) { completedCount = 1 }
    }

    private func performEmailChange(id: UUID) async -> Bool {
        guard let emailChanger,
              let account = store.accounts.first(where: { $0.id == id && $0.hasPendingEmailChange })
        else { return false }
        changingEmailAccountID = id
        displayedEmailAccountID = id
        displayedCheckAccountID = nil
        oauthAccountIDs.remove(id)
        store.selectedID = id
        message = "Смена email…"
        emailChanger.prepareSession(for: account)
        defer { changingEmailAccountID = nil }
        let outcome = await emailChanger.changeEmail(account: account) { [weak self] change in
            guard let self, !self.stopRequested, !Task.isCancelled else { throw CancellationError() }
            try self.store.checkpointEmailChange(id: id, change: change)
        }
        guard !stopRequested, !Task.isCancelled else {
            message = "Смена email остановлена. Резерв и этап сохранены; продолжите проверку."
            return false
        }
        switch outcome {
        case .success(let proof):
            do {
                try store.completeEmailChange(id: id, proof: proof)
                message = "Email изменён и проверен. Новый логин сохранён; алиас отмечен использованным."
                return true
            } catch {
                message = "Не удалось сохранить проверенную смену email. Оба адреса и резерв сохранены; продолжите проверку."
            }
        case .manual(let text), .failure(let text):
            message = redacted(text, account: account)
        }
        return false
    }

    func cancelUnsubmittedEmailChange(id: UUID) {
        guard !isRunning, exitingEmailAccountID == nil, emailQueueAccountIDs.isEmpty || emailQueueAccountIDs.first == id else { return }
        do {
            try store.cancelUnsubmittedEmailChange(id: id)
            emailQueueAccountIDs.removeAll()
            emailChanger?.cancel()
            message = "Смена email отменена до отправки кода. Алиас снова свободен."
        } catch { message = "Запрос уже мог изменить аккаунт. Резерв сохраняется до проверки нового email." }
    }

    func exitEmailChange(id: UUID, operationID: UUID) async {
        guard exitingEmailAccountID == nil, pausedAccountID == nil, pausedRotationAccountIDs.isEmpty,
              emailQueueAccountIDs.isEmpty || emailQueueAccountIDs.first == id,
              !isRunning || changingEmailAccountID == id,
              store.accounts.first(where: { $0.id == id })?.pendingEmailChange?.operationID == operationID
        else { return }
        exitingEmailAccountID = id
        defer { exitingEmailAccountID = nil }
        if isRunning {
            stop()
            while isRunning {
                do { try await Task.sleep(for: .milliseconds(50)) }
                catch { return }
            }
        }
        guard !Task.isCancelled,
              let account = store.accounts.first(where: { $0.id == id }),
              account.pendingEmailChange?.operationID == operationID
        else { return }
        do {
            try store.abandonEmailChange(id: id, operationID: operationID)
            emailChanger?.cancel()
            emailChanger?.browserSession(for: account)?.setOperationMessage(nil)
            accountSessions?.existingAccountSession(for: account)?.setOperationMessage(nil)
            emailQueueAccountIDs.removeAll()
            displayedEmailAccountID = nil
            totalCount = completedCount
            message = "Выход из смены email выполнен. Сохранённый логин и сессия оставлены; остальные действия доступны. Очередь email остановлена."
        } catch {
            message = "Не удалось сохранить выход из смены email. Адреса и этап сохранены; повторите выход."
        }
    }

    func restoreAbandonedEmailChange(id: UUID) {
        guard !isRunning, exitingEmailAccountID == nil, !hasPendingEmailChange, pausedAccountID == nil,
              pausedRotationAccountIDs.isEmpty else { return }
        do {
            try store.restoreAbandonedEmailChange(id: id)
            displayedEmailAccountID = id
            completedCount = 0
            totalCount = 1
            message = "Этап смены email восстановлен. Можно продолжить или проверить новый адрес."
        } catch {
            message = "Не удалось восстановить смену email: логин, алиас или другая операция уже изменились. Сохранённые данные не изменены."
        }
    }

    func verifyPendingEmailChange(id: UUID) async {
        guard !isRunning, exitingEmailAccountID == nil, emailQueueAccountIDs.isEmpty || emailQueueAccountIDs.first == id,
              var change = store.accounts.first(where: { $0.id == id })?.pendingEmailChange,
              change.phase != .reserved else { return }
        do {
            change.phase = .confirming
            try store.checkpointEmailChange(id: id, change: change)
            await continueEmailChange(id: id)
        } catch { message = "Не удалось сохранить этап проверки email." }
    }

    func returnToEmailConfirmation(id: UUID) {
        guard !isRunning, emailQueueAccountIDs.isEmpty || emailQueueAccountIDs.first == id,
              let account = store.accounts.first(where: { $0.id == id && $0.hasPendingEmailChange }) else { return }
        emailChanger?.returnToConfirmation(for: account)
    }

    func startFreshEmailLogin(id: UUID) async {
        guard !isRunning, exitingEmailAccountID == nil, pausedAccountID == nil, pausedRotationAccountIDs.isEmpty,
              emailQueueAccountIDs.isEmpty || emailQueueAccountIDs.first == id,
              let emailChanger,
              let account = store.accounts.first(where: {
                  $0.id == id && $0.pendingEmailChange?.phase == .confirming
              }) else { return }
        guard emailChanger.resetVerificationSession(for: account) else {
            message = "Не удалось открыть новую проверочную сессию. Сохранённая смена email не изменена."
            return
        }
        await continueEmailChange(id: id)
    }

    func replaceEmailAlias(id: UUID, alias: String? = nil) async {
        guard !isRunning, exitingEmailAccountID == nil, pausedAccountID == nil, pausedRotationAccountIDs.isEmpty,
              emailQueueAccountIDs.isEmpty || emailQueueAccountIDs.first == id,
              let emailChanger,
              let account = store.accounts.first(where: { $0.id == id }),
              let change = account.pendingEmailChange,
              account.rotationStage == nil, account.pendingTOTPSecret == nil, !account.hasPendingAccessChange && account.pendingRegistration == nil
        else { return }
        isRunning = true
        isRotating = false
        stopRequested = false
        changingEmailAccountID = id
        displayedEmailAccountID = id
        displayedCheckAccountID = nil
        oauthAccountIDs.remove(id)
        store.selectedID = id
        message = "Замена алиаса: проверяется исходный аккаунт…"
        defer { changingEmailAccountID = nil; isRunning = false }
        do {
            let proof: EmailChangeProof?
            if change.phase == .reserved {
                proof = nil
            } else {
                proof = try await emailChanger.originalIdentityForAliasReplacement(account: account)
            }
            guard !stopRequested, !Task.isCancelled else { throw CancellationError() }
            guard store.accounts.first(where: { $0.id == id })?.pendingEmailChange?.operationID == change.operationID else {
                message = "Операция смены email уже изменилась. Алиас не заменён; проверьте сохранённый этап."
                return
            }
            try store.replaceEmailChangeAlias(id: id, operationID: change.operationID, alias: alias, originalProof: proof)
            if let updated = store.accounts.first(where: { $0.id == id }) {
                emailChanger.resetAfterAliasReplacement(for: updated)
            }
            if emailQueueAccountIDs.isEmpty {
                completedCount = 0
                totalCount = 1
            }
            message = "Алиас заменён. Нажмите «Продолжить смену email», чтобы отправить новый адрес."
        } catch is CancellationError {
            message = "Замена алиаса остановлена. Адреса и этап смены email сохранены."
        } catch AccountStoreError.emailAliasUnavailable {
            message = "Выбранный алиас недоступен. Выберите свободный адрес; прежний алиас и этап сохранены."
        } catch {
            message = "Не удалось безопасно заменить алиас. Подтвердите исходный аккаунт с прежним email и выберите свободный адрес; этап сохранён."
        }
    }

    func check(id: UUID) async {
        await enqueueChecks(ids: [id])
    }

    func checkAll() async {
        await enqueueChecks(ids: store.accounts.map(\.id))
    }

    func checkGroup(groupID: UUID?) async {
        let accounts = groupID.map { store.accounts(in: $0) }
            ?? store.accounts.filter { $0.groupID == nil }
        await enqueueChecks(ids: accounts.map(\.id))
    }

    func resume() async {
        guard !isRunning, !hasPendingEmailChange,
              pausedRotationAccountIDs.isEmpty,
              let resumedAccountID = pausedAccountID,
              !remainingIDs.isEmpty
        else { return }
        pausedAccountID = nil
        message = nil
        stopRequested = false
        isRunning = true
        await runQueue(resumingAccountID: resumedAccountID)
    }

    func rotate2FA(id: UUID) async {
        guard !isRunning, !hasPendingEmailChange,
              pausedAccountID == nil,
              pausedRotationAccountIDs.isEmpty,
              rotator != nil,
              let account = store.accounts.first(where: { $0.id == id })
        else { return }
        guard !account.hasPendingAccessChange && account.pendingRegistration == nil,
              RotationStagePresentation.allowsFreshRotation(stage: account.rotationStage) else {
            message = account.rotationStage.map(RotationStagePresentation.status(for:))
            return
        }
        store.selectedID = id
        await startRotation(accountIDs: [id], concurrency: 1)
    }

    func changeAccess(id: UUID, mode: AccessChangeMode) async {
        store.selectedID = id
        await changeAccess(accountIDs: [id], mode: mode, concurrency: 1)
    }

    func needsNewPasswordConfiguration(for account: AccountRecord, mode: AccessChangeMode) -> Bool {
        configuredPassword == nil && account.pendingPassword == nil && needsPasswordStep(for: account, mode: mode)
    }

    private func needsPasswordStep(for account: AccountRecord, mode: AccessChangeMode) -> Bool {
        (account.pendingAccessChangeMode ?? mode).changesPassword && account.rotationStage == nil &&
            account.accessChangePasswordVerified != true
    }

    func changeAccess(accountIDs: [UUID], mode: AccessChangeMode, concurrency: Int = 1) async {
        guard !isRunning, !hasPendingEmailChange, pausedAccountID == nil,
              rotator != nil, !mode.changesPassword || passwordChanger != nil else { return }
        let requestedIDs = Set(accountIDs)
        guard !store.accounts.contains(where: {
            requestedIDs.contains($0.id) && $0.hasPendingAccessChange && $0.pendingAccessChangeMode != mode
        }) else {
            message = "Сначала завершите незавершённую смену доступов в выбранных аккаунтах: её режим отличается от выбранного."
            return
        }
        if !pausedRotationAccountIDs.isEmpty {
            guard accessChangeMode == mode,
                  let id = accountIDs.first(where: pausedRotationAccountIDs.contains)
            else {
                message = "Сначала продолжите или остановите текущую очередь смены доступов."
                return
            }
            await continueRotation(id: id)
            return
        }
        let eligible = Set(store.accounts.filter {
            $0.rotationStage == nil && $0.pendingTOTPSecret == nil &&
                (!$0.hasPendingAccessChange || $0.pendingAccessChangeMode == mode) && $0.pendingRegistration == nil
        }.map(\.id))
        await startRotation(accountIDs: accountIDs.filter(eligible.contains), concurrency: concurrency, mode: mode)
    }

    func resumeRotation() async {
        guard let id = pausedRotationAccountID else { return }
        await continueRotation(id: id)
    }

    func rotationResumeBlockReason(for id: UUID) -> String? {
        if hasPendingEmailChange { return "Сначала завершите или остановите смену почты." }
        if pausedAccountID != nil { return "Сначала завершите или остановите проверку подписки." }
        if !pausedRotationAccountIDs.isEmpty && !pausedRotationAccountIDs.contains(id) {
            return "Сначала продолжите или остановите приостановленную смену доступов другого аккаунта."
        }
        return nil
    }

    func rotationNeedsNewLogin(for id: UUID) -> Bool {
        guard let browserRecovery,
              let account = store.accounts.first(where: { $0.id == id }),
              let context = recoveryContext(for: id), case .rotation = context,
              !browserRecovery.hasCandidateSession(for: id),
              BrowserRecoveryPolicy.availability(
                context: context, hasTrustedPage: false, hasCandidate: false).freshLoginMode == .manualFactor
        else { return false }

        guard browserRecovery.rotationRecoverySessionState(for: account) == .authenticated,
              let session = browserRecovery.recoverySession(for: account, context: context)
        else { return true }
        return session.needsInitialPageLoad && !session.canReloadTrustedPage
    }

    func continueRotation(id: UUID) async {
        guard !isRunning, rotator != nil else { return }
        if let reason = rotationResumeBlockReason(for: id) {
            message = reason
            return
        }
        if rotationNeedsNewLogin(for: id) {
            store.selectedID = id
            message = Self.missingRotationSessionMessage
            return
        }
        if pausedRotationAccountIDs.contains(id) {
            await resumeRotation(id: id)
            return
        }
        guard pausedRotationAccountIDs.isEmpty,
              let account = store.accounts.first(where: {
                  $0.id == id && ($0.rotationStage != nil || $0.hasPendingAccessChange)
              })
        else { return }
        store.selectedID = id
        await startRotation(accountIDs: [id], concurrency: 1, mode: account.pendingAccessChangeMode ?? .twoFA)
    }

    func stageManuallyConfigured2FA(id: UUID, secret: String) throws {
        guard !isRunning else { throw AccountStoreError.accountBusy }
        guard var account = store.accounts.first(where: { $0.id == id }) else { return }
        try RotationState.stageManuallyConfiguredSecret(secret, in: &account)
        try store.mutate(id: id) { $0 = account }
    }

    func verifyManuallyChangedPassword(id: UUID, password: String? = nil) async {
        guard !isRunning, !hasPendingEmailChange, let account = store.accounts.first(where: { $0.id == id }),
              account.pendingAccessChangeMode?.changesPassword == true, account.rotationStage == nil,
              account.accessChangePasswordVerified != true
        else { return }
        guard let candidate = account.pendingPassword ?? NewPasswordConfiguration.validated(password) ?? configuredPassword else {
            message = NewPasswordConfiguration.unavailableMessage
            return
        }
        do {
            if account.pendingPassword == nil {
                try store.mutate(id: id) { $0.pendingPassword = candidate }
            }
            await continueRotation(id: id)
        } catch { message = "Не удалось сохранить этап проверки пароля." }
    }

    func retryPasswordChange(id: UUID) async {
        guard !isRunning, !hasPendingEmailChange, let account = store.accounts.first(where: { $0.id == id }),
              account.pendingPassword != nil, account.rotationStage == nil else { return }
        passwordChanger?.retryPasswordChange(for: id)
        await continueRotation(id: id)
    }

    func rotate2FA(groupID: UUID, concurrency: Int = 1) async {
        guard !isRunning, !hasPendingEmailChange, pausedAccountID == nil,
              pausedRotationAccountIDs.isEmpty, rotator != nil
        else { return }
        await startRotation(
            accountIDs: store.accounts(in: groupID)
                .filter { !$0.hasPendingAccessChange && $0.pendingRegistration == nil && RotationStagePresentation.allowsFreshRotation(stage: $0.rotationStage) }
                .map(\.id),
            concurrency: concurrency)
    }

    func rotate2FA(accountIDs: [UUID], concurrency: Int = 1) async {
        guard !isRunning, !hasPendingEmailChange, pausedAccountID == nil,
              pausedRotationAccountIDs.isEmpty, rotator != nil
        else { return }
        let eligible = Set(store.accounts.compactMap { account in
            !account.hasPendingAccessChange && account.pendingRegistration == nil && RotationStagePresentation.allowsFreshRotation(stage: account.rotationStage)
                ? account.id
                : nil
        })
        await startRotation(
            accountIDs: accountIDs.filter(eligible.contains),
            concurrency: concurrency)
    }

    func resumeRotation(id: UUID) async {
        guard !isRunning, !hasPendingEmailChange, pausedRotationAccountIDs.contains(id) else { return }
        store.selectedID = id
        isRunning = true
        isRotating = true
        stopRequested = false
        message = nil
        await rotationQueue.resume(accountID: id) { [weak self] accountID in
            guard let self else { return .failed("Coordinator unavailable") }
            return await self.performAccessChangeItem(id: accountID)
        }
        completedCount = rotationQueue.completedCount
        totalCount = rotationQueue.totalCount
        isRunning = false
        isRotating = false
        if let paused = pausedRotationAccountID { store.selectedID = paused }
        message = stopRequested ? "Stopped" : rotationMessage(for: pausedRotationAccountID ?? id)
    }

    func browserSession(for accountID: UUID) -> BrowserSession? {
        guard let account = store.accounts.first(where: { $0.id == accountID }) else { return nil }
        if changingEmailAccountID == accountID || account.hasPendingEmailChange || displayedEmailAccountID == accountID {
            return emailChanger?.browserSession(for: account)
        }
        if oauthAccountIDs.contains(accountID),
           let session = accountSessions?.existingAccountSession(for: account) {
            return session
        }
        if let browserRecovery,
           let context = recoveryContext(for: accountID),
           let session = browserRecovery.recoverySession(for: account, context: context) {
            return session
        }
        if checkingAccountID == accountID || pausedAccountID == accountID ||
            (displayedCheckAccountID == accountID && displayedCheckStoreID == account.browserStoreID) {
            if displayedCheckAccountID == accountID, displayedCheckStoreID == account.browserStoreID,
               displayedCheckProxy == account.proxy, let session = checker.activeSession {
                return session
            }
            return accountSessions?.existingAccountSession(for: account)
        }
        if let state = rotationStates[accountID], state != .queued {
            return rotator?.browserSession(for: account)
        }
        return accountSessions?.existingAccountSession(for: account)
    }

    func openOAuthURL(for id: UUID, text: String, mode: OAuthCallbackMode = .automatic) async -> String? {
        guard !isRunning, !hasPendingEmailChange, pausedAccountID == nil, pausedRotationAccountIDs.isEmpty else {
            return "Завершите или остановите текущую операцию."
        }
        guard let account = store.accounts.first(where: { $0.id == id }) else {
            return "Аккаунт не найден."
        }
        guard account.rotationStage == nil, account.pendingTOTPSecret == nil, !account.hasPendingAccessChange && account.pendingRegistration == nil else {
            return "Сначала завершите смену доступов."
        }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard BrowserAddress.url(from: value) != nil else {
            return "Вставьте полный адрес, начинающийся с https:// или http://."
        }
        guard let accountSessions else {
            return "Не удалось открыть OAuth-ссылку в сессии аккаунта."
        }
        guard !Task.isCancelled else { return "Открытие ссылки остановлено." }
        isRunning = true
        stopRequested = false
        authorizingAccountID = id
        defer {
            authorizingAccountID = nil
            isRunning = false
        }
        let session: BrowserSession
        do {
            session = try await accountSessions.authorizationSession(for: account)
        } catch is CancellationError {
            return "Открытие ссылки остановлено."
        } catch {
            return error.localizedDescription
        }
        guard !stopRequested, !Task.isCancelled else { return "Открытие ссылки остановлено." }
        guard let current = store.accounts.first(where: { $0.id == id }),
              current.credentialLine == account.credentialLine,
              current.browserStoreID == account.browserStoreID, current.proxy == account.proxy,
              current.rotationStage == nil, current.pendingTOTPSecret == nil,
              !current.hasPendingCredentialChange else {
            return "Данные аккаунта изменились. Откройте ссылку заново."
        }
        guard session.openAddress(value, mode: mode) != nil else {
            return "Не удалось открыть OAuth-ссылку в сессии аккаунта."
        }
        displayedEmailAccountID = nil
        oauthAccountIDs.insert(id)
        store.selectedID = id
        session.setVisible(true)
        return nil
    }

    private func recoveryContext(for id: UUID) -> BrowserRecoveryContext? {
        if oauthAccountIDs.contains(id) || pendingEmailAccountIDs.contains(id) { return nil }
        if pausedAccountID == id { return .subscriptionCheck }
        guard let account = store.accounts.first(where: { $0.id == id }) else { return nil }
        if account.hasPendingAccessChange && account.rotationStage == nil { return nil }
        if account.rotationStage != nil { return .rotation(stage: account.rotationStage) }
        if displayedCheckAccountID == id,
           (account.status == .failed || account.status == .needsRecovery)
        {
            return .subscriptionCheck
        }
        if let state = rotationStates[id] {
            switch state {
            case .manualAction, .failed:
                return .rotation(stage: nil)
            case .queued, .running, .complete:
                return nil
            }
        }
        return nil
    }

    func recoveryAvailability(for id: UUID) -> BrowserRecoveryAvailability? {
        guard !isRunning, !hasPendingEmailChange,
              let browserRecovery,
              let account = store.accounts.first(where: { $0.id == id }),
              let context = recoveryContext(for: id)
        else { return nil }
        let session = browserRecovery.recoverySession(for: account, context: context)
        return BrowserRecoveryPolicy.availability(
            context: context,
            hasTrustedPage: session?.canReloadTrustedPage == true,
            hasCandidate: browserRecovery.hasCandidateSession(for: id))
    }

    private func setRecoveryMessage(_ result: BrowserRecoveryResult, account: AccountRecord) {
        switch result {
        case .readyToContinue(let value),
             .manualAction(let value),
             .failure(let value):
            message = redacted(value, account: account)
        }
    }

    func reloadBrowser(for id: UUID) async {
        guard !isRunning, !hasPendingEmailChange,
              let browserRecovery,
              let account = store.accounts.first(where: { $0.id == id }),
              let context = recoveryContext(for: id)
        else { return }
        beginBrowserRecovery(id: id)
        defer { endBrowserRecovery() }
        let result = await browserRecovery.reloadRecoveryPage(for: account, context: context)
        if !stopRequested { setRecoveryMessage(result, account: account) }
    }

    func reopenBrowserSection(for id: UUID) async {
        guard !isRunning, !hasPendingEmailChange,
              let browserRecovery,
              let account = store.accounts.first(where: { $0.id == id }),
              let context = recoveryContext(for: id)
        else { return }
        beginBrowserRecovery(id: id)
        defer { endBrowserRecovery() }
        let result = await browserRecovery.reopenExpectedPage(for: account, context: context)
        if !stopRequested { setRecoveryMessage(result, account: account) }
    }

    func startFreshBrowserLogin(for id: UUID) async {
        guard !isRunning, !hasPendingEmailChange,
              let browserRecovery,
              let account = store.accounts.first(where: { $0.id == id }),
              let context = recoveryContext(for: id)
        else { return }
        if case .rotation = context, let reason = rotationResumeBlockReason(for: id) {
            message = reason
            return
        }
        beginBrowserRecovery(id: id)
        let result = await browserRecovery.startFreshLogin(for: account, context: context)
        endBrowserRecovery()
        guard !stopRequested, !Task.isCancelled else { return }
        setRecoveryMessage(result, account: account)
        guard case .readyToContinue = result else { return }
        switch context {
        case .subscriptionCheck:
            if pausedAccountID == id {
                await resume()
            } else if pausedRotationAccountIDs.isEmpty {
                // Use the replacement just prepared, without creating a third session.
                prepare(ids: [id])
                await runQueue(resumingAccountID: id)
            }
        case .rotation:
            if pausedRotationAccountIDs.contains(id) {
                await resumeRotation(id: id)
            } else if account.rotationStage != nil {
                await continueRotation(id: id)
            } else {
                await rotate2FA(id: id)
            }
        }
    }

    func returnToOriginalBrowserSession(for id: UUID) {
        guard !isRunning, !hasPendingEmailChange,
              let browserRecovery,
              let account = store.accounts.first(where: { $0.id == id }),
              recoveryContext(for: id) != nil
        else { return }
        browserRecovery.returnToOriginalSession(for: account)
        message = "Возвращена исходная сессия."
    }

    private func beginBrowserRecovery(id: UUID) {
        recoveringAccountID = id
        isRunning = true
        stopRequested = false
        message = "Восстановление страницы…"
    }

    private func endBrowserRecovery() {
        recoveringAccountID = nil
        isRunning = false
    }

    func stop() {
        stopRequested = true
        if changingEmailAccountID != nil || !emailQueueAccountIDs.isEmpty {
            emailChanger?.cancel()
            message = "Смена email останавливается; резерв и этап сохраняются."
            return
        }
        if let id = authorizingAccountID {
            if let account = store.accounts.first(where: { $0.id == id }) {
                accountSessions?.existingAccountSession(for: account)?.cancelLoading()
            }
            message = "Открытие ссылки остановлено."
        } else if let id = recoveringAccountID {
            browserSession(for: id)?.cancelLoading()
            message = "Восстановление остановлено."
        } else if (isRunning && isRotating) || !pausedRotationAccountIDs.isEmpty {
            rotationQueue.cancel()
            rotator?.cancelActiveOperation()
            message = "Stopping…"
        } else if isRunning {
            remainingIDs.removeAll()
            finishCheckQueueWaiters()
            checker.cancelActiveOperation()
        }
        if !isRunning {
            pausedAccountID = nil
            remainingIDs.removeAll()
            checkQueueActive = false
            checkQueueAccountIDs.removeAll()
            finishCheckQueueWaiters()
            message = "Stopped"
        }
        for account in store.accounts where account.hasPendingAccessChange &&
            account.pendingPassword == nil && account.rotationStage == nil {
            do {
                try store.mutate(id: account.id) {
                    $0.pendingAccessChange = nil
                    $0.accessChangePasswordVerified = nil
                    if $0.status == .needsRecovery { $0.status = .unchecked }
                    $0.lastError = nil
                }
                passwordChanger?.resetPasswordChange(for: account.id)
            } catch { message = "Не удалось сохранить остановку смены пароля." }
        }
    }

    private func isEligibleForCheck(_ account: AccountRecord) -> Bool {
        !account.hasPendingCredentialChange && account.rotationStage == nil && account.pendingTOTPSecret == nil
    }

    private func enqueueChecks(ids: [UUID]) async {
        guard canEnqueueChecks, !Task.isCancelled else { return }
        var seen: Set<UUID> = []
        let eligibleIDs = Set(store.accounts.filter { isEligibleForCheck($0) }.map(\.id))
        let validIDs = ids.filter { id in
            seen.insert(id).inserted && eligibleIDs.contains(id)
        }
        if isRunning {
            if appendChecks(ids: validIDs) { await waitForCheckQueue() }
            return
        }
        prepare(ids: validIDs)
        await runQueue()
    }

    private func appendChecks(ids: [UUID]) -> Bool {
        var joined = false
        var rejected = 0
        for id in ids {
            if checkQueueAccountIDs.contains(id) {
                joined = true
            } else if remainingIDs.count < maximumPendingChecks + 1 {
                remainingIDs.append(id)
                checkQueueAccountIDs.insert(id)
                totalCount += 1
                joined = true
            } else {
                rejected += 1
            }
        }
        if rejected > 0 {
            checkQueueOverflowed = true
            message = "Очередь проверки заполнена: максимум \(maximumPendingChecks) ожидающих. Не добавлено аккаунтов: \(rejected). Повторите запрос после завершения очереди."
        }
        return joined
    }

    private func waitForCheckQueue() async {
        let waiterID = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                guard checkQueueActive, isRunning, !stopRequested, !Task.isCancelled else {
                    continuation.resume()
                    return
                }
                checkQueueWaiters[waiterID] = continuation
            }
        } onCancel: { [weak self] in
            Task { @MainActor in
                self?.checkQueueWaiters.removeValue(forKey: waiterID)?.resume()
            }
        }
    }

    private func finishCheckQueueWaiters() {
        let waiters = Array(checkQueueWaiters.values)
        checkQueueWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    private func prepare(ids: [UUID]) {
        displayedEmailAccountID = nil
        remainingIDs.removeAll()
        checkQueueAccountIDs.removeAll()
        checkQueueOverflowed = false
        stopRequested = false
        completedCount = 0
        totalCount = 0
        pausedAccountID = nil
        isRotating = false
        message = ids.isEmpty ? "No accounts to check" : nil
        _ = appendChecks(ids: ids)
        isRunning = !remainingIDs.isEmpty
        checkQueueActive = isRunning
    }

    private func startRotation(accountIDs: [UUID], concurrency: Int, mode: AccessChangeMode = .twoFA) async {
        var seen: Set<UUID> = []
        let validIDs = accountIDs.filter { id in
            seen.insert(id).inserted && store.accounts.contains(where: { $0.id == id })
        }
        guard !validIDs.isEmpty else {
            message = "Нет аккаунтов для новой смены доступов"
            return
        }
        let validIDSet = Set(validIDs)
        guard !store.accounts.contains(where: { validIDSet.contains($0.id) && needsNewPasswordConfiguration(for: $0, mode: mode) }) else {
            message = NewPasswordConfiguration.unavailableMessage
            return
        }
        displayedEmailAccountID = nil
        accessChangeMode = mode
        displayedCheckAccountID = nil
        oauthAccountIDs.subtract(validIDs)
        for account in store.accounts where validIDs.contains(account.id) {
            accountSessions?.existingAccountSession(for: account)?.endOAuth()
        }

        isRunning = true
        isRotating = true
        stopRequested = false
        completedCount = 0
        totalCount = validIDs.count
        pausedAccountID = nil
        message = nil
        await rotationQueue.start(
            accountIDs: validIDs,
            concurrency: min(concurrency, maximumRotationConcurrency)) { [weak self] id in
                guard let self else { return .failed("Coordinator unavailable") }
                return await self.performAccessChangeItem(id: id)
            }
        completedCount = rotationQueue.completedCount
        totalCount = rotationQueue.totalCount
        isRunning = false
        isRotating = false
        if stopRequested {
            message = "Stopped"
        } else if let paused = pausedRotationAccountID {
            message = rotationMessage(for: paused)
        } else {
            if let lastID = validIDs.last,
               store.accounts.contains(where: { $0.id == lastID }) {
                // A finished batch leaves the last processed account selected.
                store.selectedID = lastID
            }
            message = mode == .twoFA ? "2FA rotation batch complete" : "Смена доступов завершена"
        }
    }

    private func performAccessChangeItem(id: UUID) async -> RotationQueueItemState {
        guard var account = store.accounts.first(where: { $0.id == id }), !stopRequested else {
            return .failed("Stopped")
        }
        let mode = account.pendingAccessChangeMode ?? accessChangeMode
        guard !needsNewPasswordConfiguration(for: account, mode: mode) else {
            return .failed(NewPasswordConfiguration.unavailableMessage)
        }
        do {
            account = try await accountWithCheckedProxy(account)
        } catch is CancellationError {
            return .failed("Stopped")
        } catch {
            let text = proxyPreflightMessage(error)
            try? store.mutate(id: id) { $0.status = .failed; $0.lastError = text }
            return .failed(text)
        }
        // Prepare only the current account. Waiting accounts have no live operation browser.
        rotator?.prepareBrowserSession(for: account)
        store.selectedID = id
        if needsPasswordStep(for: account, mode: mode), let newPassword = account.pendingPassword ?? configuredPassword {
            guard let passwordChanger else { return .failed("Смена пароля недоступна") }
            let alreadyConfigured = account.password == newPassword && account.pendingPassword == nil
            do {
                try store.mutate(id: id) {
                    $0.pendingAccessChange = mode
                    if alreadyConfigured { $0.accessChangePasswordVerified = true }
                    $0.status = .needsRecovery
                    $0.lastError = nil
                }
            } catch { return .failed("Не удалось сохранить этап смены пароля") }
            if !alreadyConfigured {
                rotator?.prepareBrowserSession(for: account)
                if let session = rotator?.browserSession(for: account),
                   !(await session.waitUntilAttached(seconds: 3)) {
                    let text = "Браузер аккаунта не успел открыться. Продолжите смену доступов."
                    try? store.mutate(id: id) { $0.lastError = text }
                    return .manualAction(text)
                }
                let outcome = await passwordChanger.changePassword(
                    account: account,
                    newPassword: newPassword
                ) { [weak self] in
                    guard let self, !self.stopRequested, !Task.isCancelled else { throw CancellationError() }
                    try self.store.mutate(id: id) { $0.pendingPassword = newPassword }
                }
                switch outcome {
                case .success(let email):
                    guard email.caseInsensitiveCompare(account.email) == .orderedSame else {
                        let message = "Проверочный вход выполнен в другой аккаунт. Пароль не сохранён."
                        try? store.mutate(id: id) {
                            guard $0.hasPendingAccessChange else { return }
                            $0.status = .needsRecovery
                            $0.lastError = message
                        }
                        return .failed(message)
                    }
                    do {
                        try store.mutate(id: id) {
                            $0.password = newPassword
                            $0.pendingPassword = nil
                            $0.accessChangePasswordVerified = true
                            $0.lastError = nil
                        }
                    } catch { return .failed("Новый пароль проверен, но не сохранён. Продолжите смену доступов.") }
                case .manualActionRequired(let message):
                    store.selectedID = id
                    let text = redacted(message, account: account, additionalSecret: newPassword)
                    try? store.mutate(id: id) {
                        guard $0.hasPendingAccessChange else { return }
                        $0.status = .needsRecovery
                        $0.lastError = text
                    }
                    return stopRequested ? .failed("Stopped") : .manualAction(text)
                case .failure(let message):
                    let text = redacted(message, account: account, additionalSecret: newPassword)
                    try? store.mutate(id: id) {
                        guard $0.hasPendingAccessChange else { return }
                        $0.status = .needsRecovery
                        $0.lastError = text
                    }
                    return .failed(text)
                }
            }
            guard !stopRequested else { return .failed("Stopped") }
        }
        let result: RotationQueueItemState
        if mode.changesTwoFA {
            result = await performRotationItem(id: id)
        } else {
            result = .complete
        }
        if result == .complete, mode.changesPassword {
            do {
                try store.mutate(id: id) {
                    $0.pendingAccessChange = nil
                    $0.accessChangePasswordVerified = nil
                    $0.status = .ready
                    $0.lastError = nil
                }
            } catch { return .failed("Доступы проверены, но завершение не сохранено") }
        }
        return result
    }

    private func performRotationItem(id: UUID) async -> RotationQueueItemState {
        guard !stopRequested else { return .failed("Stopped") }
        guard let rotator,
              let account = store.accounts.first(where: { $0.id == id })
        else { return .failed("Account no longer exists") }

        rotator.prepareBrowserSession(for: account)
        if let session = rotator.browserSession(for: account),
           !(await session.waitUntilAttached(seconds: 3))
        {
            return .failed("Браузер аккаунта не успел открыться")
        }
        var outcome = await rotator.rotate2FA(account: account) { [weak self] event in
            guard let self else { return }
            try self.applyRotationCheckpoint(id: id, event: event)
        }
        if stopRequested {
            // Keep a proven success; otherwise cancellation must not leave a
            // manual pause that blocks every subsequent account operation.
            if case .success = outcome {} else {
                outcome = .failure(stage: nil, message: "Stopped")
            }
        }

        switch outcome {
        case .success(let snapshot, let proof):
            do {
                guard var verified = store.accounts.first(where: { $0.id == id }) else {
                    throw RotationVerificationError.identityOrSecretMissing
                }
                try RotationState.markCleanLoginVerified(
                    signedInEmail: snapshot.signedInEmail,
                    proof: proof,
                    in: &verified)
                verified.planLabel = snapshot.planLabel
                verified.subscriptionDate = snapshot.activeUntil
                verified.subscriptionDateKind = snapshot.dateKind
                verified.lastCheckedAt = Date()
                try store.mutate(id: id) { $0 = verified }
                return .complete
            } catch {
                if let current = store.accounts.first(where: { $0.id == id }) {
                    try? store.mutate(id: id) {
                        $0.status = .needsRecovery
                        $0.lastError = "Clean login could not be verified."
                    }
                    return .failed(redacted(
                        "Clean login could not be verified.",
                        account: current))
                }
                return .failed("Clean login could not be verified.")
            }

        case .manualActionRequired(_, let manualMessage):
            if let current = store.accounts.first(where: { $0.id == id }),
               current.rotationStage != nil {
                try? store.mutate(id: id) {
                    $0.status = .needsRecovery
                    $0.lastError = nil
                }
            }
            store.selectedID = id
            return .manualAction(redacted(manualMessage, account: account))

        case .failure(_, let failureMessage):
            if let current = store.accounts.first(where: { $0.id == id }) {
                try? store.mutate(id: id) {
                    $0.status = $0.rotationStage == nil ? .failed : .needsRecovery
                    $0.lastError = redacted(failureMessage, account: current)
                }
            }
            return .failed(redacted(failureMessage, account: account))
        }
    }

    private func rotationMessage(for id: UUID) -> String {
        guard let state = rotationQueue.states[id] else { return "Требуется ручное действие" }
        switch state {
        case .manualAction(let value), .failed(let value): return value
        case .complete: return "2FA rotation complete"
        case .queued: return "2FA rotation queued"
        case .running: return "2FA rotation running"
        }
    }

    private func applyRotationCheckpoint(id: UUID, event: RotationCheckpointEvent) throws {
        try store.mutate(id: id) { account in
            switch event {
            case .removalStarted:
                RotationState.markRemovalStarted(in: &account)
            case .oldMethodDisabled:
                RotationState.markOldMethodDisabled(in: &account)
            case .secretCaptured(let secret):
                RotationState.capture(secret: secret, in: &account)
            case .setupConfirmed:
                RotationState.markSetupConfirmed(in: &account)
            }
        }
    }

    private func runQueue(resumingAccountID: UUID? = nil) async {
        defer {
            checkQueueActive = pausedAccountID != nil && !remainingIDs.isEmpty
            if !checkQueueActive { checkQueueAccountIDs.removeAll() }
            finishCheckQueueWaiters()
        }
        var tokenReadFailures = 0
        var tokenSaveFailures = 0
        var tokenExportFailed = false
        while let id = remainingIDs.first {
            if stopRequested || Task.isCancelled {
                remainingIDs.removeAll()
                isRunning = false
                message = "Stopped"
                return
            }

            guard var account = store.accounts.first(where: { $0.id == id }),
                  isEligibleForCheck(account) else {
                remainingIDs.removeFirst()
                completedCount += 1
                checkingAccountID = nil
                continue
            }

            oauthAccountIDs.remove(id)
            checkingAccountID = id
            store.selectedID = id
            do {
                account = try await accountWithCheckedProxy(account)
            } catch is CancellationError {
                remainingIDs.removeAll()
                checkingAccountID = nil
                isRunning = false
                message = "Stopped"
                return
            } catch {
                let text = proxyPreflightMessage(error)
                try? store.mutate(id: id) { $0.status = .failed; $0.lastError = text }
                pausedAccountID = id
                checkingAccountID = nil
                isRunning = false
                message = text
                return
            }
            guard !stopRequested, !Task.isCancelled else {
                remainingIDs.removeAll()
                checkingAccountID = nil
                isRunning = false
                message = "Stopped"
                return
            }
            guard store.accounts.first(where: { $0.id == id }) == account,
                  isEligibleForCheck(account) else {
                remainingIDs.removeFirst()
                completedCount += 1
                checkingAccountID = nil
                continue
            }
            let resumesExistingSession = id == resumingAccountID && displayedCheckAccountID == id
                && displayedCheckStoreID == account.browserStoreID && displayedCheckProxy == account.proxy
            displayedCheckAccountID = id
            displayedCheckStoreID = account.browserStoreID
            displayedCheckProxy = account.proxy
            do {
                try store.mutate(id: id) {
                    $0.status = .checking
                    $0.lastError = nil
                }
            } catch {
                remainingIDs.removeFirst()
                completedCount += 1
                checkingAccountID = nil
                message = "Could not save account state"
                continue
            }

            let checkedAccount = store.accounts.first(where: { $0.id == id })
            let outcome = if resumesExistingSession {
                await checker.continueCheck(account: account)
            } else {
                await checker.check(account: account)
            }
            if stopRequested || Task.isCancelled {
                if let checkedAccount, store.accounts.first(where: { $0.id == id }) == checkedAccount {
                    try? store.mutate(id: id) {
                        $0.status = account.status
                        $0.lastError = account.lastError
                        $0.lastCheckedAt = account.lastCheckedAt
                    }
                }
                remainingIDs.removeAll()
                checkingAccountID = nil
                isRunning = false
                message = "Stopped"
                return
            }
            guard let checkedAccount, store.accounts.first(where: { $0.id == id }) == checkedAccount else {
                remainingIDs.removeFirst()
                completedCount += 1
                checkingAccountID = nil
                tokenSaveFailures += 1
                continue
            }
            switch outcome {
            case .success(let snapshot):
                if snapshot.signedInEmail.caseInsensitiveCompare(account.email) == .orderedSame {
                    var token: String?
                    var tokenReadFailed = false
                    do { token = try await checker.accessTokenAfterCheck(for: account) }
                    catch is CancellationError {
                        if !stopRequested && !Task.isCancelled { tokenReadFailed = true }
                    } catch { tokenReadFailed = true }
                    if stopRequested || Task.isCancelled {
                        if store.accounts.first(where: { $0.id == id }) == checkedAccount {
                            try? store.mutate(id: id) {
                                $0.status = account.status
                                $0.lastError = account.lastError
                                $0.lastCheckedAt = account.lastCheckedAt
                            }
                        }
                        remainingIDs.removeAll()
                        checkingAccountID = nil
                        isRunning = false
                        message = "Stopped"
                        return
                    }
                    // Never attach an awaited token to an edited or replaced account.
                    guard store.accounts.first(where: { $0.id == id }) == checkedAccount,
                          checkedAccount.email == account.email,
                          checkedAccount.password == account.password,
                          checkedAccount.totpSecret == account.totpSecret,
                          checkedAccount.browserStoreID == account.browserStoreID,
                          checkedAccount.proxy == account.proxy,
                          !checkedAccount.hasPendingCredentialChange,
                          checkedAccount.rotationStage == nil, checkedAccount.pendingTOTPSecret == nil
                    else {
                        remainingIDs.removeFirst()
                        completedCount += 1
                        checkingAccountID = nil
                        tokenSaveFailures += 1
                        continue
                    }
                    if let value = token, !AccessTokenExport.isValidField(value) {
                        token = nil
                        tokenReadFailed = true
                    }
                    if token == nil || tokenReadFailed { tokenReadFailures += 1 }
                    do {
                        try store.mutate(id: id) {
                            $0.planLabel = snapshot.planLabel
                            $0.subscriptionDate = snapshot.activeUntil
                            $0.subscriptionDateKind = snapshot.dateKind
                            $0.lastCheckedAt = Date()
                            $0.status = .ready
                            $0.lastError = nil
                            if let token { $0.accessToken = token }
                        }
                        do { _ = try store.writeRegistrationAccessTokenExport() }
                        catch { tokenExportFailed = true }
                    } catch {
                        tokenSaveFailures += 1
                    }
                } else {
                    try? markFailed(id: id, account: account,
                                    message: "Signed-in account does not match the selected account.")
                }
                remainingIDs.removeFirst()
                completedCount += 1
                checkingAccountID = nil

            case .failure(let failureMessage):
                try? markFailed(id: id, account: account, message: failureMessage)
                remainingIDs.removeFirst()
                completedCount += 1
                checkingAccountID = nil

            case .manualActionRequired(let manualMessage):
                try? store.mutate(id: id) {
                    $0.status = .checking
                    $0.lastError = nil
                }
                pausedAccountID = id
                checkingAccountID = nil
                message = redacted(manualMessage, account: account)
                isRunning = false
                return
            }
        }

        isRunning = false
        checkingAccountID = nil
        pausedAccountID = nil
        message = totalCount == 0 ? "No accounts to check" : "Check complete"
        if tokenReadFailures > 0 { message? += ". Не удалось обновить accessToken: \(tokenReadFailures). Сохранённый кэш оставлен." }
        if tokenSaveFailures > 0 { message? += ". Не удалось сохранить результат проверки: \(tokenSaveFailures)." }
        if tokenExportFailed { message? += ". Не удалось обновить файл new-novoreg-access-tokens.txt." }
        if checkQueueOverflowed { message? += ". Часть запросов не добавлена: очередь достигла лимита \(maximumPendingChecks) ожидающих. Повторите запрос." }
    }

    private func accountWithCheckedProxy(_ account: AccountRecord) async throws -> AccountRecord {
        try Task.checkCancellation()
        guard !stopRequested else { throw CancellationError() }
        // Recovery keeps the route on which a credential change may already have happened.
        guard let proxyStore, let current = account.proxy,
              account.rotationStage == nil, account.pendingTOTPSecret == nil,
              !account.hasPendingCredentialChange else { return account }
        let replacement: AccountProxy?
        do {
            replacement = try await proxyStore.checkedProxy(replacing: current)
        } catch {
            if stopRequested || Task.isCancelled { throw CancellationError() }
            throw error
        }
        try Task.checkCancellation()
        guard !stopRequested else { throw CancellationError() }
        guard let replacement, replacement != current else { return account }
        return try store.replaceAccountProxy(id: account.id, expectedProxy: current, proxy: replacement)
    }

    private func proxyPreflightMessage(_ error: Error) -> String {
        (error as? ProxyStoreError)?.errorDescription
            ?? "Не удалось проверить или сохранить прокси. Повторите попытку."
    }

    private func markFailed(id: UUID, account: AccountRecord, message: String) throws {
        try store.mutate(id: id) {
            $0.status = .failed
            $0.lastCheckedAt = Date()
            $0.lastError = redacted(message, account: account)
        }
    }

    private func redacted(_ value: String, account: AccountRecord, additionalSecret: String? = nil) -> String {
        var result = value
        let secrets = [account.email, account.password, account.totpSecret, account.pendingTOTPSecret,
                       account.pendingPassword, configuredPassword, additionalSecret]
        for secret in secrets.compactMap({ $0 }).sorted(by: { $0.count > $1.count }) where !secret.isEmpty {
            result = result.replacingOccurrences(of: secret, with: "[redacted]")
        }
        return String(result.prefix(240))
    }
}
