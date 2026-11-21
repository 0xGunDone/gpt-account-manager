import Foundation
import Observation

enum AccountStoreError: Error, Equatable {
    case rotationRecoveryActive
    case duplicateAccountEmail
    case insecurePermissions
    case temporaryFileCreationFailed
    case unsupportedVersion
    case groupNameRequired
    case duplicateGroupName
    case missingGroup
    case accountBusy
    case invalidEmailAlias
    case emailAliasUnavailable
    case emailChangeNotFound
    case invalidEmailChangeCheckpoint
    case emailChangeVerificationFailed
    case emailChangeAlreadyRequested
    case invalidRegistration
    case registrationNotFound
    case invalidRegistrationCheckpoint
    case registrationVerificationFailed
    case invalidAccessToken
}

@MainActor
@Observable
final class AccountStore {
    private(set) var accounts: [AccountRecord] = []
    private(set) var groups: [AccountGroup] = []
    private(set) var emailAliases: [EmailAlias] = []
    private(set) var deletedAccounts: [DeletedAccountSnapshot] = []
    var selectedID: UUID?
    let fileURL: URL

    init(fileURL: URL = AccountStore.defaultFileURL()) {
        self.fileURL = fileURL
    }

    static func defaultFileURL() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GPT Account Manager", isDirectory: true)
            .appendingPathComponent("accounts.json")
    }

    func load() throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directory.path)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fileURL.path)
        try verifyPermissions(of: directory, expected: 0o700)
        try verifyPermissions(of: fileURL, expected: 0o600)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let data = try Data(contentsOf: fileURL)
        let candidateGroups: [AccountGroup]
        let candidateAliases: [EmailAlias]
        let candidateDeletedAccounts: [DeletedAccountSnapshot]
        let loadedAccounts: [AccountRecord]
        if let root = try? decoder.decode(PersistedAccountData.self, from: data) {
            guard root.version == PersistedAccountData.currentVersion else {
                throw AccountStoreError.unsupportedVersion
            }
            candidateGroups = root.groups
            candidateAliases = root.emailAliases
            candidateDeletedAccounts = root.deletedAccounts
            loadedAccounts = root.accounts.map { account in
                var value = account
                if let groupID = value.groupID,
                   !root.groups.contains(where: { $0.id == groupID }) {
                    value.groupID = nil
                }
                return value
            }
        } else {
            candidateGroups = []
            candidateAliases = []
            candidateDeletedAccounts = []
            loadedAccounts = try decoder.decode([AccountRecord].self, from: data)
        }
        let candidateAccounts = loadedAccounts.map { account in
            var value = account
            if value.hasPendingEmailChange || value.pendingRegistration != nil {
                value.status = .needsRecovery
            } else if value.status == .checking {
                value.status = value.rotationStage == nil ? .unchecked : .needsRecovery
            }
            return value
        }
        let candidateSelectedID = selectedID(for: candidateAccounts)
        groups = candidateGroups
        accounts = candidateAccounts
        emailAliases = candidateAliases
        deletedAccounts = candidateDeletedAccounts
        selectedID = candidateSelectedID
    }

    func merge(_ credentials: [ImportedCredential]) throws {
        var candidate = accounts
        for credential in credentials {
            guard !candidate.contains(where: {
                $0.pendingEmailChange?.newEmail.caseInsensitiveCompare(credential.email) == .orderedSame
            }) else { throw AccountStoreError.accountBusy }
            if let index = candidate.firstIndex(where: {
                $0.email.caseInsensitiveCompare(credential.email) == .orderedSame
            }) {
                guard candidate[index].rotationStage == nil,
                      candidate[index].pendingTOTPSecret == nil,
                      !candidate[index].hasPendingCredentialChange
                else { throw AccountStoreError.rotationRecoveryActive }
                candidate[index].email = credential.email
                candidate[index].password = credential.password
                if let externalMailbox = credential.externalMailbox {
                    candidate[index].externalMailbox = externalMailbox
                }
                // Importing an existing login must not silently replace the
                // working authenticator. Edit credentials explicitly when a
                // 2FA secret really needs to change.
            } else {
                candidate.append(AccountRecord(credential: credential))
            }
        }
        try commit(
            groups: groups,
            accounts: candidate,
            selectedID: selectedID(for: candidate))
    }

    func updateCredentials(
        id: UUID,
        credential: ImportedCredential,
        protectedIDs: Set<UUID>
    ) throws {
        guard !protectedIDs.contains(id) else { throw AccountStoreError.accountBusy }
        guard let index = accounts.firstIndex(where: { $0.id == id }) else { return }
        guard accounts[index].rotationStage == nil,
              accounts[index].pendingTOTPSecret == nil,
              !accounts[index].hasPendingCredentialChange
        else { throw AccountStoreError.rotationRecoveryActive }
        guard !accounts.contains(where: {
            $0.id != id &&
                ($0.email.caseInsensitiveCompare(credential.email) == .orderedSame ||
                 $0.pendingEmailChange?.newEmail.caseInsensitiveCompare(credential.email) == .orderedSame)
        }) else { throw AccountStoreError.duplicateAccountEmail }

        var candidate = accounts
        if candidate[index].email.caseInsensitiveCompare(credential.email) != .orderedSame {
            candidate[index].browserStoreID = UUID()
        }
        candidate[index].email = credential.email
        candidate[index].password = credential.password
        candidate[index].totpSecret = credential.totpSecret
        try commit(
            groups: groups,
            accounts: candidate,
            selectedID: selectedID(for: candidate))
    }

    func updateExternalMailbox(
        id: UUID,
        configuration: ExternalMailboxConfiguration?,
        protectedIDs: Set<UUID>
    ) throws {
        guard !protectedIDs.contains(id),
              let account = accounts.first(where: { $0.id == id })
        else { throw AccountStoreError.accountBusy }
        guard account.rotationStage == nil, account.pendingTOTPSecret == nil,
              !account.hasPendingCredentialChange
        else { throw AccountStoreError.rotationRecoveryActive }
        try mutate(id: id) { $0.externalMailbox = configuration }
    }

    func mutate(id: UUID, _ change: (inout AccountRecord) -> Void) throws {
        var candidate = accounts
        guard let index = candidate.firstIndex(where: { $0.id == id }) else { return }
        change(&candidate[index])
        if accounts[index].hasPendingEmailChange || accounts[index].pendingRegistration != nil {
            guard candidate[index].id == accounts[index].id,
                  candidate[index].email == accounts[index].email,
                  candidate[index].password == accounts[index].password,
                  candidate[index].totpSecret == accounts[index].totpSecret,
                  candidate[index].browserStoreID == accounts[index].browserStoreID,
                  candidate[index].pendingPassword == accounts[index].pendingPassword,
                  candidate[index].pendingAccessChange == accounts[index].pendingAccessChange,
                  candidate[index].accessChangePasswordVerified == accounts[index].accessChangePasswordVerified,
                  candidate[index].pendingTOTPSecret == accounts[index].pendingTOTPSecret,
                  candidate[index].rotationStage == accounts[index].rotationStage,
                  candidate[index].pendingEmailChange == accounts[index].pendingEmailChange,
                  candidate[index].pendingRegistration == accounts[index].pendingRegistration,
                  accounts[index].pendingRegistration == nil ||
                    (candidate[index].status == .needsRecovery && candidate[index].groupID == nil &&
                     candidate[index].proxy == accounts[index].proxy)
            else { throw AccountStoreError.accountBusy }
        }
        try commit(
            groups: groups,
            accounts: candidate,
            selectedID: selectedID(for: candidate))
    }

    @discardableResult
    func replaceAccountProxy(
        id: UUID,
        expectedProxy: AccountProxy?,
        proxy: AccountProxy,
        protectedIDs: Set<UUID> = []
    ) throws -> AccountRecord {
        guard !protectedIDs.contains(id),
              let index = accounts.firstIndex(where: { $0.id == id }),
              accounts[index].proxy == expectedProxy,
              accounts[index].rotationStage == nil,
              accounts[index].pendingTOTPSecret == nil,
              !accounts[index].hasPendingAccessChange,
              !accounts[index].hasPendingEmailChange
        else { throw AccountStoreError.accountBusy }
        var candidate = accounts
        candidate[index].proxy = proxy
        try commit(groups: groups, accounts: candidate, selectedID: selectedID(for: candidate))
        return candidate[index]
    }

    func save() throws {
        try commit(
            groups: groups,
            accounts: accounts,
            selectedID: selectedID(for: accounts))
    }

    @discardableResult
    func beginRegistration(
        email: String, fullName: String, age: Int, password: String, proxy: AccountProxy? = nil
    ) throws -> AccountRecord {
        let name = fullName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let email = MailVerificationMatcher.normalizedAddress(email),
              !name.isEmpty, !name.contains(where: \.isNewline), (18...100).contains(age),
              !password.isEmpty, !password.contains(where: \.isNewline)
        else { throw AccountStoreError.invalidRegistration }
        guard !accounts.contains(where: {
            $0.email.caseInsensitiveCompare(email) == .orderedSame ||
            $0.pendingEmailChange?.newEmail.caseInsensitiveCompare(email) == .orderedSame
        }) else { throw AccountStoreError.duplicateAccountEmail }
        var account = AccountRecord(credential: .init(email: email, password: password, totpSecret: ""))
        account.proxy = proxy
        account.pendingRegistration = .init(fullName: name, age: age)
        account.status = .needsRecovery
        try commit(groups: groups, accounts: accounts + [account], selectedID: account.id)
        return account
    }

    func checkpointRegistration(id: UUID, registration: PendingRegistration) throws {
        guard let index = accounts.firstIndex(where: { $0.id == id }),
              let current = accounts[index].pendingRegistration
        else { throw AccountStoreError.registrationNotFound }
        let phases: [RegistrationPhase] = [.signingUp, .awaitingEmailCode, .profile, .enablingTwoFA, .verifyingLogin]
        guard let currentPhase = phases.firstIndex(of: current.phase),
              let nextPhase = phases.firstIndex(of: registration.phase), nextPhase >= currentPhase,
              registration.fullName == current.fullName, registration.age == current.age,
              registration.termsAccepted && current.termsAccepted,
              !current.passwordWasSubmitted || registration.passwordWasSubmitted,
              current.profileRetryUsed != true || registration.profileRetryUsed == true,
              current.pendingSecret == nil || registration.pendingSecret == current.pendingSecret,
              registration.pendingSecret.map(TOTPService.isValidSecret) ?? true,
              accounts[index].totpSecret.isEmpty,
              !accounts[index].hasPendingEmailChange, !accounts[index].hasPendingAccessChange,
              accounts[index].rotationStage == nil, accounts[index].pendingTOTPSecret == nil
        else { throw AccountStoreError.invalidRegistrationCheckpoint }
        var candidate = accounts
        candidate[index].pendingRegistration = registration
        candidate[index].status = .needsRecovery
        candidate[index].lastError = nil
        try commit(groups: groups, accounts: candidate, selectedID: selectedID(for: candidate))
    }

    func updateRegistrationPassword(id: UUID, password: String) throws {
        guard let index = accounts.firstIndex(where: { $0.id == id }),
              let registration = accounts[index].pendingRegistration
        else { throw AccountStoreError.registrationNotFound }
        guard !password.allSatisfy(\.isWhitespace)
        else { throw AccountStoreError.invalidRegistration }
        guard registration.phase == .verifyingLogin, registration.passwordWasSubmitted,
              registration.termsAccepted,
              registration.pendingSecret.map(TOTPService.isValidSecret) == true,
              accounts[index].totpSecret.isEmpty,
              !accounts[index].hasPendingEmailChange, !accounts[index].hasPendingAccessChange,
              accounts[index].rotationStage == nil, accounts[index].pendingTOTPSecret == nil
        else { throw AccountStoreError.invalidRegistrationCheckpoint }
        var candidate = accounts
        candidate[index].password = password
        candidate[index].status = .needsRecovery
        try commit(groups: groups, accounts: candidate, selectedID: selectedID(for: candidate))
    }

    func completeRegistration(
        id: UUID, verifiedEmail: String, secret: String,
        proof: CleanLoginProof, snapshot: SubscriptionSnapshot, accessToken: String? = nil
    ) throws {
        try finishRegistration(id: id, verifiedEmail: verifiedEmail, secret: secret,
                               verificationConfirmed: proof.isSufficient, snapshot: snapshot, accessToken: accessToken)
    }

    func completeRegistrationAfterSetup(
        id: UUID, verifiedEmail: String, secret: String,
        authenticatorEnabled: Bool, snapshot: SubscriptionSnapshot, accessToken: String
    ) throws {
        guard AccessTokenExport.isValidField(accessToken) else { throw AccountStoreError.invalidAccessToken }
        try finishRegistration(id: id, verifiedEmail: verifiedEmail, secret: secret,
                               verificationConfirmed: authenticatorEnabled, snapshot: snapshot, accessToken: accessToken)
    }

    private func finishRegistration(
        id: UUID, verifiedEmail: String, secret: String,
        verificationConfirmed: Bool, snapshot: SubscriptionSnapshot, accessToken: String?
    ) throws {
        guard let index = accounts.firstIndex(where: { $0.id == id }),
              let registration = accounts[index].pendingRegistration
        else { throw AccountStoreError.registrationNotFound }
        guard registration.phase == .verifyingLogin, registration.passwordWasSubmitted,
              registration.termsAccepted, registration.pendingSecret == secret,
              TOTPService.isValidSecret(secret), verificationConfirmed,
              verifiedEmail.caseInsensitiveCompare(accounts[index].email) == .orderedSame,
              snapshot.signedInEmail.caseInsensitiveCompare(accounts[index].email) == .orderedSame,
              !accounts.contains(where: {
                  $0.id != id && ($0.email.caseInsensitiveCompare(accounts[index].email) == .orderedSame ||
                    $0.pendingEmailChange?.newEmail.caseInsensitiveCompare(accounts[index].email) == .orderedSame)
              })
        else { throw AccountStoreError.registrationVerificationFailed }
        if let accessToken, !AccessTokenExport.isValidField(accessToken) {
            throw AccountStoreError.invalidAccessToken
        }
        var candidateGroups = groups
        let group: AccountGroup
        if let existing = groups.first(where: { $0.name.caseInsensitiveCompare("new-novoreg") == .orderedSame }) {
            group = existing
        } else {
            group = AccountGroup(name: "new-novoreg")
            candidateGroups.append(group)
        }
        var candidate = accounts
        candidate[index].totpSecret = secret
        candidate[index].pendingRegistration = nil
        candidate[index].status = .ready
        candidate[index].lastError = nil
        candidate[index].lastCheckedAt = Date()
        candidate[index].planLabel = snapshot.planLabel
        candidate[index].subscriptionDate = snapshot.activeUntil
        candidate[index].subscriptionDateKind = snapshot.dateKind
        candidate[index].groupID = group.id
        candidate[index].accessToken = accessToken
        try commit(groups: candidateGroups, accounts: candidate, selectedID: selectedID(for: candidate))
    }

    func saveAccessToken(id: UUID, accessToken: String) throws {
        guard AccessTokenExport.isValidField(accessToken) else { throw AccountStoreError.invalidAccessToken }
        var candidate = accounts
        guard let index = candidate.firstIndex(where: { $0.id == id }) else { return }
        candidate[index].accessToken = accessToken
        try commit(groups: groups, accounts: candidate, selectedID: selectedID)
    }

    @discardableResult
    func writeRegistrationAccessTokenExport() throws -> URL {
        let groupIDs = Set(groups.filter {
            $0.name.caseInsensitiveCompare("new-novoreg") == .orderedSame
        }.map(\.id))
        let text = AccessTokenExport.text(for: accounts.filter {
            $0.status == .ready && !$0.hasPendingCredentialChange &&
                $0.rotationStage == nil && $0.pendingTOTPSecret == nil &&
                $0.groupID.map(groupIDs.contains) == true
        })
        let directory = fileURL.deletingLastPathComponent()
        let exportURL = directory.appendingPathComponent("new-novoreg-access-tokens.txt")
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        try verifyPermissions(of: directory, expected: 0o700)
        let temporaryURL = directory.appendingPathComponent(".access-tokens-\(UUID().uuidString).tmp")
        guard fileManager.createFile(atPath: temporaryURL.path, contents: nil,
                                     attributes: [.posixPermissions: 0o600])
        else { throw AccountStoreError.temporaryFileCreationFailed }
        defer { try? fileManager.removeItem(at: temporaryURL) }
        let handle = try FileHandle(forWritingTo: temporaryURL)
        do {
            try handle.write(contentsOf: Data((text.isEmpty ? "" : text + "\n").utf8))
            try handle.synchronize()
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }
        try verifyPermissions(of: temporaryURL, expected: 0o600)
        if fileManager.fileExists(atPath: exportURL.path) {
            let values = try exportURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                throw CocoaError(.fileWriteFileExists)
            }
            _ = try fileManager.replaceItemAt(exportURL, withItemAt: temporaryURL,
                                              backupItemName: nil, options: [.usingNewMetadataOnly])
        } else {
            try fileManager.moveItem(at: temporaryURL, to: exportURL)
        }
        try verifyPermissions(of: exportURL, expected: 0o600)
        return exportURL
    }

    /// Leave an already-created account manageable when its final login cannot be verified.
    /// This does not certify the password/2FA or publish it into the ready group.
    func saveRegistrationAsUnverifiedAccount(id: UUID, failure: String? = nil) throws {
        guard let index = accounts.firstIndex(where: { $0.id == id }),
              let registration = accounts[index].pendingRegistration else { throw AccountStoreError.registrationNotFound }
        guard registration.phase == .verifyingLogin, registration.passwordWasSubmitted,
              let secret = registration.pendingSecret, TOTPService.isValidSecret(secret),
              accounts[index].totpSecret.isEmpty, !accounts[index].hasPendingEmailChange,
              !accounts[index].hasPendingAccessChange, accounts[index].rotationStage == nil,
              accounts[index].pendingTOTPSecret == nil else { throw AccountStoreError.invalidRegistrationCheckpoint }
        var candidate = accounts
        candidate[index].totpSecret = secret
        candidate[index].pendingRegistration = nil
        candidate[index].status = failure == nil ? .unchecked : .failed
        candidate[index].lastError = failure ?? "Аккаунт сохранён без завершённой проверки входа с паролем и 2FA."
        try commit(groups: groups, accounts: candidate, selectedID: selectedID(for: candidate))
    }

    func createGroup(name: String, tag: String?) throws -> AccountGroup {
        let normalizedName = try normalizedGroupName(name)
        guard !groups.contains(where: {
            $0.name.caseInsensitiveCompare(normalizedName) == .orderedSame
        }) else { throw AccountStoreError.duplicateGroupName }

        let group = AccountGroup(name: normalizedName, tag: normalizedTag(tag))
        try commit(
            groups: groups + [group],
            accounts: accounts,
            selectedID: selectedID(for: accounts))
        return group
    }

    func updateGroup(id: UUID, name: String, tag: String?) throws {
        let normalizedName = try normalizedGroupName(name)
        guard let index = groups.firstIndex(where: { $0.id == id }) else {
            throw AccountStoreError.missingGroup
        }
        guard !groups.enumerated().contains(where: { candidate in
            candidate.offset != index &&
                candidate.element.name.caseInsensitiveCompare(normalizedName) == .orderedSame
        }) else { throw AccountStoreError.duplicateGroupName }

        var candidateGroups = groups
        candidateGroups[index].name = normalizedName
        candidateGroups[index].tag = normalizedTag(tag)
        try commit(
            groups: candidateGroups,
            accounts: accounts,
            selectedID: selectedID(for: accounts))
    }

    func setAccountTag(id: UUID, tag: String?) throws {
        guard let index = accounts.firstIndex(where: { $0.id == id }) else { return }
        var candidateAccounts = accounts
        candidateAccounts[index].tag = normalizedTag(tag)
        try commit(
            groups: groups,
            accounts: candidateAccounts,
            selectedID: selectedID(for: candidateAccounts))
    }

    func moveAccounts(ids: Set<UUID>, to groupID: UUID?, protectedIDs: Set<UUID>) throws {
        guard ids.isDisjoint(with: protectedIDs),
              !accounts.contains(where: { ids.contains($0.id) && $0.pendingRegistration != nil })
        else { throw AccountStoreError.accountBusy }
        if let groupID,
           !groups.contains(where: { $0.id == groupID }) {
            throw AccountStoreError.missingGroup
        }

        var candidateAccounts = accounts
        for index in candidateAccounts.indices where ids.contains(candidateAccounts[index].id) {
            candidateAccounts[index].groupID = groupID
        }
        try commit(
            groups: groups,
            accounts: candidateAccounts,
            selectedID: selectedID(for: candidateAccounts))
    }

    func deleteAccount(id: UUID, protectedIDs: Set<UUID>) throws {
        guard !protectedIDs.contains(id),
              !accounts.contains(where: { $0.id == id && ($0.hasPendingEmailChange || $0.pendingRegistration != nil) })
        else { throw AccountStoreError.accountBusy }
        let candidateAccounts = accounts.filter { $0.id != id }
        guard candidateAccounts.count != accounts.count else { return }
        try commit(
            groups: groups,
            accounts: candidateAccounts,
            deletedAccounts: deletedAccounts + accounts.filter { $0.id == id }.map(deletedSnapshot),
            selectedID: selectedID(for: candidateAccounts))
    }

    /// Only the registration coordinator can archive an already recorded provider block.
    func deleteDeactivatedRegistration(id: UUID, expectedError: String, protectedIDs: Set<UUID>) throws {
        guard !protectedIDs.contains(id),
              expectedError == RegistrationCoordinator.deactivatedAccountMessage,
              let account = accounts.first(where: { $0.id == id }),
              account.pendingRegistration != nil, account.status != .ready,
              account.lastError == expectedError, !account.hasPendingAccessChange,
              !account.hasPendingEmailChange, account.rotationStage == nil,
              account.pendingTOTPSecret == nil
        else { throw AccountStoreError.accountBusy }
        let candidateAccounts = accounts.filter { $0.id != id }
        try commit(groups: groups, accounts: candidateAccounts,
                   deletedAccounts: deletedAccounts + [deletedSnapshot(account)],
                   selectedID: selectedID(for: candidateAccounts))
    }

    func deleteGroup(id: UUID, protectedIDs: Set<UUID>) throws {
        guard groups.contains(where: { $0.id == id }) else {
            throw AccountStoreError.missingGroup
        }
        let memberIDs = Set(accounts.lazy.filter { $0.groupID == id }.map(\.id))
        guard memberIDs.isDisjoint(with: protectedIDs),
              !accounts.contains(where: { $0.groupID == id && ($0.hasPendingEmailChange || $0.pendingRegistration != nil) })
        else { throw AccountStoreError.accountBusy }

        let candidateGroups = groups.filter { $0.id != id }
        let candidateAccounts = accounts.filter { $0.groupID != id }
        try commit(
            groups: candidateGroups,
            accounts: candidateAccounts,
            deletedAccounts: deletedAccounts + accounts.filter { $0.groupID == id }.map(deletedSnapshot),
            selectedID: selectedID(for: candidateAccounts))
    }

    func restoreDeletedAccount(id: UUID, protectedIDs: Set<UUID>) throws {
        guard let snapshot = deletedAccounts.first(where: { $0.id == id }) else { return }
        var account = snapshot.account
        guard !protectedIDs.contains(account.id) else { throw AccountStoreError.accountBusy }
        let emails = [account.email, account.pendingEmailChange?.newEmail].compactMap { $0 }
        guard !accounts.contains(where: { existing in
            existing.id == account.id || emails.contains(where: { email in
                existing.email.caseInsensitiveCompare(email) == .orderedSame ||
                    existing.pendingEmailChange?.newEmail.caseInsensitiveCompare(email) == .orderedSame
            })
        }) else { throw AccountStoreError.duplicateAccountEmail }
        guard !emailAliases.contains(where: { alias in
            emails.contains(where: { alias.email.caseInsensitiveCompare($0) == .orderedSame }) &&
                (alias.status != .available || alias.accountID != nil) && alias.accountID != account.id
        }) else { throw AccountStoreError.emailAliasUnavailable }
        if let pending = account.pendingEmailChange {
            guard pending.originalEmail == account.email,
                  emailAliases.contains(where: {
                      $0.id == pending.aliasID && $0.email == pending.newEmail &&
                          $0.status == .reserved && $0.accountID == account.id
                  }), !accounts.contains(where: { $0.pendingEmailChange?.aliasID == pending.aliasID })
            else { throw AccountStoreError.emailAliasUnavailable }
        }

        var candidateGroups = groups
        if let groupID = account.groupID, !groups.contains(where: { $0.id == groupID }) {
            if var group = snapshot.group {
                if let existing = groups.first(where: { $0.name.caseInsensitiveCompare(group.name) == .orderedSame }) {
                    account.groupID = existing.id
                } else {
                    group.id = groupID
                    candidateGroups.append(group)
                }
            } else {
                account.groupID = nil
            }
        }
        let candidateAccounts = accounts + [account]
        try commit(
            groups: candidateGroups,
            accounts: candidateAccounts,
            deletedAccounts: deletedAccounts.filter { $0.id != id },
            selectedID: selectedID(for: candidateAccounts))
    }

    func removeDeletedAccountPermanently(id: UUID) throws {
        let candidateDeletedAccounts = deletedAccounts.filter { $0.id != id }
        guard candidateDeletedAccounts.count != deletedAccounts.count else { return }
        try commit(groups: groups, accounts: accounts, deletedAccounts: candidateDeletedAccounts,
                   selectedID: selectedID(for: accounts))
    }

    private func deletedSnapshot(_ account: AccountRecord) -> DeletedAccountSnapshot {
        DeletedAccountSnapshot(account: account, group: groups.first(where: { $0.id == account.groupID }))
    }

    func accounts(in groupID: UUID) -> [AccountRecord] {
        accounts.filter { $0.groupID == groupID }
    }

    @discardableResult
    func importEmailAliases(_ text: String) throws -> Int {
        var candidate = emailAliases
        var known = Set(candidate.map { $0.email.lowercased() })
        for token in text.split(whereSeparator: { $0.isWhitespace || $0 == "," || $0 == ";" }) {
            let email = try normalizedEmailAlias(String(token))
            guard !known.contains(email) else { continue }
            guard !accounts.contains(where: {
                $0.email.caseInsensitiveCompare(email) == .orderedSame ||
                $0.pendingEmailChange?.newEmail.caseInsensitiveCompare(email) == .orderedSame
            }) else { throw AccountStoreError.duplicateAccountEmail }
            candidate.append(EmailAlias(email: email))
            known.insert(email)
        }
        let inserted = candidate.count - emailAliases.count
        guard inserted > 0 else { return 0 }
        try commit(groups: groups, accounts: accounts, emailAliases: candidate,
                   selectedID: selectedID(for: accounts))
        return inserted
    }

    func markEmailAliasUsed(id: UUID) throws {
        guard let index = emailAliases.firstIndex(where: { $0.id == id }) else {
            throw AccountStoreError.emailAliasUnavailable
        }
        let alias = emailAliases[index]
        if alias.status == .used { return }
        guard alias.status == .available, alias.accountID == nil,
              !accounts.contains(where: {
                  $0.email.caseInsensitiveCompare(alias.email) == .orderedSame ||
                  $0.pendingEmailChange?.aliasID == id ||
                  $0.pendingEmailChange?.newEmail.caseInsensitiveCompare(alias.email) == .orderedSame
              }) else { throw AccountStoreError.emailAliasUnavailable }
        var candidate = emailAliases
        candidate[index].status = .used
        try commit(groups: groups, accounts: accounts, emailAliases: candidate,
                   selectedID: selectedID(for: accounts))
    }

    func deleteAvailableEmailAlias(id: UUID) throws {
        guard let alias = emailAliases.first(where: { $0.id == id }),
              alias.status == .available,
              !accounts.contains(where: { $0.pendingEmailChange?.aliasID == id })
        else { throw AccountStoreError.emailAliasUnavailable }
        try commit(groups: groups, accounts: accounts,
                   emailAliases: emailAliases.filter { $0.id != id },
                   selectedID: selectedID(for: accounts))
    }

    @discardableResult
    func reserveEmailChange(id: UUID, alias: String? = nil) throws -> PendingEmailChange {
        guard let accountIndex = accounts.firstIndex(where: { $0.id == id }) else {
            throw AccountStoreError.emailChangeNotFound
        }
        let account = accounts[accountIndex]
        guard account.rotationStage == nil, account.pendingTOTPSecret == nil,
              !account.hasPendingCredentialChange
        else { throw AccountStoreError.accountBusy }
        let requestedEmail = try alias.map(normalizedEmailAlias)
        guard let aliasIndex = emailAliases.firstIndex(where: { candidate in
            candidate.status == .available &&
            (requestedEmail == nil || candidate.email == requestedEmail) &&
            !accounts.contains(where: {
                $0.email.caseInsensitiveCompare(candidate.email) == .orderedSame ||
                $0.pendingEmailChange?.newEmail.caseInsensitiveCompare(candidate.email) == .orderedSame
            })
        }) else { throw AccountStoreError.emailAliasUnavailable }

        let pending = PendingEmailChange(
            aliasID: emailAliases[aliasIndex].id,
            originalEmail: account.email,
            newEmail: emailAliases[aliasIndex].email)
        var candidateAccounts = accounts
        var candidateAliases = emailAliases
        candidateAccounts[accountIndex].pendingEmailChange = pending
        candidateAccounts[accountIndex].status = .needsRecovery
        candidateAccounts[accountIndex].lastError = nil
        candidateAliases[aliasIndex].status = .reserved
        candidateAliases[aliasIndex].accountID = id
        try commit(groups: groups, accounts: candidateAccounts, emailAliases: candidateAliases,
                   selectedID: selectedID(for: candidateAccounts))
        return pending
    }

    @discardableResult
    func replaceEmailChangeAlias(
        id: UUID,
        operationID: UUID,
        alias: String? = nil,
        originalProof: EmailChangeProof? = nil
    ) throws -> PendingEmailChange {
        let (accountIndex, previousAliasIndex) = try emailChangeIndices(id: id)
        let account = accounts[accountIndex]
        let current = account.pendingEmailChange!
        guard current.operationID == operationID else {
            throw AccountStoreError.invalidEmailChangeCheckpoint
        }
        guard account.rotationStage == nil, account.pendingTOTPSecret == nil,
              !account.hasPendingAccessChange
        else { throw AccountStoreError.accountBusy }
        guard current.phase == .reserved || originalProof != nil else {
            throw AccountStoreError.emailChangeVerificationFailed
        }
        if let originalProof {
            guard originalProof.email.caseInsensitiveCompare(current.originalEmail) == .orderedSame,
                  !originalProof.userID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  current.originalUserID == nil || current.originalUserID == originalProof.userID,
                  current.phase == .reserved || current.originalUserID != nil
            else { throw AccountStoreError.emailChangeVerificationFailed }
        }
        let requestedEmail = try alias.map(normalizedEmailAlias)
        guard let aliasIndex = emailAliases.firstIndex(where: { candidate in
            candidate.status == .available && candidate.accountID == nil &&
            (requestedEmail == nil || candidate.email == requestedEmail) &&
            emailAliases.filter({
                $0.email.caseInsensitiveCompare(candidate.email) == .orderedSame
            }).count == 1 &&
            !accounts.contains(where: {
                $0.email.caseInsensitiveCompare(candidate.email) == .orderedSame ||
                $0.pendingEmailChange?.newEmail.caseInsensitiveCompare(candidate.email) == .orderedSame ||
                $0.pendingEmailChange?.aliasID == candidate.id
            })
        }) else { throw AccountStoreError.emailAliasUnavailable }

        let pending = PendingEmailChange(
            aliasID: emailAliases[aliasIndex].id,
            originalEmail: current.originalEmail,
            newEmail: emailAliases[aliasIndex].email,
            originalUserID: current.originalUserID ?? originalProof?.userID)
        var candidateAccounts = accounts
        var candidateAliases = emailAliases
        candidateAccounts[accountIndex].pendingEmailChange = pending
        candidateAccounts[accountIndex].status = .needsRecovery
        candidateAccounts[accountIndex].lastError = nil
        // The user reported this address occupied elsewhere; never recycle it.
        candidateAliases[previousAliasIndex].status = .used
        candidateAliases[previousAliasIndex].accountID = nil
        candidateAliases[aliasIndex].status = .reserved
        candidateAliases[aliasIndex].accountID = id
        try commit(groups: groups, accounts: candidateAccounts, emailAliases: candidateAliases,
                   selectedID: selectedID(for: candidateAccounts))
        return pending
    }

    func checkpointEmailChange(id: UUID, change: PendingEmailChange) throws {
        let (accountIndex, _) = try emailChangeIndices(id: id)
        let current = accounts[accountIndex].pendingEmailChange!
        let phases: [EmailChangePhase] = [.reserved, .requested, .confirming]
        let currentPhase = phases.firstIndex(of: current.phase)!
        let nextPhase = phases.firstIndex(of: change.phase)!
        let startsNewRequestAttempt: Bool
        if current.phase == .requested, change.phase == .requested,
           let attemptID = change.requestAttemptID, attemptID != current.requestAttemptID,
           let requestedAt = change.requestedAt, let previousRequestedAt = current.requestedAt {
            startsNewRequestAttempt = requestedAt >= previousRequestedAt
        } else {
            startsNewRequestAttempt = false
        }
        guard change.aliasID == current.aliasID,
              change.operationID == current.operationID,
              change.originalEmail == current.originalEmail,
              change.newEmail == current.newEmail,
              nextPhase == currentPhase || nextPhase == currentPhase + 1,
              current.originalUserID == nil || change.originalUserID == current.originalUserID,
              change.originalUserID.map({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) ?? true,
              current.phase == .reserved || startsNewRequestAttempt ||
                (change.baselineMessageIDs == current.baselineMessageIDs &&
                 change.requestedAt == current.requestedAt &&
                 change.requestAttemptID == current.requestAttemptID),
              change.phase == .reserved ||
                (change.requestedAt != nil && change.originalUserID != nil)
        else { throw AccountStoreError.invalidEmailChangeCheckpoint }
        var candidate = accounts
        candidate[accountIndex].pendingEmailChange = change
        candidate[accountIndex].status = .needsRecovery
        try commit(groups: groups, accounts: candidate, selectedID: selectedID(for: candidate))
    }

    func completeEmailChange(id: UUID, proof: EmailChangeProof) throws {
        let (accountIndex, aliasIndex) = try emailChangeIndices(id: id)
        let pending = accounts[accountIndex].pendingEmailChange!
        guard pending.phase == .confirming,
              proof.email.caseInsensitiveCompare(pending.newEmail) == .orderedSame,
              let originalUserID = pending.originalUserID, !originalUserID.isEmpty,
              proof.userID == originalUserID,
              !accounts.contains(where: {
                  $0.id != id &&
                  ($0.email.caseInsensitiveCompare(pending.newEmail) == .orderedSame ||
                   $0.pendingEmailChange?.newEmail.caseInsensitiveCompare(pending.newEmail) == .orderedSame)
              })
        else { throw AccountStoreError.emailChangeVerificationFailed }
        var candidateAccounts = accounts
        var candidateAliases = emailAliases
        candidateAccounts[accountIndex].email = pending.newEmail
        candidateAccounts[accountIndex].pendingEmailChange = nil
        candidateAccounts[accountIndex].status = .ready
        candidateAccounts[accountIndex].lastError = nil
        candidateAliases[aliasIndex].status = .used
        try commit(groups: groups, accounts: candidateAccounts, emailAliases: candidateAliases,
                   selectedID: selectedID(for: candidateAccounts))
    }

    func cancelUnsubmittedEmailChange(id: UUID) throws {
        let (accountIndex, aliasIndex) = try emailChangeIndices(id: id)
        guard accounts[accountIndex].pendingEmailChange?.phase == .reserved else {
            throw AccountStoreError.emailChangeAlreadyRequested
        }
        var candidateAccounts = accounts
        var candidateAliases = emailAliases
        candidateAccounts[accountIndex].pendingEmailChange = nil
        candidateAccounts[accountIndex].status = .unchecked
        candidateAccounts[accountIndex].lastError = nil
        candidateAliases[aliasIndex].status = .available
        candidateAliases[aliasIndex].accountID = nil
        try commit(groups: groups, accounts: candidateAccounts, emailAliases: candidateAliases,
                   selectedID: selectedID(for: candidateAccounts))
    }

    /// Leave local recovery without claiming that a submitted remote change was undone.
    func abandonEmailChange(id: UUID, operationID: UUID) throws {
        let (accountIndex, aliasIndex) = try emailChangeIndices(id: id)
        let pending = accounts[accountIndex].pendingEmailChange!
        guard pending.operationID == operationID else {
            throw AccountStoreError.invalidEmailChangeCheckpoint
        }
        var candidateAccounts = accounts
        var candidateAliases = emailAliases
        candidateAccounts[accountIndex].abandonedEmailChange = pending
        candidateAccounts[accountIndex].pendingEmailChange = nil
        candidateAccounts[accountIndex].status = .unchecked
        candidateAccounts[accountIndex].lastError = pending.phase == .reserved ? nil :
            "Смена email закрыта без проверки. Сохранён прежний логин; возможный новый email: \(pending.newEmail)."
        candidateAliases[aliasIndex].status = pending.phase == .reserved ? .available : .used
        candidateAliases[aliasIndex].accountID = pending.phase == .reserved ? nil : id
        try commit(groups: groups, accounts: candidateAccounts, emailAliases: candidateAliases,
                   selectedID: selectedID(for: candidateAccounts))
    }

    func restoreAbandonedEmailChange(id: UUID) throws {
        guard let accountIndex = accounts.firstIndex(where: { $0.id == id }),
              let pending = accounts[accountIndex].abandonedEmailChange else {
            throw AccountStoreError.emailChangeNotFound
        }
        let account = accounts[accountIndex]
        guard account.rotationStage == nil, account.pendingTOTPSecret == nil,
              !account.hasPendingCredentialChange else { throw AccountStoreError.accountBusy }
        guard account.email == pending.originalEmail else {
            throw AccountStoreError.invalidEmailChangeCheckpoint
        }
        guard let aliasIndex = emailAliases.firstIndex(where: {
            $0.id == pending.aliasID && $0.email == pending.newEmail &&
            (pending.phase == .reserved ? ($0.status == .available && $0.accountID == nil) :
                ($0.status == .used && $0.accountID == id))
        }), !accounts.contains(where: {
            $0.email.caseInsensitiveCompare(pending.newEmail) == .orderedSame ||
            $0.pendingEmailChange?.newEmail.caseInsensitiveCompare(pending.newEmail) == .orderedSame ||
            $0.pendingEmailChange?.aliasID == pending.aliasID
        }) else { throw AccountStoreError.emailAliasUnavailable }
        var candidateAccounts = accounts
        var candidateAliases = emailAliases
        candidateAccounts[accountIndex].pendingEmailChange = pending
        candidateAccounts[accountIndex].abandonedEmailChange = nil
        candidateAccounts[accountIndex].status = .needsRecovery
        candidateAccounts[accountIndex].lastError = nil
        candidateAliases[aliasIndex].status = .reserved
        candidateAliases[aliasIndex].accountID = id
        try commit(groups: groups, accounts: candidateAccounts, emailAliases: candidateAliases,
                   selectedID: selectedID(for: candidateAccounts))
    }

    private func emailChangeIndices(id: UUID) throws -> (account: Int, alias: Int) {
        guard let accountIndex = accounts.firstIndex(where: { $0.id == id }),
              let pending = accounts[accountIndex].pendingEmailChange,
              accounts[accountIndex].email == pending.originalEmail,
              let aliasIndex = emailAliases.firstIndex(where: {
                  $0.id == pending.aliasID && $0.email == pending.newEmail &&
                  $0.status == .reserved && $0.accountID == id
              })
        else { throw AccountStoreError.emailChangeNotFound }
        return (accountIndex, aliasIndex)
    }

    private func normalizedEmailAlias(_ value: String) throws -> String {
        let email = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let parts = email.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[1] == "icloud.com",
              !parts[0].isEmpty, parts[0].count <= 64,
              parts[0].first != ".", parts[0].last != ".", !parts[0].contains(".."),
              parts[0].allSatisfy({ "abcdefghijklmnopqrstuvwxyz0123456789._+-".contains($0) })
        else { throw AccountStoreError.invalidEmailAlias }
        return email
    }

    private func normalizedGroupName(_ value: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw AccountStoreError.groupNameRequired }
        return trimmed
    }

    private func normalizedTag(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private func selectedID(for candidateAccounts: [AccountRecord]) -> UUID? {
        guard let selectedID,
              candidateAccounts.contains(where: { $0.id == selectedID })
        else { return candidateAccounts.first?.id }
        return selectedID
    }

    private func commit(
        groups candidateGroups: [AccountGroup],
        accounts candidateAccounts: [AccountRecord],
        emailAliases candidateAliases: [EmailAlias]? = nil,
        deletedAccounts candidateDeletedAccounts: [DeletedAccountSnapshot]? = nil,
        selectedID candidateSelectedID: UUID?
    ) throws {
        var candidateAccounts = candidateAccounts
        let previousByID = Dictionary(accounts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for index in candidateAccounts.indices {
            let candidate = candidateAccounts[index]
            guard let previous = previousByID[candidate.id] else { continue }
            let loginEmailChanged = candidate.email.caseInsensitiveCompare(previous.email) != .orderedSame
            if loginEmailChanged {
                candidateAccounts[index].externalMailbox = nil
            }
            // Keep explicitly replaced tokens; invalidate cached tokens when their login changes.
            if candidate.accessToken == previous.accessToken,
                loginEmailChanged ||
                candidate.password != previous.password || candidate.totpSecret != previous.totpSecret ||
                candidate.browserStoreID != previous.browserStoreID {
                candidateAccounts[index].accessToken = nil
            }
        }
        var aliases = candidateAliases ?? emailAliases
        // Manual imports/edits can also associate a pool address with an account.
        // Keep that address consumed even if the account is later removed.
        for index in aliases.indices where aliases[index].status == .available {
            if let account = candidateAccounts.first(where: {
                $0.email.caseInsensitiveCompare(aliases[index].email) == .orderedSame
            }) {
                aliases[index].status = .used
                aliases[index].accountID = account.id
            }
        }
        let candidateDeletedAccounts = candidateDeletedAccounts ?? deletedAccounts
        try persist(groups: candidateGroups, accounts: candidateAccounts, emailAliases: aliases,
                    deletedAccounts: candidateDeletedAccounts)
        groups = candidateGroups
        accounts = candidateAccounts
        emailAliases = aliases
        deletedAccounts = candidateDeletedAccounts
        selectedID = candidateSelectedID
    }

    private func persist(
        groups candidateGroups: [AccountGroup],
        accounts candidateAccounts: [AccountRecord],
        emailAliases candidateAliases: [EmailAlias],
        deletedAccounts candidateDeletedAccounts: [DeletedAccountSnapshot]
    ) throws {
        let fileManager = FileManager.default
        let directory = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directory.path)
        try verifyPermissions(of: directory, expected: 0o700)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(PersistedAccountData(
            groups: candidateGroups,
            accounts: candidateAccounts,
            emailAliases: candidateAliases,
            deletedAccounts: candidateDeletedAccounts))
        let temporaryURL = directory.appendingPathComponent(
            ".accounts-\(UUID().uuidString).tmp")
        guard fileManager.createFile(
            atPath: temporaryURL.path,
            contents: nil,
            attributes: [.posixPermissions: 0o600])
        else { throw AccountStoreError.temporaryFileCreationFailed }

        var temporaryFileExists = true
        defer {
            if temporaryFileExists {
                try? fileManager.removeItem(at: temporaryURL)
            }
        }

        let handle = try FileHandle(forWritingTo: temporaryURL)
        do {
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }
        try verifyPermissions(of: temporaryURL, expected: 0o600)

        if fileManager.fileExists(atPath: fileURL.path) {
            _ = try fileManager.replaceItemAt(
                fileURL,
                withItemAt: temporaryURL,
                backupItemName: nil,
                options: [.usingNewMetadataOnly])
        } else {
            try fileManager.moveItem(at: temporaryURL, to: fileURL)
        }
        temporaryFileExists = false
        try verifyPermissions(of: fileURL, expected: 0o600)
    }

    private func verifyPermissions(of url: URL, expected: Int) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let permissions = attributes[.posixPermissions] as? NSNumber,
              permissions.intValue == expected
        else { throw AccountStoreError.insecurePermissions }
    }
}
