import Foundation
import Testing
@testable import GPTAccountManager

@MainActor
struct RotationQueueTests {
    @Test func legacyParallelRequestStillRunsOneAccountAtATime() async {
        let queue = RotationQueue()
        let ids = [UUID(), UUID(), UUID()]
        var active = 0
        var maximumActive = 0
        var events: [String] = []
        await queue.start(accountIDs: ids, concurrency: 3) { id in
            active += 1
            maximumActive = max(maximumActive, active)
            let index = ids.firstIndex(of: id)!
            events.append("start\(index)")
            try? await Task.sleep(for: .milliseconds(20))
            events.append("end\(index)")
            active -= 1
            return .complete
        }
        #expect(maximumActive == 1)
        #expect(events == ["start0", "end0", "start1", "end1", "start2", "end2"])
        #expect(queue.states.values.allSatisfy { $0 == .complete })
    }

    @Test(arguments: [RotationQueueItemState.manualAction("Continue in current session"), .failed("Page stalled")])
    func interruptionStopsWholeBatchUntilCurrentAccountCompletes(interruption: RotationQueueItemState) async {
        let queue = RotationQueue()
        let ids = [UUID(), UUID(), UUID()]
        var started: [UUID] = []
        await queue.start(accountIDs: ids, concurrency: 3) { id in
            started.append(id)
            return interruption
        }
        #expect(started == [ids[0]])
        #expect(queue.states[ids[1]] == .queued)
        #expect(queue.states[ids[2]] == .queued)
        #expect(queue.pausedAccountIDs == [ids[0]])
        await queue.resume(accountID: ids[0]) { id in
            started.append(id)
            return .complete
        }
        #expect(started == [ids[0], ids[0], ids[1], ids[2]])
        #expect(queue.states.values.allSatisfy { $0 == .complete })
    }

    @Test func cancellationNeverStartsWaitingAccountsOrResumesCancelledBatch() async throws {
        let queue = RotationQueue()
        let ids = [UUID(), UUID(), UUID()]
        var started: [UUID] = []
        var release: CheckedContinuation<Void, Never>?
        let task = Task {
            await queue.start(accountIDs: ids, concurrency: 3) { id in
                started.append(id)
                if id == ids[0] { await withCheckedContinuation { release = $0 } }
                return .complete
            }
        }
        while release == nil { try await Task.sleep(for: .milliseconds(5)) }
        queue.cancel()
        release?.resume()
        await task.value
        #expect(started == [ids[0]])
        #expect(queue.states[ids[0]] == .complete)
        #expect(queue.states[ids[1]] == .failed("Stopped"))
        #expect(queue.pausedAccountIDs.isEmpty)
        await queue.resume(accountID: ids[1]) { id in started.append(id); return .complete }
        #expect(started == [ids[0]])
    }

    @Test func anotherStartCannotReplaceRunningBatch() async throws {
        let queue = RotationQueue()
        let first = UUID(), second = UUID()
        var release: CheckedContinuation<Void, Never>?
        let task = Task {
            await queue.start(accountIDs: [first], concurrency: 1) { _ in
                await withCheckedContinuation { release = $0 }
                return .complete
            }
        }
        while release == nil { try await Task.sleep(for: .milliseconds(5)) }
        var secondStarted = false
        await queue.start(accountIDs: [second], concurrency: 1) { _ in
            secondStarted = true
            return .complete
        }
        release?.resume()
        await task.value
        #expect(!secondStarted)
        #expect(queue.accountIDs == [first])
    }
}
