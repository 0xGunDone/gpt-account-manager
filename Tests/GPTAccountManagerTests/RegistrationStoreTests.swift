import Foundation
import Testing
@testable import GPTAccountManager

@MainActor
@Suite struct RegistrationStoreTests {
    private let secret = "JBSWY3DPEHPK3PXP"
    private let setupToken = "fixture-setup-access-token.not-a-live-secret"
    private let proof = CleanLoginProof(passwordSubmitted: true, pendingOTPSubmitted: true,
                                        authenticatedImmediatelyAfterPendingOTP: true)

    private func store() -> AccountStore {
        AccountStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true).appendingPathComponent("accounts.json"))
    }

    private func begin(_ store: AccountStore, email: String = "new@icloud.com") throws -> AccountRecord {
        try store.beginRegistration(email: email, fullName: "Test Person", age: 28, password: "fixture-password")
    }

    private func snapshot(_ email: String = "new@icloud.com") -> SubscriptionSnapshot {
        .init(signedInEmail: email, planLabel: "free", activeUntil: nil, willRenew: nil)
    }

    private func verification(_ account: AccountRecord) throws -> PendingRegistration {
        var pending = try #require(account.pendingRegistration)
        pending.phase = .verifyingLogin
        pending.passwordWasSubmitted = true
        pending.pendingSecret = secret
        return pending
    }

    @Test func deactivatedDraftDeletionKeepsOtherRecordsAndConsumedAlias() throws {
        let store = store()
        defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
        try store.importEmailAliases("blocked@icloud.com")
        let blocked = try begin(store, email: "blocked@icloud.com")
        try store.mutate(id: blocked.id) { $0.lastError = RegistrationCoordinator.deactivatedAccountMessage }
        try store.merge([.init(email: "other@example.com", password: "fixture", totpSecret: secret)])
        let other = try #require(store.accounts.last)
        store.selectedID = other.id
        #expect(throws: AccountStoreError.accountBusy) {
            try store.deleteAccount(id: blocked.id, protectedIDs: [])
        }
        try store.deleteDeactivatedRegistration(id: blocked.id, expectedError: RegistrationCoordinator.deactivatedAccountMessage,
                                               protectedIDs: [])
        #expect(store.accounts == [other] && store.selectedID == other.id)
        #expect(store.emailAliases.first?.status == .used)
        let reloaded = AccountStore(fileURL: store.fileURL)
        try reloaded.load()
        #expect(reloaded.accounts == [other] && reloaded.emailAliases.first?.status == .used)
    }

    @Test func deactivatedDraftDeletionChecksProofProtectionAndPersistence() throws {
        let store = store()
        let directory = store.fileURL.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }
        let draft = try begin(store)
        #expect(throws: AccountStoreError.accountBusy) {
            try store.deleteDeactivatedRegistration(id: draft.id, expectedError: RegistrationCoordinator.deactivatedAccountMessage,
                                                   protectedIDs: [])
        }
        try store.mutate(id: draft.id) { $0.lastError = RegistrationCoordinator.deactivatedAccountMessage }
        #expect(throws: AccountStoreError.accountBusy) {
            try store.deleteDeactivatedRegistration(id: draft.id, expectedError: RegistrationCoordinator.deactivatedAccountMessage,
                                                   protectedIDs: [draft.id])
        }
        #expect(throws: AccountStoreError.accountBusy) {
            try store.deleteDeactivatedRegistration(id: draft.id, expectedError: "unrelated error", protectedIDs: [])
        }
        let before = store.accounts
        try FileManager.default.removeItem(at: directory)
        try Data("blocked path".utf8).write(to: directory)
        #expect(throws: (any Error).self) {
            try store.deleteDeactivatedRegistration(id: draft.id, expectedError: RegistrationCoordinator.deactivatedAccountMessage,
                                                   protectedIDs: [])
        }
        #expect(store.accounts == before)
    }

    @Test func profileRetryCheckpointSurvivesReloadAndCannotBeReset() throws {
        let store = store()
        defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
        let draft = try begin(store)
        var pending = try #require(draft.pendingRegistration)
        let legacy = try JSONDecoder().decode(PendingRegistration.self, from: JSONEncoder().encode(pending))
        #expect(legacy.profileRetryUsed == nil)
        pending.profileRetryUsed = true
        try store.checkpointRegistration(id: draft.id, registration: pending)
        let reloaded = AccountStore(fileURL: store.fileURL)
        try reloaded.load()
        #expect(reloaded.accounts.first?.pendingRegistration?.profileRetryUsed == true)
        pending.profileRetryUsed = nil
        #expect(throws: AccountStoreError.invalidRegistrationCheckpoint) {
            try reloaded.checkpointRegistration(id: draft.id, registration: pending)
        }
    }

    @Test func draftPersistsIsolatedWithoutReadyGroupOrPlaceholderSecret() throws {
        let store = store()
        defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
        try store.merge([.init(email: "existing@example.com", password: "old", totpSecret: secret)])
        let original = try #require(store.accounts.first)
        let draft = try begin(store, email: " NEW@ICLOUD.COM ")
        #expect(draft.email == "new@icloud.com")
        #expect(draft.id != original.id && draft.browserStoreID != original.browserStoreID)
        #expect(draft.totpSecret.isEmpty && draft.groupID == nil && draft.status == .needsRecovery)
        #expect(draft.hasPendingCredentialChange)
        #expect(store.groups.isEmpty)
        var pending = try #require(draft.pendingRegistration)
        pending.phase = .awaitingEmailCode
        pending.passwordWasSubmitted = true
        pending.requestedAt = Date(timeIntervalSince1970: 1_800_000_000)
        pending.baselineMessageIDs = ["already-seen"]
        try store.checkpointRegistration(id: draft.id, registration: pending)
        let reloaded = AccountStore(fileURL: store.fileURL)
        try reloaded.load()
        #expect(reloaded.accounts.first == original)
        #expect(reloaded.accounts.last?.pendingRegistration == pending)
        #expect(reloaded.accounts.last?.browserStoreID == draft.browserStoreID)
        #expect(reloaded.accounts.last?.status == .needsRecovery)
    }

    @Test func draftsRejectDuplicateOrInvalidInputsAndGenericCredentialActions() throws {
        let store = store()
        defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
        let draft = try begin(store)
        #expect(throws: AccountStoreError.duplicateAccountEmail) { try begin(store, email: "NEW@ICLOUD.COM") }
        for (email, name, age, password) in [("bad", "Name", 25, "p"), ("other@icloud.com", " ", 25, "p"),
                                             ("other@icloud.com", "Name", 17, "p"), ("other@icloud.com", "Name", 101, "p"),
                                             ("other@icloud.com", "Name", 25, "")] {
            #expect(throws: AccountStoreError.invalidRegistration) {
                try store.beginRegistration(email: email, fullName: name, age: age, password: password)
            }
        }
        #expect(throws: AccountStoreError.rotationRecoveryActive) {
            try store.merge([.init(email: draft.email, password: "replacement", totpSecret: secret)])
        }
        #expect(throws: AccountStoreError.accountBusy) {
            try store.mutate(id: draft.id) { $0.pendingRegistration = nil; $0.status = .ready }
        }
        #expect(throws: AccountStoreError.accountBusy) {
            try store.moveAccounts(ids: [draft.id], to: nil, protectedIDs: [])
        }
        try store.merge([.init(email: "old@example.com", password: "old", totpSecret: secret)])
        let old = try #require(store.accounts.last)
        try store.importEmailAliases("reserved@icloud.com")
        _ = try store.reserveEmailChange(id: old.id)
        #expect(throws: AccountStoreError.duplicateAccountEmail) { try begin(store, email: "reserved@icloud.com") }
        #expect(store.accounts.first == draft)
    }

    @Test func readinessRequiresPhasePasswordIdentitySecretAndCleanLoginProof() throws {
        let store = store()
        defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
        let draft = try begin(store)
        #expect(throws: AccountStoreError.registrationVerificationFailed) {
            try store.completeRegistration(id: draft.id, verifiedEmail: draft.email, secret: secret, proof: proof, snapshot: snapshot())
        }
        var pending = try verification(draft)
        pending.passwordWasSubmitted = false
        try store.checkpointRegistration(id: draft.id, registration: pending)
        #expect(throws: AccountStoreError.registrationVerificationFailed) {
            try store.completeRegistration(id: draft.id, verifiedEmail: draft.email, secret: secret, proof: proof, snapshot: snapshot())
        }
        pending.passwordWasSubmitted = true
        try store.checkpointRegistration(id: draft.id, registration: pending)
        for (email, secretValue, loginProof, subscription) in [
            ("other@icloud.com", secret, proof, snapshot()),
            (draft.email, "KRUGS4ZANFZSAYJA", proof, snapshot()),
            (draft.email, secret, CleanLoginProof.none, snapshot()),
            (draft.email, secret, proof, snapshot("other@icloud.com")),
        ] {
            #expect(throws: AccountStoreError.registrationVerificationFailed) {
                try store.completeRegistration(id: draft.id, verifiedEmail: email, secret: secretValue,
                                               proof: loginProof, snapshot: subscription)
            }
            #expect(store.groups.isEmpty)
            #expect(store.accounts[0].status == .needsRecovery && store.accounts[0].totpSecret.isEmpty)
        }
        let unchanged = store.accounts
        pending.pendingSecret = "KRUGS4ZANFZSAYJA"
        #expect(throws: AccountStoreError.invalidRegistrationCheckpoint) {
            try store.checkpointRegistration(id: draft.id, registration: pending)
        }
        #expect(store.accounts == unchanged)
    }

    @Test func setupCompletionSavesAccountTokenGroupAndOriginalBrowserSession() throws {
        let store = store()
        defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
        try store.importEmailAliases("new@icloud.com")
        let draft = try begin(store)
        try store.checkpointRegistration(id: draft.id, registration: verification(draft))

        try store.completeRegistrationAfterSetup(id: draft.id, verifiedEmail: draft.email.uppercased(), secret: secret,
                                                authenticatorEnabled: true, snapshot: snapshot(), accessToken: setupToken)

        let saved = try #require(store.accounts.first)
        #expect(saved.id == draft.id && saved.browserStoreID == draft.browserStoreID)
        #expect(saved.email == draft.email && saved.password == draft.password && saved.totpSecret == secret)
        #expect(saved.accessToken == setupToken && saved.accessTokenLine == "\(draft.email)|\(setupToken)")
        #expect(saved.pendingRegistration == nil && saved.status == .ready && saved.lastCheckedAt != nil)
        #expect(saved.lastError == nil && saved.planLabel == "free")
        #expect(saved.groupID == store.groups.first(where: { $0.name == "new-novoreg" })?.id)
        #expect(store.emailAliases.first?.status == .used)
        let reloaded = AccountStore(fileURL: store.fileURL)
        try reloaded.load()
        let persisted = try #require(reloaded.accounts.first)
        #expect(persisted.id == saved.id && persisted.browserStoreID == saved.browserStoreID)
        #expect(persisted.accessToken == setupToken && persisted.totpSecret == secret && persisted.status == .ready)
        #expect(persisted.pendingRegistration == nil && persisted.groupID == saved.groupID)
        #expect(reloaded.groups == store.groups)
    }

    @Test(arguments: ["authenticator", "email", "snapshotEmail", "secret", "missingSecret", "password", "phase"])
    func setupCompletionRejectsMissingEvidenceWithoutPublishingReadyAccount(evidence: String) throws {
        let store = store()
        defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
        let draft = try begin(store)
        var pending = try verification(draft)
        if evidence == "missingSecret" { pending.pendingSecret = nil }
        if evidence == "password" { pending.passwordWasSubmitted = false }
        if evidence == "phase" { pending.phase = .enablingTwoFA }
        try store.checkpointRegistration(id: draft.id, registration: pending)
        let before = store.accounts

        #expect(throws: AccountStoreError.registrationVerificationFailed) {
            try store.completeRegistrationAfterSetup(
                id: draft.id,
                verifiedEmail: evidence == "email" ? "other@icloud.com" : draft.email,
                secret: evidence == "secret" ? "KRUGS4ZANFZSAYJA" : secret,
                authenticatorEnabled: evidence != "authenticator",
                snapshot: snapshot(evidence == "snapshotEmail" ? "other@icloud.com" : draft.email),
                accessToken: setupToken)
        }

        #expect(store.accounts == before && store.groups.isEmpty)
        let reloaded = AccountStore(fileURL: store.fileURL)
        try reloaded.load()
        #expect(reloaded.accounts == before && reloaded.groups.isEmpty)
    }

    @Test(arguments: ["", " \t\n", "fixture|invalid-token", "fixture\ninvalid-token"])
    func setupCompletionRequiresValidNonemptyToken(token: String) throws {
        let store = store()
        defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
        let draft = try begin(store)
        try store.checkpointRegistration(id: draft.id, registration: verification(draft))
        let before = store.accounts

        #expect(throws: AccountStoreError.invalidAccessToken) {
            try store.completeRegistrationAfterSetup(id: draft.id, verifiedEmail: draft.email, secret: secret,
                                                    authenticatorEnabled: true, snapshot: snapshot(), accessToken: token)
        }

        #expect(store.accounts == before && store.groups.isEmpty)
    }

    @Test func failedSetupCompletionDoesNotPublishReadyAccountOrGroup() throws {
        let store = store()
        let directory = store.fileURL.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }
        let draft = try begin(store)
        try store.checkpointRegistration(id: draft.id, registration: verification(draft))
        let before = store.accounts
        try FileManager.default.removeItem(at: directory)
        try Data("blocked path".utf8).write(to: directory)

        #expect(throws: (any Error).self) {
            try store.completeRegistrationAfterSetup(id: draft.id, verifiedEmail: draft.email, secret: secret,
                                                    authenticatorEnabled: true, snapshot: snapshot(), accessToken: setupToken)
        }

        #expect(store.accounts == before && store.groups.isEmpty)
    }

    @Test(arguments: [false, true])
    func alreadyCreatedAccountCanLeaveRegistrationWithoutClaimingReadiness(failed: Bool) throws {
        let store = store()
        defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
        try store.importEmailAliases("new@icloud.com")
        let draft = try begin(store)
        try store.checkpointRegistration(id: draft.id, registration: verification(draft))
        let failure = failed ? "Аккаунт OpenAI удалён или деактивирован." : nil
        try store.saveRegistrationAsUnverifiedAccount(id: draft.id, failure: failure)
        let saved = try #require(store.accounts.first)
        #expect(saved.pendingRegistration == nil && !saved.hasPendingCredentialChange)
        #expect(saved.id == draft.id && saved.browserStoreID == draft.browserStoreID)
        #expect(saved.email == draft.email && saved.password == draft.password && saved.totpSecret == secret)
        #expect(saved.status == (failed ? .failed : .unchecked))
        #expect(saved.lastCheckedAt == nil && saved.groupID == nil && store.groups.isEmpty)
        #expect(saved.lastError != nil && store.emailAliases.first?.status == .used)
        let reloaded = AccountStore(fileURL: store.fileURL)
        try reloaded.load()
        #expect(reloaded.accounts == [saved])
    }

    @Test func earlyDraftCannotBeConvertedAndFailedSaveKeepsItsCredentials() throws {
        let store = store()
        let directory = store.fileURL.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }
        let draft = try begin(store)
        #expect(throws: AccountStoreError.invalidRegistrationCheckpoint) {
            try store.saveRegistrationAsUnverifiedAccount(id: draft.id)
        }
        try store.checkpointRegistration(id: draft.id, registration: verification(draft))
        let before = store.accounts
        try FileManager.default.removeItem(at: directory)
        try Data("blocked-directory".utf8).write(to: directory)
        #expect(throws: (any Error).self) { try store.saveRegistrationAsUnverifiedAccount(id: draft.id) }
        #expect(store.accounts == before)
    }

    @Test func completionCreatesOrReusesGroupWithoutChangingOtherAccountSessions() throws {
        let store = store()
        defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
        try store.merge([.init(email: "existing@example.com", password: "old", totpSecret: secret)])
        let existing = try #require(store.accounts.first)
        let oldGroup = try store.createGroup(name: "Existing group", tag: "keep")
        try store.moveAccounts(ids: [existing.id], to: oldGroup.id, protectedIDs: [])
        let original = store.accounts[0]
        for address in ["new@icloud.com", "another@icloud.com"] {
            let draft = try begin(store, email: address)
            try store.checkpointRegistration(id: draft.id, registration: verification(draft))
            try store.completeRegistration(id: draft.id, verifiedEmail: address.uppercased(), secret: secret,
                                           proof: proof, snapshot: snapshot(address))
            let completed = try #require(store.accounts.first(where: { $0.id == draft.id }))
            #expect(completed.browserStoreID == draft.browserStoreID)
            #expect(completed.pendingRegistration == nil && completed.totpSecret == secret)
            #expect(completed.status == .ready && completed.lastCheckedAt != nil && completed.planLabel == "free")
            #expect(completed.groupID == store.groups.first(where: { $0.name == "new-novoreg" })?.id)
        }
        #expect(store.accounts[0] == original && store.groups[0] == oldGroup)
        #expect(store.groups.filter { $0.name == "new-novoreg" }.count == 1)
        let reloaded = AccountStore(fileURL: store.fileURL)
        try reloaded.load()
        #expect(reloaded.accounts.map(\.browserStoreID) == store.accounts.map(\.browserStoreID))
        #expect(reloaded.groups == store.groups)
    }

    @Test func installedPasswordPersistsWithoutCompletingRegistrationOrChangingOtherFields() throws {
        let store = store()
        defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
        try store.merge([.init(email: "existing@example.com", password: "old", totpSecret: secret)])
        let original = try #require(store.accounts.first)
        let group = try store.createGroup(name: "Existing group", tag: "keep")
        let draft = try begin(store)
        var pending = try verification(draft)
        pending.requestedAt = Date(timeIntervalSince1970: 1_800_000_000)
        pending.baselineMessageIDs = ["already-seen"]
        try store.checkpointRegistration(id: draft.id, registration: pending)
        _ = try store.replaceAccountProxy(id: draft.id, expectedProxy: nil,
                                          proxy: .init(scheme: .http, host: "proxy.example.com", port: 8080))
        try store.mutate(id: draft.id) {
            $0.tag = "keep"
            $0.lastError = "Retry login"
        }
        var expected = try #require(store.accounts.last)
        let password = "  externally-set-password\t"
        expected.password = password
        try store.updateRegistrationPassword(id: draft.id, password: password)
        #expect(store.accounts == [original, expected])
        #expect(store.groups == [group] && store.selectedID == draft.id)
        #expect(expected.status == .needsRecovery && expected.totpSecret.isEmpty && expected.groupID == nil)
        let reloaded = AccountStore(fileURL: store.fileURL)
        try reloaded.load()
        #expect(reloaded.accounts == store.accounts && reloaded.groups == store.groups)
    }

    @Test func installedPasswordRejectsBlankInputAndIneligibleRegistrationState() throws {
        let store = store()
        defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
        #expect(throws: AccountStoreError.registrationNotFound) {
            try store.updateRegistrationPassword(id: UUID(), password: "replacement")
        }
        let draft = try begin(store)
        #expect(throws: AccountStoreError.invalidRegistrationCheckpoint) {
            try store.updateRegistrationPassword(id: draft.id, password: "replacement")
        }
        var pending = try verification(draft)
        pending.passwordWasSubmitted = false
        try store.checkpointRegistration(id: draft.id, registration: pending)
        #expect(throws: AccountStoreError.invalidRegistrationCheckpoint) {
            try store.updateRegistrationPassword(id: draft.id, password: "replacement")
        }
        pending.passwordWasSubmitted = true
        pending.pendingSecret = nil
        // The captured secret is immutable, so use a separate draft for the missing-secret checkpoint.
        let missingSecret = try begin(store, email: "missing@icloud.com")
        try store.checkpointRegistration(id: missingSecret.id, registration: pending)
        #expect(throws: AccountStoreError.invalidRegistrationCheckpoint) {
            try store.updateRegistrationPassword(id: missingSecret.id, password: "replacement")
        }
        pending.pendingSecret = secret
        try store.checkpointRegistration(id: draft.id, registration: pending)
        let original = store.accounts
        for password in ["", " \t\n", "\u{00A0}"] {
            #expect(throws: AccountStoreError.invalidRegistration) {
                try store.updateRegistrationPassword(id: draft.id, password: password)
            }
        }
        #expect(store.accounts == original && store.groups.isEmpty)
    }

    @Test func failedInstalledPasswordSavePreservesPublishedState() throws {
        let store = store()
        let directory = store.fileURL.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }
        let draft = try begin(store)
        try store.checkpointRegistration(id: draft.id, registration: verification(draft))
        let original = store.accounts
        let selectedID = store.selectedID
        try FileManager.default.removeItem(at: directory)
        try Data("block".utf8).write(to: directory)
        #expect(throws: (any Error).self) {
            try store.updateRegistrationPassword(id: draft.id, password: "externally-set-password")
        }
        #expect(store.accounts == original && store.groups.isEmpty && store.selectedID == selectedID)
    }

    @Test func failedCompletionDoesNotPublishReadyAccountOrGroup() throws {
        let store = store()
        let directory = store.fileURL.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }
        let draft = try begin(store)
        try store.checkpointRegistration(id: draft.id, registration: verification(draft))
        let original = store.accounts
        try FileManager.default.removeItem(at: directory)
        try Data("block".utf8).write(to: directory)
        #expect(throws: (any Error).self) {
            try store.completeRegistration(id: draft.id, verifiedEmail: draft.email, secret: secret, proof: proof, snapshot: snapshot())
        }
        #expect(store.accounts == original && store.groups.isEmpty)
    }
}
