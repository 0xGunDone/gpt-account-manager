import AppKit
import SwiftUI
import UniformTypeIdentifiers

private enum PendingDeletion: Identifiable {
    case account(UUID)
    case group(UUID, accountCount: Int)

    var id: String {
        switch self {
        case .account(let id): "account-\(id)"
        case .group(let id, _): "group-\(id)"
        }
    }
}

private struct PendingAccessChange: Identifiable {
    let id = UUID()
    let accountIDs: [UUID]
    let title: String
}

private struct PendingAccountMove: Identifiable {
    let id = UUID()
    let accountIDs: Set<UUID>
    let destinationGroupID: UUID?
}

enum GroupAccessTokenCopy {
    static func isEligible(_ account: AccountRecord) -> Bool {
        account.status == .ready && !account.hasPendingCredentialChange &&
            account.rotationStage == nil && account.pendingTOTPSecret == nil
    }

    static func currentAccounts(from snapshot: [AccountRecord], in accounts: [AccountRecord]) -> [AccountRecord] {
        // ponytail: group-sized scan; index by UUID if large groups make this measurable.
        snapshot.compactMap { original in
            accounts.first {
                $0.id == original.id && $0.email == original.email &&
                    $0.browserStoreID == original.browserStoreID && $0.proxy == original.proxy &&
                    $0.password == original.password && $0.totpSecret == original.totpSecret &&
                    $0.groupID == original.groupID && isEligible($0)
            }
        }
    }
}

struct ContentView: View {
    let mailbox: MailRuMailbox
    @Environment(\.openWindow) private var openWindow
    @State private var showEmailAliases = false
    @State private var store: AccountStore
    @State private var coordinator: OperationCoordinator
    @State private var codexImporter: CodexAccImportCoordinator
    @State private var registration: RegistrationCoordinator
    @State private var accessTokenBrowser: ChatGPTAutomation
    @State private var accessTokenCopying = false
    @State private var accessTokenTask: Task<Void, Never>?
    @State private var accessTokenMessage: String?
    @State private var accessTokenMount: BrowserMount?
    @State private var safariHandoffInProgress = false
    @State private var tokenExportAccounts: [AccountRecord]?
    @State private var showAccountTrash = false
    @State private var proxies: ProxyStore
    @State private var showRegistration = false
    @State private var showProxies = false
    @State private var proxySwitchAccountID: UUID?
    @State private var proxySwitchMessage: String?
    @State private var showImport = false
    @State private var showExport = false
    @State private var importSummary: String?
    @State private var showPlaintextWarning = false
    @State private var didLoad = false
    @State private var pendingFreshLoginID: UUID?
    @State private var showTextImport = false
    @State private var directImportText = ""
    @State private var directImportError: String?
    @State private var directImportFilename: String?
    @State private var importSeparatorChoice: ImportSeparatorChoice = .automatic
    @State private var customImportSeparator = ""
    @State private var sidebarSelection: SidebarSelection?
    @State private var selectedAccountIDs: Set<UUID> = []
    @State private var showNewGroup = false
    @State private var pendingDeletion: PendingDeletion?
    @State private var pendingAccessChange: PendingAccessChange?
    @State private var pendingAccountMove: PendingAccountMove?
    @AppStorage("acknowledgedPlaintextStorage")
    private var acknowledgedPlaintextStorage = false

    init(mailbox: MailRuMailbox, proxies: ProxyStore) {
        self.mailbox = mailbox
        let store = AccountStore()
        let sessions = WebSessionManager(proxyResolver: { !proxies.isLoaded || proxies.isEnabled ? $0.proxy : nil })
        let browser = ChatGPTAutomation(sessionManager: sessions, passwordMailbox: mailbox)
        _accessTokenBrowser = State(initialValue: browser)
        _store = State(initialValue: store)
        _coordinator = State(initialValue: OperationCoordinator(
            store: store,
            checker: browser,
            rotator: browser,
            browserRecovery: browser,
            accountSessions: browser,
            emailChanger: EmailChangeAutomation(browser: browser, mailbox: mailbox),
            proxyStore: proxies))
        _codexImporter = State(initialValue: CodexAccImportCoordinator(
            browser: browser, onSelect: { store.selectedID = $0 }))
        _registration = State(initialValue: RegistrationCoordinator(
            store: store, browser: ChatGPTAutomation(sessionManager: sessions), mailbox: mailbox,
            proxyStore: proxies))
        _proxies = State(initialValue: proxies)
    }

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        .overlay(alignment: .topLeading) {
            BackgroundBrowserPool(mounts: backgroundBrowserMounts)
        }
        .toolbar { toolbar }
        .sheet(isPresented: $showRegistration) {
            RegistrationPanel(store: store, registration: registration, proxies: proxies,
                              canStart: !otherOperationBlocked && !proxies.isChecking && !proxies.isRefreshing,
                              onClose: { showRegistration = false },
                              onReplaceProxy: { id in Task { await replaceProxy(for: id) } },
                              proxyActionMessage: proxySwitchMessage)
                .onChange(of: registration.isRunning) { _, running in
                    if running { proxySwitchMessage = nil }
                }
        }
        .sheet(isPresented: $showProxies) {
            ProxySettingsView(store: proxies, canEdit: !operationBlocked && proxies.isLoaded,
                              onClose: { showProxies = false })
        }
        .sheet(isPresented: $showEmailAliases) {
            EmailAliasesView(store: store, onClose: { showEmailAliases = false },
                             markingUsedDisabled: registration.isRunning || registration.hasPendingBatch)
        }
        .sheet(isPresented: Binding(get: { tokenExportAccounts != nil }, set: { if !$0 { tokenExportAccounts = nil } })) {
            if let snapshot = tokenExportAccounts {
                AccountTokenExportSheet(accounts: snapshot,
                    currentAccounts: { GroupAccessTokenCopy.currentAccounts(from: snapshot, in: store.accounts) },
                    forbiddenDirectory: store.fileURL.deletingLastPathComponent(),
                    onClose: { tokenExportAccounts = nil })
            }
        }
        .sheet(isPresented: $showAccountTrash) {
            AccountTrashView(store: store, protectedIDs: protectedAccountIDs,
                             actionsDisabled: operationBlocked, onClose: { showAccountTrash = false })
        }
        .fileImporter(
            isPresented: $showImport,
            allowedContentTypes: [.plainText],
            allowsMultipleSelection: false,
            onCompletion: importFile)
        .sheet(isPresented: $showTextImport) {
            DirectTextImportSheet(
                text: $directImportText,
                separatorChoice: $importSeparatorChoice,
                customSeparator: $customImportSeparator,
                filename: directImportFilename,
                errorMessage: directImportError,
                onCancel: {
                    directImportText = ""
                    directImportError = nil
                    directImportFilename = nil
                    showTextImport = false
                },
                onImport: importDirectText)
        }
        .sheet(isPresented: $showNewGroup) {
            NewGroupSheet(
                onCreate: { name in
                    try store.createGroup(name: name, tag: nil)
                },
                onCreated: { group in
                    sidebarSelection = .group(group.id)
                })
        }
        .fileExporter(
            isPresented: $showExport,
            document: CredentialTextDocument(text: ImportExportService.serialize(store.accounts)),
            contentType: .plainText,
            defaultFilename: "chatgpt-accounts") { result in
                if case .failure = result {
                    importSummary = "Не удалось сохранить файл экспорта."
                }
            }
        .alert("GPT Account Manager", isPresented: summaryBinding) {
            Button("OK") { importSummary = nil }
        } message: {
            Text(importSummary ?? "")
        }
        .sheet(item: $pendingAccessChange) { request in
            AccessChangeSheet(
                title: request.title,
                accountCount: request.accountIDs.count,
                passwordSetupRequired: store.accounts.contains {
                    request.accountIDs.contains($0.id) && coordinator.needsNewPasswordConfiguration(for: $0, mode: .password)
                },
                onCancel: { pendingAccessChange = nil },
                onStart: { mode in
                    pendingAccessChange = nil
                    Task {
                        guard !operationBlocked else { return }
                        await coordinator.changeAccess(
                            accountIDs: request.accountIDs,
                            mode: mode)
                    }
                })
        }
        .confirmationDialog(
            deletionTitle,
            isPresented: pendingDeletionBinding,
            titleVisibility: .visible) {
                Button(deletionButtonTitle, role: .destructive) {
                    confirmDeletion()
                }
                Button("Отмена", role: .cancel) {
                    pendingDeletion = nil
                }
            } message: {
                Text(deletionMessage)
            }
        .confirmationDialog(
            accountMoveTitle,
            isPresented: pendingAccountMoveBinding,
            titleVisibility: .visible) {
                Button("Переместить") {
                    confirmAccountMove()
                }
                Button("Отмена", role: .cancel) {
                    pendingAccountMove = nil
                }
            } message: {
                Text(accountMoveMessage)
            }
        .confirmationDialog(
            "Открыть новую сессию входа?",
            isPresented: Binding(
                get: { pendingFreshLoginID != nil },
                set: { if !$0 { pendingFreshLoginID = nil } }),
            titleVisibility: .visible
        ) {
            if let id = pendingFreshLoginID {
                Button("Открыть новый вход") {
                    pendingFreshLoginID = nil
                    Task { await coordinator.startFreshBrowserLogin(for: id) }
                }
            }
            Button("Отмена", role: .cancel) { pendingFreshLoginID = nil }
        } message: {
            let warning = pendingFreshLoginID
                .flatMap { coordinator.recoveryAvailability(for: $0)?.warning }
                ?? "Текущая сессия останется доступна, пока новая не подтверждена."
            Text(warning)
        }
        .onChange(of: sidebarSelection) { _, selection in
            accessTokenTask?.cancel()
            accessTokenMessage = nil
            let selectedID = SidebarSelectionSynchronization.selectedID(for: selection)
            guard store.selectedID != selectedID else { return }
            store.selectedID = selectedID
        }
        .onChange(of: store.selectedID) { _, id in
            let selection = SidebarSelectionSynchronization.sidebarSelection(
                for: id,
                preserving: sidebarSelection)
            guard sidebarSelection != selection else { return }
            sidebarSelection = selection
        }
        .onDisappear { accessTokenTask?.cancel() }
        .task {
            guard !didLoad else { return }
            didLoad = true
            mailbox.ensureLoaded()
            openWindow(id: "mailbox")
            do {
                try store.load()
            } catch {
                importSummary = "Не удалось прочитать локальный accounts.json."
                return
            }
            do {
                if !proxies.isLoaded {
                    try proxies.load(initiallyEnabled: store.accounts.contains(where: { $0.proxy != nil }))
                }
            }
            catch {
                importSummary = "Не удалось загрузить список прокси. Проверьте раздел «Прокси»."
                return
            }
            if !acknowledgedPlaintextStorage {
                showPlaintextWarning = true
            }
            do {
                if let groupID = try PasswordGroupLaunch.claim() {
                    guard !operationBlocked, acknowledgedPlaintextStorage else {
                        importSummary = "Сначала завершите текущую операцию или подтвердите локальное хранение."
                        return
                    }
                    let ids = try PasswordGroupLaunch.accountIDs(groupID: groupID, store: store)
                    if let id = ids.first {
                        store.selectedID = id
                        sidebarSelection = .account(id)
                    }
                    await Task.yield()
                    await coordinator.changeAccess(accountIDs: ids, mode: .password)
                    PasswordGroupLaunch.recordResult(groupID: groupID, ids: ids, store: store, coordinator: coordinator)
                }
            } catch {
                importSummary = error.localizedDescription
            }
        }
    }

    private var sidebar: some View {
        AccountSidebarView(
            store: store,
            selection: $sidebarSelection,
            selectedAccountIDs: $selectedAccountIDs,
            rotationStates: coordinator.rotationStates,
            onCreateGroup: { showNewGroup = true },
            onRequestMoveAccounts: { ids, groupID in
                requestAccountMove(ids: ids, to: groupID)
            })
        .alert("Локальное хранение", isPresented: $showPlaintextWarning) {
            Button("Понимаю") {
                acknowledgedPlaintextStorage = true
            }
        } message: {
            Text("Логины, пароли и 2FA-ключи хранятся без шифрования в accounts.json и доступны текущему пользователю macOS.")
        }
    }

    private var backgroundBrowserMounts: [BrowserMount] {
        let rotationIDs = coordinator.activeRotationAccountIDs
            .union(coordinator.pausedRotationAccountIDs)
            .union(coordinator.pendingEmailAccountIDs)
            .union(codexImporter.protectedAccountIDs)
        let selectedID: UUID? = {
            guard case .account(let id) = sidebarSelection else { return nil }
            return id
        }()

        var mounts = store.accounts.compactMap { account -> BrowserMount? in
            guard rotationIDs.contains(account.id),
                  account.id != selectedID,
                  let session = codexImporter.browserSession(for: account.id) ?? coordinator.browserSession(for: account.id)
            else { return nil }
            return BrowserMount(id: account.id, session: session)
        }
        if let mount = accessTokenMount,
           !mounts.contains(where: { $0.session === mount.session }),
           !(selectedID == mount.id &&
             (codexImporter.browserSession(for: mount.id) ?? coordinator.browserSession(for: mount.id)) === mount.session) {
            mounts.append(mount)
        }
        return mounts
    }

    @ViewBuilder
    private var detail: some View {
        if case .account(let id) = sidebarSelection,
           let account = store.accounts.first(where: { $0.id == id }) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    AccountDetailView(
                        account: account,
                        groups: store.groups,
                        actionsDisabled: operationBlocked,
                        checkDisabled: subscriptionCheckBlocked,
                        isProtected: protectedAccountIDs.contains(account.id),
                        deletionDisabled: protectedAccountIDs.contains(account.id) &&
                            !registration.canDeleteBlockedAccount(id: account.id, protectedIDs: nonRegistrationProtectedAccountIDs),
                        recoveryActionsDisabled: coordinator.isRunning || codexImportBlocked || accessTokenCopying,
                        passwordSetupRequired: coordinator.needsNewPasswordConfiguration(for: account, mode: .twoFA),
                        isRotationPaused: coordinator.pausedRotationAccountIDs.contains(account.id),
                        credentialsEditable:
                            !protectedAccountIDs.contains(account.id) &&
                            account.rotationStage == nil &&
                            account.pendingTOTPSecret == nil && !account.hasPendingCredentialChange,
                        rotationState: coordinator.rotationStates[account.id],
                        onSaveCredentials: { text in
                            do {
                                let credential = try ImportExportService
                                    .parseCredentialLine(text)
                                try store.updateCredentials(
                                    id: account.id,
                                    credential: credential,
                                    protectedIDs: protectedAccountIDs)
                                return nil
                            } catch CredentialLineError.invalidFormat {
                                return "Формат: LOGIN|PASS|2FA"
                            } catch CredentialLineError.missingField {
                                return "LOGIN, PASS и 2FA обязательны."
                            } catch CredentialLineError.invalidSecret {
                                return "2FA должен быть корректным Base32-ключом."
                            } catch AccountStoreError.duplicateAccountEmail {
                                return "Аккаунт с таким логином уже есть."
                            } catch AccountStoreError.rotationRecoveryActive {
                                return "Сначала завершите текущую смену 2FA."
                            } catch AccountStoreError.accountBusy {
                                return "Дождитесь завершения операции с аккаунтом."
                            } catch {
                                return "Не удалось сохранить аккаунт."
                            }
                        },
                        onSaveExternalMailbox: { configuration in
                            do {
                                try store.updateExternalMailbox(id: account.id, configuration: configuration,
                                                                protectedIDs: protectedAccountIDs)
                                return nil
                            } catch AccountStoreError.accountBusy, AccountStoreError.rotationRecoveryActive {
                                return "Дождитесь завершения операции с аккаунтом."
                            } catch {
                                return configuration == nil ? "Не удалось удалить настройку внешней почты."
                                    : "Не удалось сохранить настройку внешней почты."
                            }
                        },
                        onCopyOneTimeCode: copy,
                        onOpenOAuth: { text, mode in
                            await coordinator.openOAuthURL(for: account.id, text: text, mode: mode)
                        },
                        onOpenSafari: { await openSafariPasskeySettings(for: account) },
                        onSaveTag: { tag in
                            do {
                                try store.setAccountTag(id: account.id, tag: tag)
                            } catch {
                                importSummary = "Не удалось сохранить тег."
                            }
                        },
                        onMove: { groupID in
                            requestAccountMove(ids: [account.id], to: groupID)
                        },
                        onCheck: {
                            Task {
                                guard !subscriptionCheckBlocked else { return }
                                await coordinator.check(id: account.id)
                            }
                        },
                        onImportCodex: { startCodexImport(accounts: [account]) },
                        onRotate: {
                            pendingAccessChange = PendingAccessChange(
                                accountIDs: [account.id], title: account.email)
                        },
                        onStageManualSecret: { secret in
                            do {
                                try coordinator.stageManuallyConfigured2FA(
                                    id: account.id,
                                    secret: secret)
                                Task {
                                    await coordinator.continueRotation(id: account.id)
                                }
                                return nil
                            } catch ManualAuthenticatorRecoveryError.invalidSecret {
                                return "Введите новый Base32-ключ, отличный от старого."
                            } catch ManualAuthenticatorRecoveryError.invalidStage {
                                return "Этот способ доступен только после отключения старого 2FA."
                            } catch AccountStoreError.accountBusy {
                                return "Дождитесь завершения текущей операции."
                            } catch {
                                return "Не удалось сохранить новый 2FA для проверки."
                            }
                        },
                        onResumeRotation: {
                            Task { await coordinator.continueRotation(id: account.id) }
                        },
                        onVerifyManualPassword: { password in
                            Task { await coordinator.verifyManuallyChangedPassword(id: account.id, password: password) }
                        },
                        onStopAccessChange: { coordinator.stop() },
                        onRetryPasswordChange: {
                            Task { await coordinator.retryPasswordChange(id: account.id) }
                        },
                        onDelete: {
                            pendingDeletion = .account(account.id)
                        })
                        .id(account.id)
                    if let proxy = account.proxy {
                        HStack {
                            Text("Прокси: \(proxy.displayName)")
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                            Spacer()
                            Button("Сменить прокси") { Task { await replaceProxy(for: account.id) } }
                                .disabled(operationBlocked || !proxies.isEnabled || proxies.isChecking || proxies.isRefreshing ||
                                          account.rotationStage != nil || account.hasPendingAccessChange || account.hasPendingEmailChange)
                        }
                        if proxySwitchAccountID == account.id { ProgressView().controlSize(.small) }
                        if let proxySwitchMessage { Text(proxySwitchMessage).font(.caption).foregroundStyle(.secondary) }
                    }
                    EmailChangeControls(
                        account: account,
                        aliases: store.emailAliases,
                        disabled: operationBlocked || account.rotationStage != nil || account.hasPendingAccessChange,
                        running: coordinator.isRunning || coordinator.exitingEmailAccountID != nil || codexImportBlocked,
                        onStart: { alias in Task { await coordinator.changeEmail(id: account.id, alias: alias) } },
                        onContinue: { Task { await coordinator.continueEmailChange(id: account.id) } },
                        canExit: !codexImportBlocked && coordinator.exitingEmailAccountID == nil &&
                            (!coordinator.isRunning || coordinator.changingEmailAccountID == account.id),
                        onExit: { operationID in
                            Task { await coordinator.exitEmailChange(id: account.id, operationID: operationID) }
                        },
                        onRestore: { coordinator.restoreAbandonedEmailChange(id: account.id) },
                        onVerify: { Task { await coordinator.verifyPendingEmailChange(id: account.id) } },
                        onReturn: { coordinator.returnToEmailConfirmation(id: account.id) },
                        onFreshLogin: { Task { await coordinator.startFreshEmailLogin(id: account.id) } },
                        onReplaceAlias: { alias in
                            Task {
                                guard !codexImportBlocked else { return }
                                await coordinator.replaceEmailAlias(id: account.id, alias: alias)
                            }
                        },
                        onShowMailbox: { mailbox.ensureLoaded(); openWindow(id: "mailbox") },
                        onShowAliases: { showEmailAliases = true })
                    .id("email-\(account.id)")
                    operationStatus
                    codexImportStatus
                    if account.pendingRegistration != nil {
                        Button("Продолжить регистрацию") {
                            registration.show(id: account.id)
                            showRegistration = true
                        }
                        .disabled(registration.isRunning && registration.accountID != account.id)
                    }
                    if !showRegistration || registration.accountID != account.id {
                        browserPanel(account: account)
                    }
                }
                .frame(maxWidth: 760, alignment: .leading)
                .padding(28)
            }
            .navigationTitle(account.email)
        } else if case .group(let id) = sidebarSelection,
                  let group = store.groups.first(where: { $0.id == id }) {
            groupDetail(group: group, accounts: store.accounts(in: id))
        } else if sidebarSelection == .ungrouped {
            groupDetail(
                group: nil,
                accounts: store.accounts.filter { $0.groupID == nil })
        } else {
            ContentUnavailableView(
                "Выберите аккаунт или группу",
                systemImage: "sidebar.left",
                description: Text("Здесь появятся данные и действия."))
        }
    }

    private func groupDetail(group: AccountGroup?, accounts: [AccountRecord]) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                GroupDetailView(
                    group: group,
                    accounts: accounts,
                    checkDisabled: subscriptionCheckBlocked,
                    importDisabled: operationBlocked,
                    rotationDisabled: operationBlocked,
                    deleteDisabled: accounts.contains {
                        protectedAccountIDs.contains($0.id)
                    },
                    rotationStates: coordinator.rotationStates,
                    rotationCompletedCount: coordinator.rotationCompletedCount,
                    rotationTotalCount: coordinator.rotationTotalCount,
                    accessTokenCount: AccessTokenExport.count(for: accounts.filter(GroupAccessTokenCopy.isEligible)),
                    accessTokenCopying: accessTokenCopying,
                    accessTokenMessage: accessTokenMessage,
                    onSave: { name, tag in
                        guard let group else { return }
                        do {
                            try store.updateGroup(id: group.id, name: name, tag: tag)
                        } catch AccountStoreError.groupNameRequired {
                            importSummary = "Введите название группы."
                        } catch AccountStoreError.duplicateGroupName {
                            importSummary = "Группа с таким названием уже есть."
                        } catch {
                            importSummary = "Не удалось сохранить группу."
                        }
                    },
                    onCopyAll: {
                        copyAccounts(accounts)
                    },
                    onCopyAccessTokens: {
                        guard accessTokenTask == nil, !accessTokenCopying else { return }
                        accessTokenTask = Task {
                            await copyGroupAccessTokens(accounts)
                            accessTokenTask = nil
                        }
                    },
                    onExportAccessTokens: { tokenExportAccounts = accounts },
                    onOpenAccessTokenFolder: {
                        NSWorkspace.shared.open(store.fileURL.deletingLastPathComponent())
                    },
                    onCheck: {
                        Task {
                            guard !subscriptionCheckBlocked else { return }
                            await coordinator.checkGroup(groupID: group?.id)
                        }
                    },
                    onImportCodex: { startCodexImport(accounts: accounts) },
                    onChangeEmail: {
                        guard let group else { return }
                        Task {
                            guard !operationBlocked else { return }
                            await coordinator.changeEmail(groupID: group.id)
                        }
                    },
                    onRotate: {
                        guard let group else { return }
                        pendingAccessChange = PendingAccessChange(
                            accountIDs: accounts.map(\.id),
                            title: "Группа «\(group.name)»")
                    },
                    onDelete: {
                        guard let group else { return }
                        pendingDeletion = .group(group.id, accountCount: accounts.count)
                    })
                operationStatus
                codexImportStatus
            }
            .frame(maxWidth: 900, alignment: .leading)
            .padding(28)
        }
        .navigationTitle(group?.name ?? "Без группы")
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button("Новая регистрация", systemImage: "person.badge.plus") {
                if !registration.isRunning && !registration.hasPendingBatch { registration.newRegistration() }
                showRegistration = true
            }
            Button("Прокси", systemImage: "network") { showProxies = true }
            Button("База почт", systemImage: "tray.full") { showEmailAliases = true }
            Button("Почта Mail.ru", systemImage: "envelope") { mailbox.ensureLoaded(); openWindow(id: "mailbox") }
            Button("Импорт", systemImage: "square.and.arrow.down") {
                showImport = true
            }
            .disabled(operationBlocked)
            Button("Добавить текстом", systemImage: "text.badge.plus") {
                directImportError = nil
                directImportFilename = nil
                showTextImport = true
            }
            .disabled(operationBlocked)
            Button("Экспорт", systemImage: "square.and.arrow.up") {
                showExport = true
            }
            .disabled(store.accounts.isEmpty)
            Button("Экспорт токенов", systemImage: "key.horizontal") {
                let selected = selectedAccountIDs.isEmpty ? store.selectedID.map { Set([$0]) } ?? [] : selectedAccountIDs
                tokenExportAccounts = store.accounts.filter { selected.contains($0.id) }
            }
            .disabled(selectedAccountIDs.isEmpty && store.selectedID == nil)
            Button("Корзина", systemImage: "trash") { showAccountTrash = true }
            Button("Проверить все", systemImage: "checkmark.arrow.trianglehead.counterclockwise") {
                Task {
                    guard !subscriptionCheckBlocked else { return }
                    await coordinator.checkAll()
                }
            }
            .disabled(
                store.accounts.isEmpty || subscriptionCheckBlocked)
        }
    }

    private func accountHeader(_ account: AccountRecord) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(account.email)
                .font(.title2.weight(.semibold))
                .textSelection(.enabled)
            HStack(spacing: 7) {
                Circle()
                    .fill(statusColor(account.status))
                    .frame(width: 8, height: 8)
                Text(statusLabel(account.status))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func accountFacts(_ account: AccountRecord) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 28, verticalSpacing: 12) {
            factRow("Подписка", account.planLabel ?? "Не проверена")
            GridRow {
                Text(dateTitle(account.subscriptionDateKind))
                    .foregroundStyle(.secondary)
                if let date = account.subscriptionDate {
                    Text(date, format: .dateTime.day().month(.wide).year().hour().minute())
                } else {
                    Text("Нет данных")
                }
            }
            GridRow {
                Text("Последняя проверка")
                    .foregroundStyle(.secondary)
                if let date = account.lastCheckedAt {
                    Text(date, format: .dateTime.day().month(.abbreviated).year().hour().minute())
                } else {
                    Text("Никогда")
                }
            }
            if let error = account.lastError {
                GridRow {
                    Text("Ошибка")
                        .foregroundStyle(.secondary)
                    Text(error)
                        .foregroundStyle(.red)
                }
            }
        }
    }

    private func factRow(_ title: String, _ value: String) -> some View {
        GridRow {
            Text(title)
                .foregroundStyle(.secondary)
            Text(value)
        }
    }

    private func accountActions(_ account: AccountRecord) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Button("Проверить") {
                    Task { await coordinator.check(id: account.id) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(operationBlocked)

                Button("Копировать LOGIN|PASS|2FA") {
                    copy(account.credentialLine)
                }

                Button("Сменить доступы") {
                    pendingAccessChange = PendingAccessChange(
                                accountIDs: [account.id], title: account.email)
                }
                .disabled(operationBlocked)
            }

            if account.status == .needsRecovery {
                HStack(spacing: 10) {
                    Button("Копировать текущий 2FA") {
                        copy(account.totpSecret)
                    }
                    if let pending = account.pendingTOTPSecret {
                        Button("Копировать ожидающий 2FA") {
                            copy(pending)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var operationStatus: some View {
        if coordinator.isRunning || coordinator.totalCount > 0 || coordinator.message != nil ||
            coordinator.pausedAccountID != nil || coordinator.pausedRotationAccountID != nil {
            VStack(alignment: .leading, spacing: 10) {
                if coordinator.totalCount > 0 {
                    ProgressView(
                        value: Double(coordinator.completedCount),
                        total: Double(coordinator.totalCount)) {
                            Text("\(coordinator.completedCount) из \(coordinator.totalCount)")
                        }
                }
                if let message = coordinator.message {
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                if coordinator.isCheckingAccounts {
                    Text("В очереди проверок: \(coordinator.pendingCheckCount). Повторные запросы одного аккаунта объединяются.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    if coordinator.isRunning || coordinator.pausedAccountID != nil ||
                        coordinator.pausedRotationAccountID != nil {
                        Button("Остановить", role: .cancel) { coordinator.stop() }
                    }
                    if coordinator.pausedAccountID != nil {
                        Button("Продолжить") {
                            Task { await coordinator.resume() }
                        }
                    }
                    if coordinator.pausedRotationAccountID != nil {
                        Button("Продолжить смену доступов") {
                            Task { await coordinator.resumeRotation() }
                        }
                    }
                    if !coordinator.isRunning && !coordinator.emailQueueAccountIDs.isEmpty {
                        Button("Продолжить смену почты группы") {
                            Task { await coordinator.resumeEmailGroup() }
                        }
                        Button("Снять оставшиеся с очереди") { coordinator.cancelEmailGroupQueue() }
                    }
                }
            }
            .padding(.top, 4)
        }
    }

    @ViewBuilder
    private var codexImportStatus: some View {
        if codexImporter.totalCount > 0 || codexImporter.message != nil {
            VStack(alignment: .leading, spacing: 10) {
                if codexImporter.totalCount > 0 {
                    ProgressView(
                        value: Double(codexImporter.completedCount),
                        total: Double(codexImporter.totalCount)) {
                            Text("Импорт в CodexAcc: \(codexImporter.completedCount) из \(codexImporter.totalCount)")
                        }
                }
                if let message = codexImporter.message {
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                HStack {
                    if codexImportBlocked {
                        Button("Остановить импорт", role: .cancel) {
                            Task { await codexImporter.stop() }
                        }
                    }
                    if codexImporter.isPaused {
                        Button("Продолжить импорт") {
                            Task { await codexImporter.resume() }
                        }
                    }
                }
            }
        }
    }

    private func startCodexImport(accounts: [AccountRecord]) {
        guard !operationBlocked else { return }
        Task {
            guard !operationBlocked else { return }
            await codexImporter.start(accounts: accounts)
        }
    }

    @ViewBuilder
    private func browserPanel(account: AccountRecord) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let availability = coordinator.recoveryAvailability(for: account.id) {
                BrowserRecoveryControlsView(
                    availability: availability,
                    onReload: {
                        Task { await coordinator.reloadBrowser(for: account.id) }
                    },
                    onReopen: {
                        Task { await coordinator.reopenBrowserSection(for: account.id) }
                    },
                    onFreshLogin: {
                        pendingFreshLoginID = account.id
                    },
                    onReturnToOriginal: {
                        coordinator.returnToOriginalBrowserSession(for: account.id)
                    })
                    .disabled(codexImportBlocked || accessTokenCopying)
            }
            if let session = codexImporter.browserSession(for: account.id) ?? coordinator.browserSession(for: account.id) {
                Text("Открытая сессия ChatGPT")
                    .font(.headline)
                BrowserAddressBar(
                    session: session,
                    navigationDisabled: operationBlocked || account.rotationStage != nil || account.hasPendingCredentialChange)
                    .id(ObjectIdentifier(session))
                BrowserStatusView(session: session)
                BrowserView(session: session)
                    .frame(minHeight: 460)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(.separator, lineWidth: 1)
                    }
            }
        }
    }

    private var selectedAccount: AccountRecord? {
        guard case .account(let id) = sidebarSelection else { return nil }
        return store.accounts.first(where: { $0.id == id })
    }

    private var summaryBinding: Binding<Bool> {
        Binding(
            get: { importSummary != nil },
            set: { if !$0 { importSummary = nil } })
    }

    private var pendingDeletionBinding: Binding<Bool> {
        Binding(
            get: { pendingDeletion != nil },
            set: { if !$0 { pendingDeletion = nil } })
    }

    private var pendingAccountMoveBinding: Binding<Bool> {
        Binding(
            get: { pendingAccountMove != nil },
            set: { if !$0 { pendingAccountMove = nil } })
    }

    private var accountMoveTitle: String {
        guard let request = pendingAccountMove else { return "Переместить аккаунты?" }
        return "Переместить \(request.accountIDs.count) \(accountNoun(for: request.accountIDs.count))?"
    }

    private var accountMoveMessage: String {
        guard let request = pendingAccountMove else { return "" }
        let destination = request.destinationGroupID.flatMap { groupID in
            store.groups.first(where: { $0.id == groupID })?.name
        } ?? "Без группы"
        return "Переместить выбранные аккаунты в «\(destination)»?"
    }

    private var deletionTitle: String {
        switch pendingDeletion {
        case .account(let id):
            let email = store.accounts.first(where: { $0.id == id })?.email ?? "аккаунт"
            return "Удалить \(email)?"
        case .group(let id, _):
            let name = store.groups.first(where: { $0.id == id })?.name ?? "группу"
            return "Удалить группу «\(name)»?"
        case nil:
            return "Удалить?"
        }
    }

    private var deletionButtonTitle: String {
        switch pendingDeletion {
        case .account: "Удалить аккаунт"
        case .group: "Удалить группу с аккаунтами"
        case nil: "Удалить"
        }
    }

    private var deletionMessage: String {
        switch pendingDeletion {
        case .account:
            "Запись с локальными доступами будет перемещена в корзину. Её можно восстановить через приложение."
        case .group(_, let accountCount):
            "Группа будет удалена, а её аккаунты (\(accountCount)) перемещены в корзину с возможностью восстановления."
        case nil:
            "Запись будет перемещена в корзину."
        }
    }

    private var operationBlocked: Bool {
        !proxies.isLoaded || registration.isRunning || otherOperationBlocked
    }

    private var subscriptionCheckBlocked: Bool {
        !proxies.isLoaded || registration.isRunning || accessTokenCopying || proxySwitchAccountID != nil ||
            proxies.isChecking || proxies.isRefreshing || codexImportBlocked ||
            !coordinator.canEnqueueChecks
    }

    private var otherOperationBlocked: Bool {
        accessTokenCopying || accessTokenRefreshBlocked
    }

    private func openSafariPasskeySettings(for account: AccountRecord) async -> String? {
        guard !safariHandoffInProgress, !operationBlocked, !protectedAccountIDs.contains(account.id) else {
            return SafariPasskeySettings.OpenError.busy.localizedDescription
        }
        if proxies.isEnabled, account.proxy != nil { return SafariPasskeySettings.OpenError.proxyConfigured.localizedDescription }
        safariHandoffInProgress = true
        defer { safariHandoffInProgress = false }

        do {
            try await SafariPasskeySettings.checkExtension()
            try Task.checkCancellation()
            guard !operationBlocked, !protectedAccountIDs.contains(account.id),
                  store.accounts.first(where: { $0.id == account.id }) == account,
                  sidebarSelection == .account(account.id) else {
                throw SafariPasskeySettings.OpenError.busy
            }
            if proxies.isEnabled, account.proxy != nil { throw SafariPasskeySettings.OpenError.proxyConfigured }
            try await SafariPasskeySettings.open(email: account.email)
            return nil
        } catch let error as SafariPasskeySettings.OpenError {
            return error.localizedDescription
        } catch is CancellationError {
            return nil
        } catch {
            return SafariPasskeySettings.OpenError.extensionUnavailable.localizedDescription
        }
    }

    private var accessTokenRefreshBlocked: Bool {
        proxySwitchAccountID != nil || !proxies.isLoaded || registration.isRunning || coordinator.isRunning || coordinator.pausedAccountID != nil ||
            coordinator.pausedRotationAccountID != nil || coordinator.hasPendingEmailChange || codexImportBlocked
    }

    private var codexImportBlocked: Bool { codexImporter.isRunning || codexImporter.isPaused }

    private var protectedAccountIDs: Set<UUID> {
        nonRegistrationProtectedAccountIDs
            .union(store.accounts.filter { $0.pendingRegistration != nil }.map(\.id))
    }

    private var nonRegistrationProtectedAccountIDs: Set<UUID> {
        coordinator.protectedAccountIDs.union(codexImporter.protectedAccountIDs)
            .union(accessTokenMount.map { [$0.id] } ?? [])
    }

    private func replaceProxy(for id: UUID) async {
        guard !operationBlocked, proxies.isEnabled, !proxies.isChecking, !proxies.isRefreshing,
              let account = store.accounts.first(where: { $0.id == id }), let old = account.proxy else { return }
        proxySwitchAccountID = id
        proxySwitchMessage = "Подбирается другой доступный прокси…"
        defer { proxySwitchAccountID = nil }
        do {
            guard proxies.proxies.contains(where: { $0.isEnabled && $0.proxy != old }) else {
                proxySwitchMessage = "Другого включённого прокси в списке нет. Текущий адрес сохранён; «Возобновить» проверит его снова."
                return
            }
            guard let replacement = try await proxies.chooseForNewAccount(excluding: [old]) else {
                throw ProxyStoreError.noAvailableProxy
            }
            try Task.checkCancellation()
            guard !registration.isRunning, !coordinator.isRunning, !codexImportBlocked else {
                throw AccountStoreError.accountBusy
            }
            let previousSession = coordinator.browserSession(for: id)
            _ = try store.replaceAccountProxy(id: id, expectedProxy: old, proxy: replacement,
                                              protectedIDs: coordinator.protectedAccountIDs.union(codexImporter.protectedAccountIDs))
            previousSession?.cancelLoading()
            previousSession?.setVisible(false)
            registration.proxyDidChange(id: id)
            proxySwitchMessage = "Прокси заменён: \(replacement.displayName). Сессия и данные аккаунта сохранены."
        } catch {
            proxySwitchMessage = (error as? ProxyStoreError)?.localizedDescription ??
                "Не удалось сменить прокси. Прежний адрес и сессия сохранены."
        }
    }

    private func importFile(_ result: Result<[URL], Error>) {
        guard !operationBlocked else {
            importSummary = "Дождитесь завершения текущей операции."
            return
        }
        do {
            guard let url = try result.get().first else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            directImportText = try String(contentsOf: url, encoding: .utf8)
            directImportFilename = url.lastPathComponent
            directImportError = nil
            showTextImport = true
        } catch {
            importSummary = "Не удалось импортировать UTF-8 файл."
        }
    }

    private func importDirectText() {
        guard !operationBlocked else {
            directImportError = "Дождитесь завершения текущей операции."
            return
        }
        guard let separator = importSeparatorChoice.separator(custom: customImportSeparator) else {
            directImportError = "Введите разделитель без переноса строки."
            return
        }
        do {
            let summary = try AccountImportService.importText(directImportText, into: store, separator: separator)
            guard summary.imported > 0 else {
                directImportError = "Аккаунты не распознаны. Проверьте формат, 2FA и поля внешней почты."
                return
            }
            directImportText = ""
            directImportError = nil
            directImportFilename = nil
            showTextImport = false
            importSummary = summary.message
        } catch {
            directImportError = "Не удалось сохранить аккаунты локально."
        }
    }

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    private func copyAccounts(_ accounts: [AccountRecord]) {
        let text = ImportExportService.serializeForClipboard(accounts)
        NSPasteboard.general.clearContents()
        guard NSPasteboard.general.setString(text, forType: .string) else {
            importSummary = "Не удалось скопировать аккаунты."
            return
        }
    }

    private func copyGroupAccessTokens(_ accounts: [AccountRecord]) async {
        guard !accessTokenCopying, !accounts.isEmpty, !Task.isCancelled else { return }
        let canRefresh = !operationBlocked && !proxies.isChecking && !proxies.isRefreshing
        accessTokenCopying = true
        accessTokenMessage = canRefresh ? "Чтение accessToken из сохранённых сессий…" : nil
        var refreshedIDs: Set<UUID> = []
        defer {
            accessTokenMount = nil
            accessTokenCopying = false
        }

        if canRefresh {
            for account in GroupAccessTokenCopy.currentAccounts(from: accounts, in: store.accounts) {
                guard !accessTokenRefreshBlocked, !proxies.isChecking, !proxies.isRefreshing,
                      !Task.isCancelled else { break }
                guard store.accounts.first(where: { $0.id == account.id }) == account else { continue }
                let session = accessTokenBrowser.accountSession(for: account)
                accessTokenMount = BrowserMount(id: account.id, session: session)
                await Task.yield()
                guard !Task.isCancelled, !accessTokenRefreshBlocked,
                      !proxies.isChecking, !proxies.isRefreshing else { break }
                if !TrustedChatGPTOrigin.allowsMetadata(session.webView.url) {
                    let loaded = await session.loadInitialPage(URL(string: "https://chatgpt.com/")!, seconds: 10, attempts: 1)
                    if Task.isCancelled {
                        session.cancelLoading()
                        break
                    }
                    guard loaded else { continue }
                }
                do {
                    try Task.checkCancellation()
                    guard !accessTokenRefreshBlocked, !proxies.isChecking, !proxies.isRefreshing,
                          store.accounts.first(where: { $0.id == account.id }) == account else { break }
                    let token = try await accessTokenBrowser.accessToken(for: account, in: session)
                    try Task.checkCancellation()
                    guard !accessTokenRefreshBlocked, !proxies.isChecking, !proxies.isRefreshing else { break }
                    guard store.accounts.first(where: { $0.id == account.id }) == account else { continue }
                    try store.saveAccessToken(id: account.id, accessToken: token)
                    refreshedIDs.insert(account.id)
                } catch is CancellationError {
                    break
                } catch {
                    // Missing or mismatched sessions require the user to sign in manually.
                }
            }
        }

        guard !Task.isCancelled else { return }
        let currentAccounts = GroupAccessTokenCopy.currentAccounts(from: accounts, in: store.accounts)
        let text = AccessTokenExport.text(for: currentAccounts)
        let copiedCount = AccessTokenExport.count(for: currentAccounts)
        let missingCount = accounts.count - copiedCount
        let cachedCount = currentAccounts.count { $0.accessTokenLine != nil && !refreshedIDs.contains($0.id) }
        var exportFailed = false
        do { _ = try store.writeRegistrationAccessTokenExport() }
        catch { exportFailed = true }
        guard copiedCount > 0 else {
            accessTokenMessage = "Нет доступных accessToken. Пропущено: \(missingCount). Откройте аккаунты и подтвердите вход вручную."
            if !canRefresh {
                accessTokenMessage? += " Для чтения токенов дождитесь завершения текущей операции."
            }
            if exportFailed { accessTokenMessage? += " Не удалось обновить файл new-novoreg." }
            return
        }
        NSPasteboard.general.clearContents()
        guard NSPasteboard.general.setString(text, forType: .string) else {
            accessTokenMessage = "Не удалось скопировать почта|accessToken."
            return
        }
        accessTokenMessage = "Скопировано: \(copiedCount). Пропущено: \(missingCount)."
        if cachedCount > 0 {
            accessTokenMessage? += " Из сохранённого кэша без проверки актуальности: \(cachedCount)."
        }
        if !canRefresh && missingCount > 0 {
            accessTokenMessage? += " Для чтения остальных токенов дождитесь завершения текущей операции."
        }
        if exportFailed { accessTokenMessage? += " Не удалось обновить файл new-novoreg." }
    }

    private func confirmDeletion() {
        guard let deletion = pendingDeletion else { return }
        do {
            switch deletion {
            case .account(let id):
                if registration.blockedAccountIDs.contains(id) {
                    try registration.deleteBlockedAccount(id: id, protectedIDs: nonRegistrationProtectedAccountIDs)
                } else {
                    try store.deleteAccount(id: id, protectedIDs: protectedAccountIDs)
                }
            case .group(let id, _):
                try store.deleteGroup(id: id, protectedIDs: protectedAccountIDs)
                sidebarSelection = store.selectedID.map(SidebarSelection.account) ?? .ungrouped
            }
            pendingDeletion = nil
            do { _ = try store.writeRegistrationAccessTokenExport() }
            catch { importSummary = "Запись перемещена в корзину, но файл токенов ещё не обновлён." }
        } catch AccountStoreError.accountBusy {
            pendingDeletion = nil
            importSummary = "Дождитесь завершения текущей операции."
        } catch {
            pendingDeletion = nil
            importSummary = "Не удалось удалить локальные данные."
        }
    }

    private func confirmAccountMove() {
        guard let request = pendingAccountMove else { return }
        do {
            try store.moveAccounts(
                ids: request.accountIDs,
                to: request.destinationGroupID,
                protectedIDs: protectedAccountIDs)
            pendingAccountMove = nil
        } catch AccountStoreError.accountBusy {
            pendingAccountMove = nil
            importSummary = "Дождитесь завершения текущей операции."
        } catch {
            pendingAccountMove = nil
            importSummary = "Не удалось переместить аккаунты."
        }
    }

    private func requestAccountMove(ids: Set<UUID>, to groupID: UUID?) {
        guard !ids.isEmpty else { return }
        guard !operationBlocked else {
            importSummary = "Дождитесь завершения текущей операции."
            return
        }
        pendingAccountMove = PendingAccountMove(
            accountIDs: ids,
            destinationGroupID: groupID)
    }

    private func accountNoun(for count: Int) -> String {
        let remainder = count % 100
        if (11...14).contains(remainder) { return "аккаунтов" }
        switch count % 10 {
        case 1: return "аккаунт"
        case 2...4: return "аккаунта"
        default: return "аккаунтов"
        }
    }

    private func statusColor(_ status: AccountStatus) -> Color {
        switch status {
        case .unchecked: .secondary
        case .checking: .blue
        case .ready: .green
        case .failed: .red
        case .needsRecovery: .orange
        }
    }

    private func statusLabel(_ status: AccountStatus) -> String {
        switch status {
        case .unchecked: "Не проверен"
        case .checking: "Проверяется"
        case .ready: "Готов"
        case .failed: "Ошибка"
        case .needsRecovery: "Требуется восстановление 2FA"
        }
    }

    private func dateTitle(_ kind: SubscriptionDateKind?) -> String {
        switch kind {
        case .renews: "Продление"
        case .expires: "Окончание"
        case nil: "Дата подписки"
        }
    }
}

private enum ImportSeparatorChoice: String, CaseIterable, Identifiable {
    case automatic, pipe, colon, semicolon, comma, tab, custom

    var id: Self { self }
    var title: String {
        switch self {
        case .automatic: "Автоматически"
        case .pipe: "Вертикальная черта |"
        case .colon: "Двоеточие :"
        case .semicolon: "Точка с запятой ;"
        case .comma: "Запятая ,"
        case .tab: "Табуляция"
        case .custom: "Свой разделитель"
        }
    }

    func separator(custom: String) -> CredentialImportSeparator? {
        switch self {
        case .automatic: .automatic
        case .pipe: .literal("|")
        case .colon: .literal(":")
        case .semicolon: .literal(";")
        case .comma: .literal(",")
        case .tab: .literal("\t")
        case .custom: custom.isEmpty || custom.contains(where: \.isNewline) ? nil : .literal(custom)
        }
    }
}

private struct DirectTextImportSheet: View {
    @Binding var text: String
    @Binding var separatorChoice: ImportSeparatorChoice
    @Binding var customSeparator: String
    let filename: String?
    let errorMessage: String?
    let onCancel: () -> Void
    let onImport: () -> Void

    private var separator: CredentialImportSeparator? { separatorChoice.separator(custom: customSeparator) }
    private var preview: ImportResult? { separator.map { ImportExportService.parse(text, separator: $0) } }
    private var formatExample: String {
        guard case .literal(let value) = separator else { return "LOGIN|PASS|2FA" }
        return ["LOGIN", "PASS", "2FA"].joined(separator: value == "\t" ? " ⇥ " : value)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(filename == nil ? "Добавить аккаунты текстом" : "Импорт аккаунтов из файла")
                .font(.title3.weight(.semibold))
            if let filename { Text(filename).font(.callout).foregroundStyle(.secondary) }
            Text("Вставьте строки аккаунтов или блоки с полями Email, Password, 2FA, Mailbox email и «Ссылка для кода с почты».")
                .foregroundStyle(.secondary)

            Picker("Разделитель", selection: $separatorChoice) {
                ForEach(ImportSeparatorChoice.allCases) { Text($0.title).tag($0) }
            }
            if separatorChoice == .custom {
                TextField("Например: :: или ----", text: $customSeparator)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Свой разделитель")
            }
            Text(formatExample).font(.system(.callout, design: .monospaced))
            Text(separatorChoice == .automatic
                 ? "Автоопределение в каждой строке: | : ; , или табуляция."
                 : "Первый и последний разделители отделяют логин и 2FA. Символы и пробелы внутри пароля сохраняются.")
                .font(.caption).foregroundStyle(.secondary)

            TextEditor(text: $text)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 220)
                .border(.separator)
                .accessibilityLabel("Строки аккаунтов")

            if let preview {
                Text("Распознано: \(preview.records.count). Ошибки: \(preview.issues.count). Дубликаты: \(preview.duplicateEmails.count).")
                    .font(.callout).foregroundStyle(.secondary)
                if !preview.issues.isEmpty {
                    Text("Ошибки в строках \(preview.issues.prefix(6).map { String($0.lineNumber) }.joined(separator: ", "))\(preview.issues.count > 6 ? "…" : ""). Проверьте формат, 2FA и поля внешней почты.")
                        .font(.caption).foregroundStyle(.orange)
                }
            } else {
                Text("Введите свой разделитель без переноса строки.")
                    .font(.callout).foregroundStyle(.orange)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.callout)
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("Отмена", action: onCancel)
                Button("Добавить", action: onImport)
                    .keyboardShortcut(.defaultAction)
                    .disabled(preview?.records.isEmpty != false)
            }
        }
        .padding(20)
        .frame(width: 660, height: 570)
    }
}
