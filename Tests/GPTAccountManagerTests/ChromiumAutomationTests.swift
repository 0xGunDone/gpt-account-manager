import Foundation
import Testing
@testable import GPTAccountManager

@MainActor
private final class FakeChromiumWorker: ChromiumWorkerRunning {
    var requests: [ChromiumWorkerRequest] = []
    var checkpoints: [ChromiumWorkerCheckpoint] = []
    var result: ChromiumWorkerResult

    init(result: ChromiumWorkerResult) {
        self.result = result
    }

    func run(
        request: ChromiumWorkerRequest,
        onCheckpoint: @escaping @MainActor (ChromiumWorkerCheckpoint) throws -> Void
    ) async -> ChromiumWorkerResult {
        requests.append(request)
        do {
            for checkpoint in checkpoints {
                try onCheckpoint(checkpoint)
            }
            return result
        } catch {
            return .failure(
                stage: request.rotationStage,
                message: "Could not persist Chromium checkpoint")
        }
    }
}

@MainActor
private final class WaitingChromiumWorker: ChromiumWorkerRunning {
    var started = 0

    func run(
        request: ChromiumWorkerRequest,
        onCheckpoint: @escaping @MainActor (ChromiumWorkerCheckpoint) throws -> Void
    ) async -> ChromiumWorkerResult {
        started += 1
        do {
            try await Task.sleep(for: .milliseconds(500))
            return .failure(stage: nil, message: "Timed out")
        } catch {
            return .failure(stage: nil, message: "Cancelled")
        }
    }
}

@MainActor
@Suite struct ChromiumAutomationTests {
    @Test func cancellingConcurrentRotationsCancelsEveryWorker() async throws {
        let worker = WaitingChromiumWorker()
        let automation = ChromiumAutomation(worker: worker)
        let first = Task { await automation.rotate2FA(account: account()) { _ in } }
        let second = Task { await automation.rotate2FA(account: account()) { _ in } }
        while worker.started < 2 {
            try await Task.sleep(for: .milliseconds(5))
        }
        automation.cancelActiveOperation()

        let outcomes = [await first.value, await second.value]
        for outcome in outcomes {
            guard case .failure(let stage, let message) = outcome else {
                Issue.record("Cancellation must not succeed or pause")
                continue
            }
            #expect(stage == nil)
            #expect(message == "Cancelled")
        }
    }

    private func account(
        password: String = "private-password",
        pendingSecret: String? = nil,
        stage: RotationStage? = nil
    ) -> AccountRecord {
        var account = AccountRecord(credential: .init(
            email: "owner@example.com",
            password: password,
            totpSecret: "JBSWY3DPEHPK3PXP"))
        account.pendingTOTPSecret = pendingSecret
        account.rotationStage = stage
        return account
    }

    @Test func checkMapsSubscriptionAndForwardsCredentials() async throws {
        let worker = FakeChromiumWorker(result: .success(.init(
            signedInEmail: "owner@example.com",
            planLabel: "plus",
            activeUntil: "2026-09-30T00:00:00Z",
            activeUntilText: nil,
            locale: nil,
            willRenew: true,
            proof: nil)))
        let automation = ChromiumAutomation(worker: worker)
        let account = account()

        let outcome = await automation.check(account: account)

        guard case .success(let snapshot) = outcome else {
            Issue.record("Expected subscription success")
            return
        }
        #expect(snapshot.signedInEmail == account.email)
        #expect(snapshot.planLabel == "plus")
        #expect(snapshot.activeUntil == ISO8601DateFormatter().date(
            from: "2026-09-30T00:00:00Z"))
        #expect(snapshot.willRenew == true)
        #expect(worker.requests == [.init(
            operation: .check,
            email: account.email,
            password: account.password,
            currentSecret: account.totpSecret,
            pendingSecret: nil,
            rotationStage: nil)])
    }

    @Test func checkParsesLocalizedPlanCardDate() async throws {
        let worker = FakeChromiumWorker(result: .success(.init(
            signedInEmail: "owner@example.com",
            planLabel: "plus",
            activeUntil: nil,
            activeUntilText: "до 30 сент. 2026 г.",
            locale: "ru-RU",
            willRenew: nil,
            proof: nil)))
        let automation = ChromiumAutomation(worker: worker)

        let outcome = await automation.check(account: account())

        guard case .success(let snapshot) = outcome else {
            Issue.record("Expected subscription success")
            return
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        #expect(snapshot.activeUntil == calendar.date(from: .init(
            year: 2026,
            month: 9,
            day: 30)))
    }

    @Test func rotationForwardsAndMapsEveryCheckpoint() async throws {
        let worker = FakeChromiumWorker(result: .success(.init(
            signedInEmail: "owner@example.com",
            planLabel: "plus",
            activeUntil: "2026-09-30T00:00:00Z",
            activeUntilText: nil,
            locale: nil,
            willRenew: true,
            proof: .init(
                passwordSubmitted: true,
                pendingOTPSubmitted: true,
                authenticatedImmediatelyAfterPendingOTP: true))))
        worker.checkpoints = [
            .removalStarted,
            .oldMethodDisabled,
            .secretCaptured("KRUGS4ZANFZSAYJA"),
            .setupConfirmed,
        ]
        let automation = ChromiumAutomation(worker: worker)
        let account = account(
            pendingSecret: "KRUGS4ZANFZSAYJA",
            stage: .pendingSecretCaptured)
        var received: [RotationCheckpointEvent] = []

        let outcome = await automation.rotate2FA(account: account) {
            received.append($0)
        }

        #expect(received == [
            .removalStarted,
            .oldMethodDisabled,
            .secretCaptured("KRUGS4ZANFZSAYJA"),
            .setupConfirmed,
        ])
        #expect(worker.requests.first == .init(
            operation: .rotate,
            email: account.email,
            password: account.password,
            currentSecret: account.totpSecret,
            pendingSecret: account.pendingTOTPSecret,
            rotationStage: account.rotationStage))
        #expect(outcome == .success(
            snapshot: .init(
                signedInEmail: account.email,
                planLabel: "plus",
                activeUntil: ISO8601DateFormatter().date(
                    from: "2026-09-30T00:00:00Z"),
                willRenew: true),
            proof: .init(
                passwordSubmitted: true,
                pendingOTPSubmitted: true,
                authenticatedImmediatelyAfterPendingOTP: true)))
    }

    @Test func ambiguousRecoveryStagesNeverStartAChromiumWorker() async {
        for stage in [RotationStage.removingOldMethod, .oldMethodDisabled] {
            let worker = FakeChromiumWorker(result: .failure(
                stage: stage,
                message: "Worker must not be called"))
            let automation = ChromiumAutomation(worker: worker)

            let outcome = await automation.rotate2FA(account: account(stage: stage)) { _ in }

            guard case .manualActionRequired(let resultStage, _) = outcome else {
                Issue.record("Ambiguous recovery must require the original app session")
                continue
            }
            #expect(resultStage == stage)
            #expect(worker.requests.isEmpty)
        }
    }

    @Test func rotationSuccessWithoutCleanLoginProofFailsClosed() async {
        let worker = FakeChromiumWorker(result: .success(.init(
            signedInEmail: "owner@example.com",
            planLabel: nil,
            activeUntil: nil,
            activeUntilText: nil,
            locale: nil,
            willRenew: nil,
            proof: nil)))
        let automation = ChromiumAutomation(worker: worker)

        let outcome = await automation.rotate2FA(account: account()) { _ in }

        guard case .failure(_, let message) = outcome else {
            Issue.record("Expected a closed failure without clean-login proof")
            return
        }
        #expect(message.contains("proof"))
    }

    @Test func workerMessagesDoNotExposeAccountSecrets() async {
        let password = "password-that-must-not-leak"
        let worker = FakeChromiumWorker(result: .manual(
            stage: .awaitingCleanLogin,
            message: "Retry owner@example.com with \(password) and JBSWY3DPEHPK3PXP"))
        let automation = ChromiumAutomation(worker: worker)

        let outcome = await automation.rotate2FA(
            account: account(password: password)) { _ in }

        guard case .manualActionRequired(_, let message) = outcome else {
            Issue.record("Expected a manual outcome")
            return
        }
        #expect(!message.contains(password))
        #expect(!message.contains("owner@example.com"))
        #expect(!message.contains("JBSWY3DPEHPK3PXP"))
        #expect(message.contains("[redacted]"))
    }
}
