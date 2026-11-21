import AppKit
import Observation
import OSLog

@MainActor
@Observable
final class GitStartupUpdate {
    static let skipArgument = "--skip-git-update-on-launch"

    struct Release: Equatable {
        let tag: String
        let commit: String

        init?(_ line: String) {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count == 3, fields[0] == "available",
                  fields[1].range(of: #"^v[0-9]+\.[0-9]+\.[0-9]+$"#, options: .regularExpression) != nil,
                  GitStartupUpdate.isCommit(String(fields[2])) else { return nil }
            tag = String(fields[1])
            commit = String(fields[2])
        }
    }

    enum Phase: Equatable {
        case checking, checkFailed, available(Release), downloading, building, installing, restarting, failed, ready

        var title: String {
            switch self {
            case .checking: "Проверяю стабильный релиз GitHub…"
            case .checkFailed: "Не удалось проверить обновления"
            case .available(let release): "Доступно обновление \(release.tag)"
            case .downloading: "Загрузка обновления…"
            case .building: "Сборка и подпись приложения…"
            case .installing: "Подготовка к установке…"
            case .restarting: "Запускаю обновлённую версию…"
            case .failed: "Обновление не установлено"
            case .ready: ""
            }
        }
    }

    private static let logger = Logger(subsystem: "local.wemakecode.gptaccountmanager", category: "startup-update")
    private(set) var phase = Phase.checking
    @ObservationIgnored private var started = false
    @ObservationIgnored private var source: (helper: URL, checkout: URL, revision: String)?

    func start() {
        guard !started else { return }
        started = true
        let arguments = ProcessInfo.processInfo.arguments
        let bundle = Bundle.main.bundleURL.resolvingSymlinksInPath().standardizedFileURL
        guard !arguments.contains(Self.skipArgument), !arguments.contains(PasswordGroupLaunch.flag),
              let checkout = Self.managedCheckout(for: bundle),
              let revision = Bundle.main.object(forInfoDictionaryKey: "GPTAMBuildCommit") as? String,
              Self.isCommit(revision),
              let helper = Bundle.main.url(forResource: "update_on_launch", withExtension: "sh") else {
            phase = .ready
            return
        }
        source = (helper, checkout, revision)
        Task {
            do {
                let result = try await output(from: helper, arguments: ["check", checkout.path, revision]) { _ in true }
                guard phase == .checking else { return }
                if let result, let release = Release(result) {
                    phase = .available(release)
                    return
                }
                if result == "current" {
                    phase = .ready
                    return
                }
            } catch {
                Self.logger.error("Could not check for a stable release.")
            }
            if phase == .checking { phase = .checkFailed }
        }
    }

    func useInstalledVersion() {
        switch phase {
        case .checking, .checkFailed, .available, .failed:
            phase = .ready
        default:
            break
        }
    }

    func installAvailableRelease() {
        guard case .available(let release) = phase, let source else { return }
        phase = .downloading
        Task {
            do {
                let response = try await output(from: source.helper, arguments: [
                    "prepare", source.checkout.path, source.revision, release.tag, release.commit,
                ]) { line in
                    switch line {
                    case "downloading": self.phase = .downloading
                    case "building": self.phase = .building
                    default: break
                    }
                    return false
                }
                if let response, response.hasPrefix("staged\t") {
                    let stage = String(response.dropFirst("staged\t".count))
                    phase = .installing
                    let receipt = try await output(from: source.helper, arguments: [
                        "install", source.checkout.path, String(ProcessInfo.processInfo.processIdentifier), stage,
                    ], preservePassword: true) { $0 == "ready" }
                    if receipt == "ready" {
                        phase = .restarting
                        NSApp.terminate(nil)
                        return
                    }
                }
            } catch {
                Self.logger.error("Could not prepare or install the confirmed stable release.")
            }
            phase = .failed
        }
    }

    private nonisolated static func isCommit(_ value: String) -> Bool {
        value.range(of: #"^[0-9a-f]{40}$"#, options: .regularExpression) != nil
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

    // Install signals readiness before exit because it waits for this app to quit.
    private func output(from helper: URL, arguments: [String], preservePassword: Bool = false,
                        stopReading: (String) -> Bool) async throws -> String? {
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
        var lastLine: String?
        for try await line in output.fileHandleForReading.bytes.lines {
            lastLine = line
            if stopReading(line) { break }
        }
        return lastLine
    }
}
