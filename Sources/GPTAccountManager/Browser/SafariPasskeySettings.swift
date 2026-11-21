import Foundation
import SafariServices

@MainActor
enum SafariPasskeySettings {
    private static let extensionID = "local.wemakecode.gptaccountmanager.SafariSession"

    enum OpenError: LocalizedError {
        case extensionUnavailable, extensionDisabled, proxyConfigured, busy

        var errorDescription: String? {
            switch self {
            case .extensionUnavailable: "Расширение GPT Account Manager недоступно в Safari."
            case .extensionDisabled: "Включите расширение GPT Account Manager в Safari и разрешите ему доступ к chatgpt.com."
            case .proxyConfigured: "Для аккаунта включён отдельный прокси. Safari использует сетевые настройки macOS."
            case .busy: "Дождитесь завершения операции с аккаунтом."
            }
        }
    }

    static func checkExtension() async throws {
        let state: SFSafariExtensionState
        do {
            state = try await SFSafariExtensionManager.stateOfSafariExtension(withIdentifier: extensionID)
        } catch {
            throw OpenError.extensionUnavailable
        }
        guard state.isEnabled else {
            try? await SFSafariApplication.showPreferencesForExtension(withIdentifier: extensionID)
            throw OpenError.extensionDisabled
        }
    }

    static func open(email: String) async throws {
        try Task.checkCancellation()
        do {
            try await SFSafariApplication.dispatchMessage(
                withName: "openPasskeySettings", toExtensionWithIdentifier: extensionID,
                userInfo: ["email": email, "issuedAt": Date().timeIntervalSince1970,
                           "requestId": UUID().uuidString])
        } catch {
            throw OpenError.extensionUnavailable
        }
    }
}
