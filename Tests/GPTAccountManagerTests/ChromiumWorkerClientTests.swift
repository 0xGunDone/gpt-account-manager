import Foundation
import Testing
@testable import GPTAccountManager

@MainActor
@Suite struct ChromiumWorkerClientTests {
    private func client() throws -> ChromiumWorkerClient {
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/fake-chromium-worker.js")
        let node = try #require(ChromiumWorkerClient.resolveNodeExecutable())
        return ChromiumWorkerClient(
            nodeURL: node,
            workerURL: fixture,
            requireChrome: false)
    }

    private func request(
        operation: ChromiumWorkerOperation = .rotate,
        email: String = "user@example.com"
    ) -> ChromiumWorkerRequest {
        .init(
            operation: operation,
            email: email,
            password: "private-password",
            currentSecret: "JBSWY3DPEHPK3PXP",
            pendingSecret: nil,
            rotationStage: nil)
    }

    @Test func persistsEveryCheckpointBeforeAcknowledgingIt() async throws {
        let client = try client()
        var checkpoints: [ChromiumWorkerCheckpoint] = []

        let result = await client.run(request: request()) { checkpoint in
            checkpoints.append(checkpoint)
        }

        #expect(checkpoints == [
            .removalStarted,
            .oldMethodDisabled,
            .secretCaptured("KRUGS4ZANFZSAYJA"),
            .setupConfirmed,
        ])
        #expect(result == .success(.init(
            signedInEmail: "user@example.com",
            planLabel: nil,
            activeUntil: nil,
            activeUntilText: nil,
            locale: nil,
            willRenew: nil,
            proof: .init(
                passwordSubmitted: true,
                pendingOTPSubmitted: true,
                authenticatedImmediatelyAfterPendingOTP: true))))
    }

    @Test func checkRequestReturnsSubscriptionResult() async throws {
        let client = try client()

        let result = await client.run(request: request(operation: .check)) { _ in
            Issue.record("Check operation must not emit rotation checkpoints")
        }

        guard case .success(let success) = result else {
            Issue.record("Expected success")
            return
        }
        #expect(success.planLabel == "plus")
        #expect(success.activeUntil == "2026-09-30T00:00:00Z")
        #expect(success.willRenew == true)
    }

    @Test func rejectedCheckpointStopsTheWorkerWithoutAcknowledging() async throws {
        struct PersistenceError: Error {}
        let client = try client()

        let result = await client.run(request: request()) { _ in
            throw PersistenceError()
        }

        #expect(result == .failure(
            stage: nil,
            message: "Could not persist Chromium checkpoint"))
    }

    @Test func cancellationTerminatesTheWorkerPromptly() async throws {
        let client = try client()
        let clock = ContinuousClock()
        let started = clock.now
        let task = Task {
            await client.run(request: request(email: "hang@example.com")) { _ in }
        }
        try await Task.sleep(for: .milliseconds(200))

        task.cancel()
        let result = await task.value

        #expect(result == .failure(
            stage: nil,
            message: "External Chrome automation cancelled"))
        #expect(started.duration(to: clock.now) < .seconds(3))
    }
}
