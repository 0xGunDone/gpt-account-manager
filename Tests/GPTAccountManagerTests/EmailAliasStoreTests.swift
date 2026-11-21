import Foundation
import Testing
@testable import GPTAccountManager

@MainActor
@Suite struct EmailAliasStoreTests {
    private func populatedStore() throws -> AccountStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = AccountStore(fileURL: directory.appendingPathComponent("accounts.json"))
        try store.merge([
            .init(email: "old@example.com", password: "old-password", totpSecret: "JBSWY3DPEHPK3PXP"),
            .init(email: "other@example.com", password: "other-password", totpSecret: "KRUGS4ZANFZSAYJA")
        ])
        return store
    }

    private func requestedChange(in store: AccountStore, id: UUID) throws -> PendingEmailChange {
        try store.importEmailAliases("first@icloud.com\nsecond@icloud.com")
        var pending = try store.reserveEmailChange(id: id)
        pending.phase = .requested
        pending.originalUserID = "openai-user-1"
        pending.requestedAt = Date(timeIntervalSince1970: 1_700_000_000)
        pending.baselineMessageIDs = ["message-before-request"]
        try store.checkpointEmailChange(id: id, change: pending)
        return pending
    }

    @Test func oldVersionTwoAndLegacyArrayLoadWithoutAliasFields() throws {
        let store = try populatedStore()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let originalAccounts = store.accounts
        var root = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: store.fileURL)) as? [String: Any])
        root.removeValue(forKey: "emailAliases")
        try JSONSerialization.data(withJSONObject: root).write(to: store.fileURL)

        let versionTwo = AccountStore(fileURL: store.fileURL)
        try versionTwo.load()
        #expect(versionTwo.accounts == originalAccounts)
        #expect(versionTwo.emailAliases.isEmpty)

        try encoder.encode(originalAccounts).write(to: store.fileURL)
        let legacy = AccountStore(fileURL: store.fileURL)
        try legacy.load()
        #expect(legacy.accounts == originalAccounts)
        #expect(legacy.emailAliases.isEmpty)
    }

    @Test func aliasImportDeduplicatesCaseAndRejectsInvalidInputAtomically() throws {
        let store = try populatedStore()
        #expect(try store.importEmailAliases(" FIRST@icloud.com\nfirst@ICLOUD.com; second@icloud.com ") == 2)
        #expect(store.emailAliases.map(\.email) == ["first@icloud.com", "second@icloud.com"])
        #expect(try store.importEmailAliases("FIRST@icloud.com") == 0)
        let original = store.emailAliases

        for invalid in ["valid@icloud.com invalid@example.com", ".bad@icloud.com", "two..dots@icloud.com", "a@icloud.com.evil.test"] {
            #expect(throws: AccountStoreError.invalidEmailAlias) {
                try store.importEmailAliases(invalid)
            }
            #expect(store.emailAliases == original)
        }
    }

    @Test func importRejectsAddressAlreadyUsedByAccount() throws {
        let store = try populatedStore()
        try store.merge([.init(email: "taken@icloud.com", password: "p", totpSecret: "JBSWY3DPEHPK3PXP")])
        #expect(throws: AccountStoreError.duplicateAccountEmail) {
            try store.importEmailAliases("TAKEN@icloud.com")
        }
        #expect(store.emailAliases.isEmpty)
    }

    @Test func reserveSpecificAliasAndPersistRequestSurviveRestart() throws {
        let store = try populatedStore()
        let id = try #require(store.accounts.first?.id)
        let otherID = try #require(store.accounts.last?.id)
        try store.importEmailAliases("first@icloud.com second@icloud.com")
        var pending = try store.reserveEmailChange(id: id, alias: " SECOND@ICLOUD.com ")
        #expect(pending.originalEmail == "old@example.com")
        #expect(pending.newEmail == "second@icloud.com")
        #expect(store.accounts.first?.email == "old@example.com")
        #expect(store.emailAliases[1].status == .reserved)
        #expect(store.emailAliases[1].accountID == id)
        #expect(throws: AccountStoreError.emailAliasUnavailable) {
            try store.reserveEmailChange(id: otherID, alias: "second@icloud.com")
        }
        pending.phase = .requested
        pending.originalUserID = "stable-openai-user"
        pending.requestedAt = Date(timeIntervalSince1970: 1_700_000_000)
        pending.baselineMessageIDs = ["one", "two"]
        try store.checkpointEmailChange(id: id, change: pending)

        let reloaded = AccountStore(fileURL: store.fileURL)
        try reloaded.load()
        #expect(reloaded.accounts.first?.pendingEmailChange == pending)
        #expect(reloaded.accounts.first?.status == .needsRecovery)
        #expect(reloaded.emailAliases == store.emailAliases)
        #expect(try reloaded.reserveEmailChange(id: otherID).newEmail == "first@icloud.com")
    }

    @Test func checkpointRejectsIdentityOperationAndPhaseChanges() throws {
        let store = try populatedStore()
        let id = try #require(store.accounts.first?.id)
        let original = try requestedChange(in: store, id: id)
        var changes: [PendingEmailChange] = []
        var changed = original
        changed.originalUserID = "different-user"
        changes.append(changed)
        changed = original
        changed.operationID = UUID()
        changes.append(changed)
        changed = original
        changed.newEmail = "other@icloud.com"
        changes.append(changed)
        changed = original
        changed.phase = .reserved
        changes.append(changed)
        changed = original
        changed.baselineMessageIDs = []
        changes.append(changed)
        changed = original
        changed.requestedAt = nil
        changes.append(changed)
        for change in changes {
            #expect(throws: AccountStoreError.invalidEmailChangeCheckpoint) {
                try store.checkpointEmailChange(id: id, change: change)
            }
            #expect(store.accounts.first?.pendingEmailChange == original)
        }
    }

    @Test func requestCannotStartWithoutIdentityAndFreshnessCheckpoint() throws {
        let store = try populatedStore()
        let id = try #require(store.accounts.first?.id)
        try store.importEmailAliases("first@icloud.com")
        var pending = try store.reserveEmailChange(id: id)
        pending.phase = .requested
        #expect(throws: AccountStoreError.invalidEmailChangeCheckpoint) {
            try store.checkpointEmailChange(id: id, change: pending)
        }
        pending.phase = .confirming
        pending.originalUserID = "openai-user-1"
        pending.requestedAt = Date()
        #expect(throws: AccountStoreError.invalidEmailChangeCheckpoint) {
            try store.checkpointEmailChange(id: id, change: pending)
        }
        #expect(store.accounts.first?.pendingEmailChange?.phase == .reserved)
    }

    @Test func legacyRequestedCheckpointCanStartNewPersistedRequestAttempt() throws {
        let store = try populatedStore()
        let id = try #require(store.accounts.first?.id)
        let legacy = try requestedChange(in: store, id: id)
        var root = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: store.fileURL)) as? [String: Any])
        var records = try #require(root["accounts"] as? [[String: Any]])
        var persisted = try #require(records[0]["pendingEmailChange"] as? [String: Any])
        persisted.removeValue(forKey: "requestAttemptID")
        records[0]["pendingEmailChange"] = persisted
        root["accounts"] = records
        try JSONSerialization.data(withJSONObject: root).write(to: store.fileURL)
        let reloaded = AccountStore(fileURL: store.fileURL)
        try reloaded.load()
        #expect(reloaded.accounts.first?.pendingEmailChange == legacy)

        var retry = try #require(reloaded.accounts.first?.pendingEmailChange)
        retry.requestAttemptID = UUID()
        retry.requestedAt = try #require(legacy.requestedAt).addingTimeInterval(60)
        retry.baselineMessageIDs = ["message-before-request", "previous-request-code"]
        try reloaded.checkpointEmailChange(id: id, change: retry)
        let resumed = AccountStore(fileURL: store.fileURL)
        try resumed.load()
        #expect(resumed.accounts.first?.pendingEmailChange == retry)
        #expect(resumed.accounts.first?.email == legacy.originalEmail)
        #expect(resumed.emailAliases.first?.status == .reserved)
        #expect(retry.operationID == legacy.operationID)

        var next = retry
        next.requestAttemptID = UUID()
        next.baselineMessageIDs.insert("second-request-code")
        try resumed.checkpointEmailChange(id: id, change: next)
        #expect(resumed.accounts.first?.pendingEmailChange == next)
    }

    @Test func requestedRetryRequiresNewAttemptNondecreasingTimeAndSameIdentity() throws {
        let store = try populatedStore()
        let id = try #require(store.accounts.first?.id)
        var original = try requestedChange(in: store, id: id)
        original.requestAttemptID = UUID()
        try store.checkpointEmailChange(id: id, change: original)
        var invalid: [PendingEmailChange] = []
        var changed = original
        changed.baselineMessageIDs.insert("fresh-message")
        invalid.append(changed)
        changed = original
        changed.requestedAt = try #require(original.requestedAt).addingTimeInterval(60)
        invalid.append(changed)
        changed = original
        changed.requestAttemptID = nil
        invalid.append(changed)
        changed = original
        changed.requestAttemptID = UUID()
        changed.requestedAt = try #require(original.requestedAt).addingTimeInterval(-1)
        invalid.append(changed)
        changed = original
        changed.requestAttemptID = UUID()
        changed.requestedAt = nil
        invalid.append(changed)
        changed = original
        changed.requestAttemptID = UUID()
        changed.originalUserID = "different-user"
        invalid.append(changed)
        changed = original
        changed.requestAttemptID = UUID()
        changed.operationID = UUID()
        invalid.append(changed)
        for checkpoint in invalid {
            #expect(throws: AccountStoreError.invalidEmailChangeCheckpoint) {
                try store.checkpointEmailChange(id: id, change: checkpoint)
            }
            #expect(store.accounts.first?.pendingEmailChange == original)
        }
    }

    @Test func confirmingCheckpointFreezesRequestAttemptAndFreshness() throws {
        let store = try populatedStore()
        let id = try #require(store.accounts.first?.id)
        var original = try requestedChange(in: store, id: id)
        original.requestAttemptID = UUID()
        try store.checkpointEmailChange(id: id, change: original)
        var changed = original
        changed.phase = .confirming
        changed.requestAttemptID = UUID()
        #expect(throws: AccountStoreError.invalidEmailChangeCheckpoint) {
            try store.checkpointEmailChange(id: id, change: changed)
        }
        original.phase = .confirming
        try store.checkpointEmailChange(id: id, change: original)
        try store.checkpointEmailChange(id: id, change: original)
        var invalid: [PendingEmailChange] = []
        changed = original
        changed.requestAttemptID = UUID()
        invalid.append(changed)
        changed = original
        changed.requestedAt = try #require(original.requestedAt).addingTimeInterval(60)
        invalid.append(changed)
        changed = original
        changed.baselineMessageIDs.insert("fresh-message")
        invalid.append(changed)
        changed = original
        changed.phase = .requested
        changed.requestAttemptID = UUID()
        invalid.append(changed)
        for checkpoint in invalid {
            #expect(throws: AccountStoreError.invalidEmailChangeCheckpoint) {
                try store.checkpointEmailChange(id: id, change: checkpoint)
            }
            #expect(store.accounts.first?.pendingEmailChange == original)
        }
    }

    @Test func pendingChangeBlocksEditsImportsAndDeletionAfterRestart() throws {
        let store = try populatedStore()
        let id = try #require(store.accounts.first?.id)
        let group = try store.createGroup(name: "Protected", tag: nil)
        try store.moveAccounts(ids: [id], to: group.id, protectedIDs: [])
        _ = try requestedChange(in: store, id: id)
        let reloaded = AccountStore(fileURL: store.fileURL)
        try reloaded.load()
        let replacement = ImportedCredential(email: "old@example.com", password: "changed", totpSecret: "JBSWY3DPEHPK3PXP")

        #expect(throws: AccountStoreError.rotationRecoveryActive) { try reloaded.merge([replacement]) }
        #expect(throws: AccountStoreError.rotationRecoveryActive) {
            try reloaded.updateCredentials(id: id, credential: replacement, protectedIDs: [])
        }
        #expect(throws: AccountStoreError.accountBusy) {
            try reloaded.merge([.init(email: "FIRST@icloud.com", password: "changed", totpSecret: "JBSWY3DPEHPK3PXP")])
        }
        #expect(throws: AccountStoreError.accountBusy) { try reloaded.deleteAccount(id: id, protectedIDs: []) }
        #expect(throws: AccountStoreError.accountBusy) { try reloaded.deleteGroup(id: group.id, protectedIDs: []) }
        #expect(throws: AccountStoreError.accountBusy) { try reloaded.mutate(id: id) { $0.pendingEmailChange = nil } }
        #expect(reloaded.accounts.count == 2)
        #expect(reloaded.accounts.first?.email == "old@example.com")
    }

    @Test func onlyUnsubmittedReservationCanBeReleased() throws {
        let store = try populatedStore()
        let id = try #require(store.accounts.first?.id)
        try store.importEmailAliases("first@icloud.com")
        let reserved = try store.reserveEmailChange(id: id)
        #expect(throws: AccountStoreError.emailAliasUnavailable) { try store.deleteAvailableEmailAlias(id: reserved.aliasID) }
        try store.cancelUnsubmittedEmailChange(id: id)
        #expect(store.accounts.first?.pendingEmailChange == nil)
        #expect(store.emailAliases.first?.status == .available)
        #expect(store.emailAliases.first?.accountID == nil)
        let pending = try requestedChange(in: store, id: id)
        #expect(throws: AccountStoreError.emailChangeAlreadyRequested) { try store.cancelUnsubmittedEmailChange(id: id) }
        #expect(store.accounts.first?.pendingEmailChange == pending)
        #expect(store.emailAliases.first?.status == .reserved)
    }

    @Test func abandonedEmailChangeRoundTripsEveryPhaseWithoutChangingAccountData() throws {
        for phase in [EmailChangePhase.reserved, .requested, .confirming] {
            let store = try populatedStore()
            defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
            let id = try #require(store.accounts.first?.id)
            let group = try store.createGroup(name: "Keep", tag: "paid")
            try store.moveAccounts(ids: [id], to: group.id, protectedIDs: [])
            try store.mutate(id: id) {
                $0.tag = "keep-tag"
                $0.planLabel = "Plus"
                $0.subscriptionDate = Date(timeIntervalSince1970: 1_800_000_000)
                $0.subscriptionDateKind = .renews
                $0.lastCheckedAt = Date(timeIntervalSince1970: 1_700_000_000)
                $0.proxy = AccountProxy(scheme: .socks5, host: "127.0.0.1", port: 1080,
                                       username: "fixture-user", password: "fixture-pass")
            }
            try store.importEmailAliases("first@icloud.com second@icloud.com")
            var pending = try store.reserveEmailChange(id: id)
            if phase != .reserved {
                pending.phase = .requested
                pending.originalUserID = "stable-user"
                pending.requestedAt = Date(timeIntervalSince1970: 1_700_000_000)
                pending.requestAttemptID = UUID()
                pending.baselineMessageIDs = ["before-request"]
                try store.checkpointEmailChange(id: id, change: pending)
            }
            if phase == .confirming {
                pending.phase = .confirming
                try store.checkpointEmailChange(id: id, change: pending)
            }
            let before = try #require(store.accounts.first)
            let other = try #require(store.accounts.last)
            store.selectedID = other.id

            try store.abandonEmailChange(id: id, operationID: pending.operationID)

            var expected = before
            expected.pendingEmailChange = nil
            expected.abandonedEmailChange = pending
            expected.status = .unchecked
            expected.lastError = phase == .reserved ? nil :
                "Смена email закрыта без проверки. Сохранён прежний логин; возможный новый email: \(pending.newEmail)."
            #expect(store.accounts == [expected, other])
            #expect(!expected.hasPendingCredentialChange)
            #expect(store.selectedID == other.id)
            #expect(store.emailAliases[0].status == (phase == .reserved ? .available : .used))
            #expect(store.emailAliases[0].accountID == (phase == .reserved ? nil : id))
            #expect(store.emailAliases[1].status == .available)
            // Normal local account work is available after leaving recovery.
            try store.updateCredentials(id: id, credential: .init(
                email: before.email, password: before.password, totpSecret: before.totpSecret), protectedIDs: [])
            #expect(store.accounts.first == expected)

            let reloaded = AccountStore(fileURL: store.fileURL)
            try reloaded.load()
            #expect(reloaded.accounts == store.accounts)
            #expect(reloaded.emailAliases == store.emailAliases)
            try reloaded.restoreAbandonedEmailChange(id: id)
            #expect(reloaded.accounts == [before, other])
            #expect(reloaded.accounts.first?.abandonedEmailChange == nil)
            #expect(reloaded.emailAliases[0].status == .reserved)
            #expect(reloaded.emailAliases[0].accountID == id)
            let restored = AccountStore(fileURL: store.fileURL)
            try restored.load()
            #expect(restored.accounts == reloaded.accounts)
            #expect(restored.emailAliases == reloaded.emailAliases)
        }
    }

    @Test func staleEmailExitAndCompetingRestoreLeavePersistedStateUntouched() throws {
        let store = try populatedStore()
        defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
        let id = try #require(store.accounts.first?.id)
        let pending = try requestedChange(in: store, id: id)
        let before = store.accounts
        let aliases = store.emailAliases
        let persisted = try Data(contentsOf: store.fileURL)
        #expect(throws: AccountStoreError.invalidEmailChangeCheckpoint) {
            try store.abandonEmailChange(id: id, operationID: UUID())
        }
        #expect(store.accounts == before && store.emailAliases == aliases)
        #expect(try Data(contentsOf: store.fileURL) == persisted)

        try store.abandonEmailChange(id: id, operationID: pending.operationID)
        let replacement = try store.reserveEmailChange(id: id, alias: "second@icloud.com")
        let busyAccounts = store.accounts
        let busyAliases = store.emailAliases
        let busyData = try Data(contentsOf: store.fileURL)
        #expect(throws: AccountStoreError.accountBusy) { try store.restoreAbandonedEmailChange(id: id) }
        #expect(throws: AccountStoreError.invalidEmailChangeCheckpoint) {
            try store.abandonEmailChange(id: id, operationID: pending.operationID)
        }
        #expect(store.accounts == busyAccounts && store.emailAliases == busyAliases)
        #expect(try Data(contentsOf: store.fileURL) == busyData)
        #expect(store.accounts.first?.pendingEmailChange == replacement)
        #expect(store.accounts.first?.abandonedEmailChange == pending)
    }

    @Test func restoreRejectsChangedLoginAndReusedReleasedAlias() throws {
        for changeLogin in [false, true] {
            let store = try populatedStore()
            defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
            let id = try #require(store.accounts.first?.id)
            let otherID = try #require(store.accounts.last?.id)
            try store.importEmailAliases("first@icloud.com")
            let pending = try store.reserveEmailChange(id: id)
            try store.abandonEmailChange(id: id, operationID: pending.operationID)
            if changeLogin {
                let account = try #require(store.accounts.first)
                try store.updateCredentials(id: id, credential: .init(
                    email: "changed@example.com", password: account.password, totpSecret: account.totpSecret), protectedIDs: [])
            } else {
                _ = try store.reserveEmailChange(id: otherID)
            }
            let before = store.accounts
            let aliases = store.emailAliases
            let persisted = try Data(contentsOf: store.fileURL)
            if changeLogin {
                #expect(throws: AccountStoreError.invalidEmailChangeCheckpoint) { try store.restoreAbandonedEmailChange(id: id) }
            } else {
                #expect(throws: AccountStoreError.emailAliasUnavailable) { try store.restoreAbandonedEmailChange(id: id) }
            }
            #expect(store.accounts == before && store.emailAliases == aliases)
            #expect(try Data(contentsOf: store.fileURL) == persisted)
        }
    }

    @Test func replacementRetiresOccupiedAliasAndRestartsEveryPhaseAtomically() throws {
        for phase in [EmailChangePhase.reserved, .requested, .confirming] {
            let store = try populatedStore()
            let id = try #require(store.accounts.first?.id)
            let group = try store.createGroup(name: "Keep", tag: "paid")
            try store.moveAccounts(ids: [id], to: group.id, protectedIDs: [])
            try store.setAccountTag(id: id, tag: "keep-tag")
            try store.importEmailAliases("first@icloud.com second@icloud.com")
            var previous = try store.reserveEmailChange(id: id)
            previous.originalUserID = "openai-user-1"
            previous.baselineMessageIDs = ["old-message"]
            previous.requestedAt = Date(timeIntervalSince1970: 1_700_000_000)
            previous.requestAttemptID = UUID()
            try store.checkpointEmailChange(id: id, change: previous)
            if phase != .reserved {
                previous.phase = .requested
                try store.checkpointEmailChange(id: id, change: previous)
            }
            if phase == .confirming {
                previous.phase = .confirming
                try store.checkpointEmailChange(id: id, change: previous)
            }
            try store.mutate(id: id) { $0.lastError = "Address already occupied" }
            let before = try #require(store.accounts.first)
            let otherAccount = try #require(store.accounts.last)
            store.selectedID = otherAccount.id
            let proof = phase == .reserved ? nil : EmailChangeProof(
                email: "OLD@EXAMPLE.COM", userID: "openai-user-1")

            let replacement = try store.replaceEmailChangeAlias(
                id: id, operationID: previous.operationID,
                alias: " SECOND@ICLOUD.COM ", originalProof: proof)
            #expect(replacement.operationID != previous.operationID)
            #expect(replacement.aliasID == store.emailAliases[1].id)
            #expect(replacement.originalEmail == previous.originalEmail)
            #expect(replacement.newEmail == "second@icloud.com")
            #expect(replacement.originalUserID == previous.originalUserID)
            #expect(replacement.phase == .reserved)
            #expect(replacement.baselineMessageIDs.isEmpty)
            #expect(replacement.requestedAt == nil)
            #expect(replacement.requestAttemptID == nil)
            var expected = before
            expected.pendingEmailChange = replacement
            expected.status = .needsRecovery
            expected.lastError = nil
            #expect(store.accounts == [expected, otherAccount])
            #expect(store.selectedID == otherAccount.id)
            #expect(store.emailAliases[0].status == .used)
            #expect(store.emailAliases[0].accountID == nil)
            #expect(store.emailAliases[1].status == .reserved)
            #expect(store.emailAliases[1].accountID == id)

            let reloaded = AccountStore(fileURL: store.fileURL)
            try reloaded.load()
            #expect(reloaded.accounts == store.accounts)
            #expect(reloaded.emailAliases == store.emailAliases)
            #expect(throws: AccountStoreError.invalidEmailChangeCheckpoint) {
                try reloaded.checkpointEmailChange(id: id, change: previous)
            }
            #expect(throws: AccountStoreError.invalidEmailChangeCheckpoint) {
                try reloaded.replaceEmailChangeAlias(
                    id: id, operationID: previous.operationID, originalProof: proof)
            }
            #expect(reloaded.accounts == store.accounts)
            #expect(reloaded.emailAliases == store.emailAliases)
        }
    }

    @Test func reservedReplacementAcceptsOptionalOriginalProofAndAutomaticAlias() throws {
        let proofs: [EmailChangeProof?] = [nil, .init(email: "old@example.com", userID: "openai-user-1")]
        for proof in proofs {
            let store = try populatedStore()
            let id = try #require(store.accounts.first?.id)
            try store.importEmailAliases("first@icloud.com second@icloud.com")
            let previous = try store.reserveEmailChange(id: id)
            let replacement = try store.replaceEmailChangeAlias(
                id: id, operationID: previous.operationID, originalProof: proof)
            #expect(replacement.newEmail == "second@icloud.com")
            #expect(replacement.originalUserID == proof?.userID)
            #expect(store.emailAliases[0].status == .used)
            #expect(store.emailAliases[0].accountID == nil)
        }
    }

    @Test func replacementRejectsUnprovenOriginalIdentityWithoutChanges() throws {
        for phase in [EmailChangePhase.reserved, .requested, .confirming] {
            let store = try populatedStore()
            let id = try #require(store.accounts.first?.id)
            try store.importEmailAliases("first@icloud.com second@icloud.com")
            var pending = try store.reserveEmailChange(id: id)
            pending.originalUserID = "openai-user-1"
            try store.checkpointEmailChange(id: id, change: pending)
            if phase != .reserved {
                pending.phase = .requested
                pending.requestedAt = Date(timeIntervalSince1970: 1_700_000_000)
                try store.checkpointEmailChange(id: id, change: pending)
            }
            if phase == .confirming {
                pending.phase = .confirming
                try store.checkpointEmailChange(id: id, change: pending)
            }
            var proofs: [EmailChangeProof?] = [
                .init(email: "wrong@example.com", userID: "openai-user-1"),
                .init(email: pending.newEmail, userID: "openai-user-1"),
                .init(email: pending.originalEmail, userID: "different-user"),
                .init(email: pending.originalEmail, userID: " \n ")
            ]
            if phase != .reserved { proofs.append(nil) }
            let oldAccounts = store.accounts
            let oldAliases = store.emailAliases
            let persisted = try Data(contentsOf: store.fileURL)
            for proof in proofs {
                #expect(throws: AccountStoreError.emailChangeVerificationFailed) {
                    try store.replaceEmailChangeAlias(
                        id: id, operationID: pending.operationID,
                        alias: "second@icloud.com", originalProof: proof)
                }
                #expect(store.accounts == oldAccounts)
                #expect(store.emailAliases == oldAliases)
                #expect(try Data(contentsOf: store.fileURL) == persisted)
            }
        }
    }

    @Test func replacementRejectsUnavailableTargetsWithoutChanges() throws {
        let store = try populatedStore()
        let id = try #require(store.accounts.first?.id)
        let otherID = try #require(store.accounts.last?.id)
        let pending = try requestedChange(in: store, id: id)
        _ = try store.reserveEmailChange(id: otherID, alias: "second@icloud.com")
        try store.importEmailAliases("used@icloud.com")
        try store.merge([.init(email: "USED@icloud.com", password: "p", totpSecret: "JBSWY3DPEHPK3PXP")])
        let oldAccounts = store.accounts
        let oldAliases = store.emailAliases
        let persisted = try Data(contentsOf: store.fileURL)
        let targets: [String?] = [nil, "first@icloud.com", "SECOND@icloud.com", "used@icloud.com", "missing@icloud.com"]
        for target in targets {
            #expect(throws: AccountStoreError.emailAliasUnavailable) {
                try store.replaceEmailChangeAlias(
                    id: id, operationID: pending.operationID, alias: target,
                    originalProof: .init(email: pending.originalEmail, userID: "openai-user-1"))
            }
            #expect(store.accounts == oldAccounts)
            #expect(store.emailAliases == oldAliases)
            #expect(try Data(contentsOf: store.fileURL) == persisted)
        }
        #expect(throws: AccountStoreError.invalidEmailAlias) {
            try store.replaceEmailChangeAlias(
                id: id, operationID: pending.operationID, alias: "invalid@example.com",
                originalProof: .init(email: pending.originalEmail, userID: "openai-user-1"))
        }
        #expect(store.accounts == oldAccounts)
        #expect(store.emailAliases == oldAliases)
        #expect(try Data(contentsOf: store.fileURL) == persisted)
    }

    @Test func failedReplacementSavePublishesNeitherNewOperationNorAliasChanges() throws {
        let store = try populatedStore()
        let id = try #require(store.accounts.first?.id)
        let pending = try requestedChange(in: store, id: id)
        let oldAccounts = store.accounts
        let oldAliases = store.emailAliases
        let directory = store.fileURL.deletingLastPathComponent()
        try FileManager.default.removeItem(at: directory)
        try Data("block".utf8).write(to: directory)
        #expect(throws: (any Error).self) {
            try store.replaceEmailChangeAlias(
                id: id, operationID: pending.operationID, alias: "second@icloud.com",
                originalProof: .init(email: pending.originalEmail, userID: "openai-user-1"))
        }
        #expect(store.accounts == oldAccounts)
        #expect(store.emailAliases == oldAliases)
    }

    @Test func successfulProofCommitsEmailAndConsumesAliasPreservingCredentials() throws {
        let store = try populatedStore()
        let original = try #require(store.accounts.first)
        let group = try store.createGroup(name: "Keep", tag: "paid")
        try store.moveAccounts(ids: [original.id], to: group.id, protectedIDs: [])
        try store.setAccountTag(id: original.id, tag: "keep-tag")
        var pending = try requestedChange(in: store, id: original.id)
        pending.phase = .confirming
        try store.checkpointEmailChange(id: original.id, change: pending)
        let before = try #require(store.accounts.first)
        try store.completeEmailChange(id: original.id, proof: .init(email: "FIRST@icloud.com", userID: "openai-user-1"))
        var expected = before
        expected.email = "first@icloud.com"
        expected.pendingEmailChange = nil
        expected.status = .ready
        expected.lastError = nil
        #expect(store.accounts.first == expected)
        #expect(store.emailAliases.first?.status == .used)
        #expect(store.emailAliases.first?.accountID == original.id)

        let reloaded = AccountStore(fileURL: store.fileURL)
        try reloaded.load()
        #expect(reloaded.accounts.first == expected)
        #expect(reloaded.emailAliases == store.emailAliases)
        try reloaded.deleteAccount(id: original.id, protectedIDs: [])
        #expect(try reloaded.importEmailAliases("FIRST@icloud.com") == 0)
        #expect(reloaded.emailAliases.first?.status == .used)
        #expect(throws: AccountStoreError.emailAliasUnavailable) { try reloaded.deleteAvailableEmailAlias(id: pending.aliasID) }
        #expect(throws: AccountStoreError.emailAliasUnavailable) {
            try reloaded.reserveEmailChange(id: try #require(reloaded.accounts.first?.id), alias: "first@icloud.com")
        }
    }

    @Test func wrongIdentityOrTargetCannotCommit() throws {
        let store = try populatedStore()
        let id = try #require(store.accounts.first?.id)
        var pending = try requestedChange(in: store, id: id)
        #expect(throws: AccountStoreError.emailChangeVerificationFailed) {
            try store.completeEmailChange(id: id, proof: .init(email: pending.newEmail, userID: "openai-user-1"))
        }
        pending.phase = .confirming
        try store.checkpointEmailChange(id: id, change: pending)
        for proof in [EmailChangeProof(email: "wrong@icloud.com", userID: "openai-user-1"),
                      EmailChangeProof(email: pending.newEmail, userID: "wrong-user")] {
            #expect(throws: AccountStoreError.emailChangeVerificationFailed) { try store.completeEmailChange(id: id, proof: proof) }
        }
        #expect(store.accounts.first?.email == "old@example.com")
        #expect(store.accounts.first?.pendingEmailChange == pending)
        #expect(store.emailAliases.first?.status == .reserved)
    }

    @Test func failedFinalSavePublishesNeitherEmailNorAliasConsumption() throws {
        let store = try populatedStore()
        let id = try #require(store.accounts.first?.id)
        var pending = try requestedChange(in: store, id: id)
        pending.phase = .confirming
        try store.checkpointEmailChange(id: id, change: pending)
        let oldAccounts = store.accounts
        let oldAliases = store.emailAliases
        let directory = store.fileURL.deletingLastPathComponent()
        try FileManager.default.removeItem(at: directory)
        try Data("block".utf8).write(to: directory)
        #expect(throws: (any Error).self) {
            try store.completeEmailChange(id: id, proof: .init(email: pending.newEmail, userID: "openai-user-1"))
        }
        #expect(store.accounts == oldAccounts)
        #expect(store.emailAliases == oldAliases)
    }

    @Test func manuallyAssociatedPoolAliasStaysUsedAfterAccountDeletion() throws {
        let store = try populatedStore()
        try store.importEmailAliases("manual@icloud.com")
        try store.merge([.init(email: "MANUAL@icloud.com", password: "p", totpSecret: "JBSWY3DPEHPK3PXP")])
        let id = try #require(store.accounts.last?.id)
        #expect(store.emailAliases.first?.status == .used)
        try store.deleteAccount(id: id, protectedIDs: [])
        #expect(store.emailAliases.first?.status == .used)
    }
}
