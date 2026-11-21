import AppKit
import Observation
import OSLog

@MainActor
@Observable
final class GitStartupUpdate {
    static let skipArgument = "--skip-git-update-on-launch"

    enum Phase {
        case checking, restarting, ready

        var title: String {
            switch self {
            case .checking: "Проверяю стабильный релиз GitHub…"
            case .restarting: "Запускаю обновлённую версию…"
            case .ready: ""
            }
        }
    }

    private static let logger = Logger(subsystem: "local.wemakecode.gptaccountmanager", category: "startup-update")
    private(set) var phase = Phase.checking
    @ObservationIgnored private var started = false

    func start() {
        guard !started else { return }
        started = true
        let arguments = ProcessInfo.processInfo.arguments
        let bundle = Bundle.main.bundleURL.resolvingSymlinksInPath().standardizedFileURL
        guard !arguments.contains(Self.skipArgument), !arguments.contains(PasswordGroupLaunch.flag),
              let checkout = Self.managedCheckout(for: bundle),
              let revision = Bundle.main.object(forInfoDictionaryKey: "GPTAMBuildCommit") as? String,
              revision.range(of: #"^[0-9a-f]{40}$"#, options: .regularExpression) != nil,
              let helper = Bundle.main.url(forResource: "update_on_launch", withExtension: "sh") else {
            phase = .ready
            return
        }
        Task {
            do {
                if let stage = try await firstLine(from: helper, arguments: ["prepare", checkout.path, revision]),
                   try await firstLine(from: helper, arguments: [
                       "install", checkout.path, String(ProcessInfo.processInfo.processIdentifier), stage,
                   ], preservePassword: true) == "ready" {
                    phase = .restarting
                    NSApp.terminate(nil)
                    return
                }
            } catch {
                Self.logger.error("Could not start the Git updater.")
            }
            phase = .ready
        }
    }

    static func managedCheckout(for bundle: URL) -> URL? {
        let parent = bundle.deletingLastPathComponent()
        guard bundle.lastPathComponent == "GPT Account Manager.app", parent.lastPathComponent == "dist" else {
            return nil
        }
        let checkout = parent.deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath: checkout.appendingPathComponent(".git").path) else { return nil }
        return checkout
    }

    private func firstLine(from helper: URL, arguments: [String], preservePassword: Bool = false) async throws -> String? {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [helper.path] + arguments
        var environment = ProcessInfo.processInfo.environment
        if !preservePassword { environment.removeValue(forKey: NewPasswordConfiguration.environmentKey) }
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer { try? output.fileHandleForReading.close() }
        var lines = output.fileHandleForReading.bytes.lines.makeAsyncIterator()
        return try await lines.next()
    }
}
