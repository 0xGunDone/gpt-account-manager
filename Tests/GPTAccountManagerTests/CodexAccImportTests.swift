import Foundation
import Testing
import WebKit
@testable import GPTAccountManager

@MainActor
private final class CodexAccImportFixture {
    static let authorizationURL = URL(string: "https://auth.openai.com/oauth/authorize?client_id=app_EMoamEEZ73f0CkXaXp7hrann&response_type=code&redirect_uri=http%3A%2F%2Flocalhost%3A1455%2Fauth%2Fcallback&scope=openid%20profile%20email%20offline_access&state=fixture-state&code_challenge=fixture-challenge&code_challenge_method=S256")!
    var starts: [CodexAccImportStart] = []
    var statuses: [String: [CodexAccImportStatus]] = [:]
    var steps: [CodexAccAuthorization.State] = [.waiting]
    var received: [AccountRecord] = []
    var prepared: [UUID] = []
    var cancelled: [String] = []
    var events: [String] = []
    var cancelFails = false
    var holdStart = false
    var suspendedStart: CheckedContinuation<Void, Never>?
    var now = Date(timeIntervalSince1970: 1_000)
    var tick: TimeInterval = 0

    func pending(_ id: String) -> CodexAccImportStart {
        .pending(.init(id: id, authorizationURL: Self.authorizationURL, expiresInSeconds: 300))
    }

    func coordinator(onSelect: @escaping @MainActor (UUID) -> Void = { _ in }) -> CodexAccImportCoordinator {
        CodexAccImportCoordinator(dependencies: .init(
            start: { account in
                self.received.append(account)
                self.events.append("start:\(account.email)")
                if self.holdStart { await withCheckedContinuation { self.suspendedStart = $0 } }
                guard !self.starts.isEmpty else { throw CodexAccImportError.requestFailed }
                return self.starts.removeFirst()
            },
            status: { id in
                self.events.append("status:\(id)")
                guard let next = self.statuses[id]?.first else { throw CodexAccImportError.requestFailed }
                if self.statuses[id]!.count > 1 { self.statuses[id]!.removeFirst() }
                return next
            },
            cancel: { id in
                self.cancelled.append(id)
                self.events.append("cancel:\(id)")
                if self.cancelFails { throw CodexAccImportError.requestFailed }
                return .cancelled
            },
            prepare: { account, _ in
                self.prepared.append(account.id)
                return BrowserSession(dataStore: .nonPersistent())
            },
            advance: { _, _ in
                guard !self.steps.isEmpty else { return .waiting }
                return self.steps.removeFirst()
            },
            now: { self.now },
            wait: { self.now.addTimeInterval(self.tick); await Task.yield() }), onSelect: onSelect)
    }
}

@MainActor
struct CodexAccImportTests {
    private func account(_ email: String = "first@example.com") -> AccountRecord {
        AccountRecord(credential: .init(email: email, password: "fixture-password", totpSecret: "JBSWY3DPEHPK3PXP"))
    }

    @Test func serialQueueUsesExactSelectionAndPreservesCredentials() async {
        let first = account(), second = account("second@example.com")
        let fixture = CodexAccImportFixture()
        fixture.starts = [fixture.pending("attempt-1"), .complete(email: second.email, accountID: "second")]
        fixture.statuses = ["attempt-1": [.pending, .complete(email: first.email, accountID: "first")]]
        var selected: [UUID] = []
        let coordinator = fixture.coordinator { selected.append($0) }
        await coordinator.start(accounts: [first, first, second])

        #expect(fixture.received == [first, second])
        #expect(fixture.events == ["start:first@example.com", "status:attempt-1", "status:attempt-1", "start:second@example.com"])
        #expect(Set(selected) == [first.id, second.id])
        #expect(fixture.prepared == [first.id])
        #expect(coordinator.completedCount == 2 && coordinator.totalCount == 2)
        #expect(!coordinator.isRunning && !coordinator.isPaused)
        #expect(coordinator.protectedAccountIDs.isEmpty)
    }

    @Test func duplicateCompletionRequiresMatchingEmailAndNoBrowser() async {
        let fixture = CodexAccImportFixture(), first = account(), second = account("second@example.com")
        fixture.starts = [.complete(email: "wrong@example.com", accountID: "wrong")]
        let coordinator = fixture.coordinator()
        await coordinator.start(accounts: [first, second])
        #expect(fixture.received == [first])
        #expect(fixture.prepared.isEmpty)
        #expect(coordinator.completedCount == 0)
        #expect(coordinator.isPaused)
        #expect(coordinator.protectedAccountIDs == [first.id, second.id])
        #expect(coordinator.message == CodexAccImportError.wrongAccount.errorDescription)
    }

    @Test func manualResumeRetainsAttemptAndBrowserThenContinuesRemainingAccounts() async {
        let fixture = CodexAccImportFixture(), first = account(), second = account("second@example.com")
        fixture.starts = [fixture.pending("attempt-1"), .complete(email: second.email, accountID: "second")]
        fixture.statuses = ["attempt-1": [.pending]]
        fixture.steps = [.manual("Введите код из письма.")]
        let coordinator = fixture.coordinator()
        await coordinator.start(accounts: [first, second])
        let pausedSession = coordinator.browserSession(for: first.id)
        #expect(coordinator.isPaused && !coordinator.isRunning)
        #expect(pausedSession != nil)
        #expect(fixture.received == [first])
        #expect(coordinator.protectedAccountIDs == [first.id, second.id])
        await coordinator.start(accounts: [second])
        #expect(fixture.received == [first])

        fixture.statuses["attempt-1"] = [.complete(email: first.email, accountID: "first")]
        await coordinator.resume()
        #expect(fixture.received == [first, second])
        #expect(fixture.prepared == [first.id])
        #expect(fixture.cancelled.isEmpty)
        #expect(coordinator.completedCount == 2)
    }

    @Test func failedAttemptPausesBatchAndNewAttemptNeedsExplicitResume() async {
        let fixture = CodexAccImportFixture(), first = account(), second = account("second@example.com")
        fixture.starts = [fixture.pending("old"), .complete(email: first.email, accountID: "first"), .complete(email: second.email, accountID: "second")]
        fixture.statuses = ["old": [.failed]]
        let coordinator = fixture.coordinator()
        await coordinator.start(accounts: [first, second])
        #expect(coordinator.isPaused && coordinator.completedCount == 0)
        #expect(fixture.received == [first])
        #expect(fixture.cancelled.isEmpty)
        await coordinator.resume()
        #expect(fixture.cancelled == ["old"])
        #expect(fixture.events == ["start:first@example.com", "status:old", "cancel:old", "start:first@example.com", "start:second@example.com"])
        #expect(coordinator.completedCount == 2)
    }

    @Test func expiredAttemptAndInvalidAuthorizationPauseWithoutStartingNextAccount() async {
        let first = account()
        let fixture = CodexAccImportFixture()
        fixture.starts = [fixture.pending("expired")]
        fixture.statuses = ["expired": [.pending]]
        fixture.tick = 301
        let coordinator = fixture.coordinator()
        await coordinator.start(accounts: [first])
        #expect(coordinator.isPaused)
        #expect(fixture.received == [first])
        fixture.starts = [.complete(email: first.email, accountID: "first")]
        await coordinator.resume()
        #expect(fixture.cancelled == ["expired"])
        #expect(coordinator.completedCount == 1)

        let invalid = CodexAccImportFixture()
        invalid.starts = [.pending(.init(id: "invalid", authorizationURL: URL(string: "https://example.com")!, expiresInSeconds: 300))]
        let invalidCoordinator = invalid.coordinator()
        await invalidCoordinator.start(accounts: [first])
        #expect(invalidCoordinator.isPaused)
        #expect(invalid.prepared.isEmpty)
        await invalidCoordinator.stop()
        #expect(invalid.cancelled == ["invalid"])
        #expect(invalidCoordinator.protectedAccountIDs.isEmpty)
    }

    @Test func pendingCredentialChangesRejectWholeSelectionBeforeContactingCodexAcc() async {
        for mode in 0..<5 {
            var blocked = account()
            switch mode {
            case 0: blocked.pendingPassword = "new-password"
            case 1: blocked.rotationStage = .oldMethodDisabled
            case 2: blocked.pendingTOTPSecret = "pending-secret"
            case 3: blocked.pendingAccessChange = .password
            default: blocked.pendingEmailChange = .init(aliasID: UUID(), originalEmail: blocked.email, newEmail: "pending@example.com")
            }
            let fixture = CodexAccImportFixture(), coordinator = fixture.coordinator()
            await coordinator.start(accounts: [account("eligible@example.com"), blocked])
            #expect(fixture.received.isEmpty)
            #expect(coordinator.protectedAccountIDs.isEmpty)
            #expect(coordinator.message != nil)
        }
    }

    @Test func stopWaitsForLateStartAndKeepsProtectionUntilCancelAcknowledged() async {
        let first = account(), fixture = CodexAccImportFixture()
        fixture.holdStart = true
        fixture.starts = [fixture.pending("late")]
        let coordinator = fixture.coordinator()
        let starting = Task { await coordinator.start(accounts: [first]) }
        while fixture.suspendedStart == nil { await Task.yield() }
        let stopping = Task { await coordinator.stop() }
        while coordinator.message != "Остановка импорта в CodexAcc…" { await Task.yield() }
        #expect(coordinator.protectedAccountIDs == [first.id])
        #expect(fixture.cancelled.isEmpty)
        fixture.suspendedStart?.resume()
        await starting.value
        await stopping.value
        #expect(fixture.cancelled == ["late"])
        #expect(fixture.prepared.isEmpty)
        #expect(coordinator.protectedAccountIDs.isEmpty)
        #expect(!coordinator.isRunning && !coordinator.isPaused)
    }

    @Test func failedCancellationKeepsProtectionForRetry() async {
        let first = account(), fixture = CodexAccImportFixture()
        fixture.starts = [fixture.pending("held")]
        fixture.statuses = ["held": [.pending]]
        fixture.steps = [.manual("Проверка.")]
        let coordinator = fixture.coordinator()
        await coordinator.start(accounts: [first])
        fixture.cancelFails = true
        await coordinator.stop()
        #expect(coordinator.isPaused)
        #expect(coordinator.protectedAccountIDs == [first.id])
        fixture.cancelFails = false
        await coordinator.stop()
        #expect(fixture.cancelled == ["held", "held"])
        #expect(coordinator.protectedAccountIDs.isEmpty)
    }
}

@MainActor
struct CodexAccImportClientTests {
    private let descriptor = CodexAccBridgeDescriptor(port: 32123, token: String(repeating: "x", count: 64))
    private func response(_ request: URLRequest, _ json: String, status: Int = 200) -> (Data, HTTPURLResponse) {
        (Data(json.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!)
    }

    @Test func clientSendsOnlyMetadataAndUsesBoundLoopbackForWholeAttempt() async throws {
        var requests: [URLRequest] = []
        let account = AccountRecord(credential: .init(email: "fixture@example.com", password: "never-sent-password", totpSecret: "never-sent-secret"))
        let client = CodexAccImportClient(readDescriptor: { descriptor }, launch: { Issue.record("Unexpected launch") }, transport: { request in
            requests.append(request)
            switch request.url!.path {
            case "/import/start": return response(request, """
                {"status":"pending","attempt_id":"attempt","auth_url":"https://auth.openai.com/oauth/authorize","expires_in_seconds":300}
                """)
            case "/import/status": return response(request, "{\"status\":\"pending\",\"attempt_id\":\"attempt\"}")
            default: return response(request, "{\"status\":\"cancelled\"}")
            }
        })
        _ = try await client.start(account: account)
        #expect(try await client.status(attemptID: "attempt") == .pending)
        #expect(try await client.cancel(attemptID: "attempt") == .cancelled)
        #expect(requests.count == 3)
        for request in requests {
            #expect(request.url!.host == "127.0.0.1" && request.url!.port == descriptor.port)
            #expect(request.httpMethod == "POST")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(descriptor.token)")
            #expect(request.value(forHTTPHeaderField: "Origin") == nil)
            let body = String(decoding: request.httpBody!, as: UTF8.self)
            #expect(!body.contains(account.password) && !body.contains(account.totpSecret))
        }
        let metadata = try JSONDecoder().decode([String: String].self, from: requests[0].httpBody!)
        #expect(metadata == ["email": account.email, "name": account.email])
    }

    @Test func missingAndStaleDescriptorLaunchNativeAppWithBoundedWait() async throws {
        var active: CodexAccBridgeDescriptor?, launches = 0, waits = 0
        let account = AccountRecord(credential: .init(email: "fixture@example.com", password: "password", totpSecret: "secret"))
        let client = CodexAccImportClient(readDescriptor: { active }, launch: { launches += 1 }, transport: { request in
            response(request, "{\"status\":\"complete\",\"email\":\"fixture@example.com\",\"account_id\":\"stored\"}")
        }, wait: { waits += 1; active = descriptor })
        #expect(try await client.start(account: account) == .complete(email: account.email, accountID: "stored"))
        #expect(launches == 1 && waits == 1)

        var current = descriptor, requests = 0
        let replacement = CodexAccBridgeDescriptor(port: 32124, token: String(repeating: "y", count: 64))
        let stale = CodexAccImportClient(readDescriptor: { current }, launch: { current = replacement }, transport: { request in
            requests += 1
            if request.url!.port == descriptor.port { throw URLError(.cannotConnectToHost) }
            return response(request, "{\"status\":\"complete\",\"email\":\"fixture@example.com\",\"account_id\":\"stored\"}")
        }, wait: { Issue.record("Replacement descriptor should already exist") })
        _ = try await stale.start(account: account)
        #expect(requests == 2)
    }

    @Test func responseFailuresNeverExposeRemoteTextOrRetryPossibleStartedAttempt() async {
        for status in [302, 401, 409, 500] {
            var calls = 0
            let client = CodexAccImportClient(readDescriptor: { descriptor }, launch: { Issue.record("Unexpected retry") }, transport: { request in
                calls += 1
                return response(request, "{\"status\":\"failed\",\"error\":\"secret-token https://secret.example\"}", status: status)
            })
            do {
                _ = try await client.start(account: .init(credential: .init(email: "fixture@example.com", password: "p", totpSecret: "s")))
                Issue.record("Expected failure")
            } catch {
                #expect(error as? CodexAccImportError == .invalidResponse)
                #expect(!error.localizedDescription.contains("secret"))
            }
            #expect(calls == 1)
        }
    }

    @Test func terminalCancellationWithWrongIdentityClearsProtectionAndAllowsIdempotentRetry() async throws {
        var cancellations = 0
        let account = AccountRecord(credential: .init(email: "fixture@example.com", password: "p", totpSecret: "s"))
        let client = CodexAccImportClient(readDescriptor: { descriptor }, launch: {}, transport: { request in
            switch request.url!.path {
            case "/import/start":
                return response(request, """
                {"status":"pending","attempt_id":"attempt","auth_url":"\(CodexAccImportFixture.authorizationURL.absoluteString)","expires_in_seconds":300}
                """)
            case "/import/status":
                return response(request, "{\"status\":\"pending\",\"attempt_id\":\"attempt\"}")
            default:
                cancellations += 1
                return response(request, cancellations == 1
                    ? "{\"status\":\"complete\",\"email\":\"wrong@example.com\",\"account_id\":\"wrong\"}"
                    : "{\"status\":\"cancelled\"}")
            }
        })
        let coordinator = CodexAccImportCoordinator(dependencies: .init(
            start: { try await client.start(account: $0) },
            status: { try await client.status(attemptID: $0) },
            cancel: { try await client.cancel(attemptID: $0) },
            prepare: { _, _ in BrowserSession(dataStore: .nonPersistent()) },
            advance: { _, _ in .manual("Проверка.") }))
        await coordinator.start(accounts: [account])
        await coordinator.stop()
        #expect(coordinator.protectedAccountIDs.isEmpty)
        #expect(!coordinator.isPaused && !coordinator.isRunning)
        #expect(coordinator.completedCount == 0)
        #expect(coordinator.message?.contains("другой аккаунт") == true)
        #expect(try await client.cancel(attemptID: "attempt") == .cancelled)
        #expect(cancellations == 2)
    }

    @Test func descriptorRejectsSymlinksInsecureModesAndOversizeFiles() throws {
        let manager = FileManager.default
        let directory = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try manager.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? manager.removeItem(at: directory) }
        let file = directory.appendingPathComponent("import-bridge.json")
        let data = Data("{\"port\":32123,\"token\":\"\(descriptor.token)\"}".utf8)
        try data.write(to: file)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        #expect(try CodexAccBridgeDescriptor.read(from: file) == descriptor)
        try manager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        #expect(throws: CodexAccImportError.invalidDescriptor) { try CodexAccBridgeDescriptor.read(from: file) }
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        #expect(throws: CodexAccImportError.invalidDescriptor) { try CodexAccBridgeDescriptor.read(from: file) }
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let link = directory.appendingPathComponent("link.json")
        try manager.createSymbolicLink(at: link, withDestinationURL: file)
        #expect(throws: CodexAccImportError.invalidDescriptor) { try CodexAccBridgeDescriptor.read(from: link) }
        try Data(repeating: 32, count: 4097).write(to: file)
        #expect(throws: CodexAccImportError.invalidDescriptor) { try CodexAccBridgeDescriptor.read(from: file) }
    }
}
