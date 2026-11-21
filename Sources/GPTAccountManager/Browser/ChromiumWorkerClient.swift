import Foundation

@MainActor
protocol ChromiumWorkerRunning: AnyObject {
    func run(
        request: ChromiumWorkerRequest,
        onCheckpoint: @escaping @MainActor (ChromiumWorkerCheckpoint) throws -> Void
    ) async -> ChromiumWorkerResult
}

private final class ChromiumProcessBox: @unchecked Sendable {
    let process: Process

    init(_ process: Process) {
        self.process = process
    }

    func terminate() {
        if process.isRunning {
            process.terminate()
        }
    }
}

@MainActor
final class ChromiumWorkerClient: ChromiumWorkerRunning {
    private let nodeURL: URL?
    private let workerURL: URL?
    private let additionalEnvironment: [String: String]
    private let requireChrome: Bool

    init(
        nodeURL: URL? = nil,
        workerURL: URL? = nil,
        additionalEnvironment: [String: String] = [:],
        requireChrome: Bool = true
    ) {
        self.nodeURL = nodeURL
        self.workerURL = workerURL
        self.additionalEnvironment = additionalEnvironment
        self.requireChrome = requireChrome
    }

    static func resolveNodeExecutable() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            home.appendingPathComponent(".local/bin/node"),
            URL(fileURLWithPath: "/opt/homebrew/bin/node"),
            URL(fileURLWithPath: "/usr/local/bin/node"),
            URL(fileURLWithPath: "/usr/bin/node"),
        ]
        return candidates.first(where: {
            FileManager.default.isExecutableFile(atPath: $0.path)
        })
    }

    func run(
        request: ChromiumWorkerRequest,
        onCheckpoint: @escaping @MainActor (ChromiumWorkerCheckpoint) throws -> Void
    ) async -> ChromiumWorkerResult {
        guard let node = nodeURL ?? Self.resolveNodeExecutable() else {
            return .failure(stage: request.rotationStage, message: "Node.js runtime is unavailable")
        }
        guard let worker = workerURL ?? Self.bundledWorkerURL(),
              FileManager.default.fileExists(atPath: worker.path)
        else {
            return .failure(stage: request.rotationStage, message: "Chromium worker is unavailable")
        }
        if requireChrome && !FileManager.default.isExecutableFile(
            atPath: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome")
        {
            return .failure(stage: request.rotationStage, message: "Google Chrome is unavailable")
        }

        let process = Process()
        let input = Pipe()
        let output = Pipe()
        process.executableURL = node
        process.arguments = [worker.path]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        var environment = ProcessInfo.processInfo.environment.merging(
            additionalEnvironment,
            uniquingKeysWith: { _, override in override })
        environment.removeValue(forKey: NewPasswordConfiguration.environmentKey)
        process.environment = environment
        let box = ChromiumProcessBox(process)

        do {
            try process.run()
            var payload = try JSONEncoder().encode(request)
            payload.append(0x0A)
            try input.fileHandleForWriting.write(contentsOf: payload)
        } catch {
            box.terminate()
            return .failure(stage: request.rotationStage, message: "Could not start external Chrome automation")
        }

        return await withTaskCancellationHandler {
            do {
                for try await line in output.fileHandleForReading.bytes.lines {
                    try Task.checkCancellation()
                    let event = try JSONDecoder().decode(
                        ChromiumWorkerEvent.self,
                        from: Data(line.utf8))
                    switch event {
                    case .checkpoint(let id, let checkpoint):
                        do {
                            try onCheckpoint(checkpoint)
                        } catch {
                            box.terminate()
                            try? input.fileHandleForWriting.close()
                            await Self.waitForExit(box)
                            return .failure(
                                stage: request.rotationStage,
                                message: "Could not persist Chromium checkpoint")
                        }
                        let acknowledgment = try JSONSerialization.data(
                            withJSONObject: ["type": "ack", "id": id])
                        try input.fileHandleForWriting.write(contentsOf: acknowledgment)
                        try input.fileHandleForWriting.write(contentsOf: Data([0x0A]))

                    case .result(let result):
                        try? input.fileHandleForWriting.close()
                        await Self.waitForExit(box)
                        return result
                    }
                }
                if Task.isCancelled {
                    return .failure(
                        stage: request.rotationStage,
                        message: "External Chrome automation cancelled")
                }
                return .failure(
                    stage: request.rotationStage,
                    message: "External Chrome worker stopped unexpectedly")
            } catch is CancellationError {
                box.terminate()
                try? input.fileHandleForWriting.close()
                await Self.waitForExit(box)
                return .failure(
                    stage: request.rotationStage,
                    message: "External Chrome automation cancelled")
            } catch {
                box.terminate()
                try? input.fileHandleForWriting.close()
                await Self.waitForExit(box)
                return .failure(
                    stage: request.rotationStage,
                    message: "External Chrome worker returned invalid data")
            }
        } onCancel: {
            box.terminate()
        }
    }

    private static func bundledWorkerURL() -> URL? {
        Bundle.main.resourceURL?
            .appendingPathComponent("BrowserWorker/src/worker.js")
    }

    private static func waitForExit(_ box: ChromiumProcessBox) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while box.process.isRunning, clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(25))
        }
        box.terminate()
    }
}
