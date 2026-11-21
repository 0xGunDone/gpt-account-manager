import Foundation
import Observation

enum RotationQueueItemState: Equatable, Sendable {
    case queued
    case running
    case manualAction(String)
    case complete
    case failed(String)

    var isTerminalForBatchProgress: Bool {
        switch self {
        case .manualAction, .complete, .failed: true
        case .queued, .running: false
        }
    }
}

@MainActor
@Observable
final class RotationQueue {
    typealias Worker = @MainActor @Sendable (UUID) async -> RotationQueueItemState

    private(set) var states: [UUID: RotationQueueItemState] = [:]
    private(set) var totalCount = 0
    private var orderedIDs: [UUID] = []
    private var isRunning = false
    private(set) var pausedAccountIDs: Set<UUID> = []
    private var cancellationRequested = false

    var activeAccountIDs: Set<UUID> {
        Set(states.compactMap { $0.value == .running ? $0.key : nil })
    }

    var accountIDs: Set<UUID> {
        Set(states.keys)
    }

    var completedCount: Int {
        states.values.count(where: \.isTerminalForBatchProgress)
    }

    func start(
        accountIDs: [UUID],
        concurrency _: Int = 1,
        worker: @escaping Worker
    ) async {
        guard !isRunning, pausedAccountIDs.isEmpty else { return }
        cancellationRequested = false
        var seen: Set<UUID> = []
        let snapshot = accountIDs.filter { seen.insert($0).inserted }
        orderedIDs = snapshot
        totalCount = snapshot.count
        states = Dictionary(uniqueKeysWithValues: snapshot.map { ($0, .queued) })
        await run(worker: worker)
    }

    func resume(accountID: UUID, worker: @escaping Worker) async {
        guard !isRunning, pausedAccountIDs.contains(accountID) else { return }
        pausedAccountIDs.remove(accountID)
        cancellationRequested = false
        states[accountID] = .queued
        await run(worker: worker)
    }

    func cancel() {
        cancellationRequested = true
        pausedAccountIDs.removeAll()
        for (id, state) in states {
            switch state {
            case .queued, .manualAction:
                states[id] = .failed("Stopped")
            case .running, .complete, .failed:
                break
            }
        }
    }

    private func run(worker: @escaping Worker) async {
        isRunning = true
        defer { isRunning = false }
        // Always serial, including legacy callers that still supply concurrency > 1.
        for id in orderedIDs where states[id] == .queued {
            guard !cancellationRequested, !Task.isCancelled else { cancel(); return }
            states[id] = .running
            let result = await worker(id)
            states[id] = result
            if cancellationRequested || Task.isCancelled {
                if result != .complete { states[id] = .failed("Stopped") }
                cancel()
                return
            }
            guard result == .complete else {
                // Keep this browser and its recovery checkpoint; do not start another account.
                pausedAccountIDs.insert(id)
                return
            }
        }
    }
}
