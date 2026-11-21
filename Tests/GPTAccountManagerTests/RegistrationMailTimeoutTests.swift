import AppKit
import Foundation
import Testing
@testable import GPTAccountManager

@MainActor
@Suite(.serialized)
struct RegistrationMailTimeoutTests {
    private func coordinator() -> RegistrationCoordinator {
        _ = NSApplication.shared
        let store = AccountStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathComponent("accounts.json"))
        return RegistrationCoordinator(store: store, browser: ChatGPTAutomation(sessionManager: WebSessionManager()),
                                       mailbox: MailRuMailbox(expectedMailbox: "fixture@mail.ru"))
    }

    @Test func delayedCodeRetriesOnlyTheSameReadAndNeverRequestsAnotherCode() async throws {
        let coordinator = coordinator()
        let requestedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let excluded: Set<String> = ["before-request"]
        var requests: [(Date, Set<String>)] = []
        let result = try await coordinator.waitForMailbox {
            requests.append((requestedAt, excluded))
            if requests.count < 3 { throw MailVerificationError.timedOut }
            return MailVerificationCode(messageID: "fresh-message", code: "123456")
        }
        #expect(result.messageID == "fresh-message")
        #expect(requests.count == 3 && requests.allSatisfy { $0.0 == requestedAt && $0.1 == excluded })
        #expect(coordinator.message.contains("продолжается автоматически"))
    }

    @Test(arguments: [MailVerificationError.ambiguousMessage, .signInRequired, .untrustedOrigin, .unverifiedSender, .unsupportedLayout])
    func unsafeMailboxResultStillStops(error: MailVerificationError) async throws {
        let coordinator = coordinator()
        var reads = 0
        await #expect(throws: error) {
            let _: String = try await coordinator.waitForMailbox {
                reads += 1
                throw error
            }
        }
        #expect(reads == 1)
    }

    @Test func cancellationStopsContinuousMailboxWait() async throws {
        let coordinator = coordinator()
        var reads = 0
        let task = Task { () throws -> String in
            try await coordinator.waitForMailbox {
                reads += 1
                throw MailVerificationError.timedOut
            }
        }
        while reads == 0 { await Task.yield() }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(reads == 1)
    }
}
