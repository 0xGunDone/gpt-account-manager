import Foundation

enum BrowserRecoveryContext: Equatable, Sendable {
    case subscriptionCheck
    case rotation(stage: RotationStage?)
}

enum BrowserFreshLoginMode: Equatable, Sendable {
    case storedSecret
    case manualFactor
    case pendingSecret
}

enum BrowserRecoveryDestination: Equatable, Sendable {
    case chatGPT
    case security
}

struct BrowserRecoveryAvailability: Equatable, Sendable {
    let canReload: Bool
    let reopenDestination: BrowserRecoveryDestination?
    let freshLoginMode: BrowserFreshLoginMode
    let canReturnToOriginalSession: Bool
    let warning: String
}

enum BrowserRecoveryPolicy {
    static func availability(
        context: BrowserRecoveryContext,
        hasTrustedPage: Bool,
        hasCandidate: Bool
    ) -> BrowserRecoveryAvailability {
        let mode: BrowserFreshLoginMode
        let destination: BrowserRecoveryDestination?
        let warning: String

        switch context {
        case .subscriptionCheck:
            mode = .storedSecret
            destination = hasCandidate ? nil : .chatGPT
            warning = "Будет создана новая временная сессия проверки."
        case .rotation(stage: nil):
            mode = .storedSecret
            destination = hasCandidate ? nil : .security
            warning = "Смена 2FA ещё не началась; можно безопасно повторить вход."
        case .rotation(stage: .removingOldMethod):
            mode = .manualFactor
            destination = hasCandidate ? nil : .security
            warning = "После входа с паролем приложение один раз попробует сохранённый 2FA на распознанной форме OpenAI."
        case .rotation(stage: .oldMethodDisabled),
             .rotation(stage: .pendingSecretCaptured):
            mode = .manualFactor
            destination = hasCandidate ? nil : .security
            warning = "Старый 2FA уже мог быть отключён. В новой сессии приложение не отправит старый код автоматически."
        case .rotation(stage: .awaitingCleanLogin):
            mode = .pendingSecret
            destination = nil
            warning = "Будет заново выполнен только проверочный вход с ожидающим 2FA."
        }

        return BrowserRecoveryAvailability(
            canReload: hasTrustedPage,
            reopenDestination: destination,
            freshLoginMode: mode,
            canReturnToOriginalSession: hasCandidate,
            warning: warning)
    }
}
