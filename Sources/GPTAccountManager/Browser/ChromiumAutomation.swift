import Foundation

@MainActor
final class ChromiumAutomation: SubscriptionChecking, TwoFARotating {
    private enum AutomationError: Error {
        case unexpectedCheckpoint
    }

    private let worker: ChromiumWorkerRunning
    private var activeWorkerTasks: [UUID: Task<ChromiumWorkerResult, Never>] = [:]

    var activeSession: BrowserSession? { nil }
    var maximumConcurrentRotations: Int { 1 }

    init(worker: ChromiumWorkerRunning) {
        self.worker = worker
    }

    func cancelActiveOperation() {
        for task in activeWorkerTasks.values { task.cancel() }
    }

    func check(account: AccountRecord) async -> SubscriptionCheckOutcome {
        let result = await run(
            request: request(operation: .check, account: account)) { _ in
                throw AutomationError.unexpectedCheckpoint
            }

        switch result {
        case .success(let success):
            do {
                return .success(try subscriptionSnapshot(from: success))
            } catch {
                return .failure("Не удалось прочитать данные тарифа из Google Chrome.")
            }
        case .manual(_, let message):
            return .manualActionRequired(sanitize(message, account: account))
        case .failure(_, let message):
            return .failure(sanitize(message, account: account))
        }
    }

    func rotate2FA(
        account: AccountRecord,
        onCheckpoint: @escaping @MainActor (RotationCheckpointEvent) throws -> Void
    ) async -> TwoFARotationOutcome {
        if account.rotationStage == .removingOldMethod ||
            account.rotationStage == .oldMethodDisabled
        {
            return .manualActionRequired(
                stage: account.rotationStage,
                message: "Продолжите восстановление в исходной открытой сессии приложения.")
        }

        let result = await run(
            request: request(operation: .rotate, account: account)) { checkpoint in
                switch checkpoint {
                case .removalStarted:
                    try onCheckpoint(.removalStarted)
                case .oldMethodDisabled:
                    try onCheckpoint(.oldMethodDisabled)
                case .secretCaptured(let secret):
                    try onCheckpoint(.secretCaptured(secret))
                case .setupConfirmed:
                    try onCheckpoint(.setupConfirmed)
                }
            }

        switch result {
        case .success(let success):
            guard let proof = success.proof else {
                return .failure(
                    stage: account.rotationStage,
                    message: "External Chrome did not return clean-login proof.")
            }
            do {
                let snapshot = try subscriptionSnapshot(from: success)
                return .success(
                    snapshot: snapshot,
                    proof: .init(
                        passwordSubmitted: proof.passwordSubmitted,
                        pendingOTPSubmitted: proof.pendingOTPSubmitted,
                        authenticatedImmediatelyAfterPendingOTP:
                            proof.authenticatedImmediatelyAfterPendingOTP))
            } catch {
                return .failure(
                    stage: account.rotationStage,
                    message: "External Chrome did not return subscription data.")
            }

        case .manual(let stage, let message):
            return .manualActionRequired(
                stage: stage,
                message: sanitize(message, account: account))

        case .failure(let stage, let message):
            return .failure(
                stage: stage,
                message: sanitize(message, account: account))
        }
    }

    private func run(
        request: ChromiumWorkerRequest,
        onCheckpoint: @escaping @MainActor (ChromiumWorkerCheckpoint) throws -> Void
    ) async -> ChromiumWorkerResult {
        let id = UUID()
        let task = Task { @MainActor [worker] in
            await worker.run(request: request, onCheckpoint: onCheckpoint)
        }
        activeWorkerTasks[id] = task
        defer { activeWorkerTasks.removeValue(forKey: id) }
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func request(
        operation: ChromiumWorkerOperation,
        account: AccountRecord
    ) -> ChromiumWorkerRequest {
        .init(
            operation: operation,
            email: account.email,
            password: account.password,
            currentSecret: account.totpSecret,
            pendingSecret: account.pendingTOTPSecret,
            rotationStage: account.rotationStage)
    }

    private func subscriptionSnapshot(
        from success: ChromiumWorkerSuccess
    ) throws -> SubscriptionSnapshot {
        var value: [String: Any] = [
            "state": "success",
            "email": success.signedInEmail,
            "plan": success.planLabel ?? "unknown",
            "source": "subscription",
        ]
        if let activeUntil = success.activeUntil {
            value["activeUntil"] = activeUntil
        }
        if let activeUntilText = success.activeUntilText {
            value["activeUntilText"] = activeUntilText
        }
        if let locale = success.locale {
            value["activeUntilLocale"] = locale
        }
        if let willRenew = success.willRenew {
            value["willRenew"] = willRenew
        }
        return try SubscriptionSnapshot(javaScriptValue: value)
    }

    private func sanitize(_ message: String, account: AccountRecord) -> String {
        var sanitized = message
        let sensitiveValues = [
            account.email,
            account.password,
            account.totpSecret,
            account.pendingTOTPSecret,
        ].compactMap { value -> String? in
            guard let value, !value.isEmpty else { return nil }
            return value
        }
        for value in sensitiveValues {
            sanitized = sanitized.replacingOccurrences(of: value, with: "[redacted]")
        }
        return String(sanitized.prefix(240))
    }
}
