import Foundation

/// Explicit local invocation of the same password queue used by the group button.
@MainActor
enum PasswordGroupLaunch {
    static let flag = "--change-passwords-in-group-id"
    private static var claimed = false

    static func groupID(arguments: [String]) throws -> UUID? {
        let positions = arguments.indices.filter { arguments[$0] == flag }
        guard !positions.isEmpty else { return nil }
        guard positions.count == 1, let position = positions.first,
              arguments.indices.contains(position + 1),
              let id = UUID(uuidString: arguments[position + 1]) else { throw LaunchError.invalidArguments }
        return id
    }

    static func claim(arguments: [String] = ProcessInfo.processInfo.arguments) throws -> UUID? {
        guard !claimed else { return nil }
        guard let id = try groupID(arguments: arguments) else { return nil }
        claimed = true
        return id
    }

    static func accountIDs(groupID: UUID, store: AccountStore) throws -> [UUID] {
        guard store.groups.contains(where: { $0.id == groupID }) else { throw LaunchError.missingGroup }
        let accounts = store.accounts(in: groupID)
        guard !accounts.isEmpty else { throw LaunchError.emptyGroup }
        guard accounts.allSatisfy({
            $0.pendingRegistration == nil && $0.pendingEmailChange == nil &&
            $0.rotationStage == nil && $0.pendingTOTPSecret == nil &&
            (!$0.hasPendingAccessChange || $0.pendingAccessChangeMode == .password)
        }) else { throw LaunchError.conflictingOperation }
        return accounts.map(\.id)
    }

    static func recordResult(groupID: UUID, ids: [UUID], store: AccountStore, coordinator: OperationCoordinator) {
        struct Result: Codable {
            let processID: Int32
            let recordedAt: Date
            let groupID: UUID
            let accountCount: Int
            let verifiedCount: Int
            let pausedCount: Int
            let failedCount: Int
            let running: Bool
            let stage: String
        }
        let session = coordinator.pausedRotationAccountID.flatMap { coordinator.browserSession(for: $0) }
        let result = Result(processID: ProcessInfo.processInfo.processIdentifier, recordedAt: Date(), groupID: groupID, accountCount: ids.count,
            verifiedCount: ids.count { coordinator.rotationStates[$0] == .complete },
            pausedCount: coordinator.pausedRotationAccountIDs.count,
            failedCount: coordinator.rotationStates.values.filter { if case .failed = $0 { return true }; return false }.count,
            running: coordinator.isRunning,
            stage: PasswordChangeTelemetry.route(session?.webView.url))
        let path = store.fileURL.deletingLastPathComponent().appendingPathComponent("password-group-result.json")
        guard let data = try? JSONEncoder().encode(result) else { return }
        try? data.write(to: path, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
    }

    enum LaunchError: Error, LocalizedError {
        case invalidArguments, missingGroup, emptyGroup, conflictingOperation
        var errorDescription: String? {
            switch self {
            case .invalidArguments: "Не указан единственный корректный ID группы для смены паролей."
            case .missingGroup: "Указанная группа для смены паролей не найдена."
            case .emptyGroup: "В указанной группе нет аккаунтов."
            case .conflictingOperation: "В группе есть другая незавершённая операция. Смена паролей не запущена."
            }
        }
    }
}
