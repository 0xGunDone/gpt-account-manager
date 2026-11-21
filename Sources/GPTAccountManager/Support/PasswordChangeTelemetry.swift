import Foundation
import OSLog

enum PasswordChangeTelemetry {
    private static let logger = Logger(subsystem: "local.wemakecode.gptaccountmanager", category: "password-change")

    enum Event: String {
        case started, reauthenticationReturned, reopeningSettings, passwordFormOpened
        case passwordSubmitted, verificationStarted, verified, paused, cancelled
    }

    static func record(_ event: Event) {
        logger.notice("\(event.rawValue, privacy: .public)")
    }

    // Closed labels only: never log URLs, query parameters, email, password, or mailbox code.
    static func route(_ url: URL?) -> String {
        guard let url else { return "not-loaded" }
        if url.host == "auth.openai.com" {
            if ["/email-verification", "/verify-email"].contains(url.path) { return "email-code" }
            if url.path.hasPrefix("/mfa-challenge/") { return "authenticator-code" }
            if url.path == "/log-in/password" { return "login-password" }
            if url.path.contains("reset-password") { return "password-form" }
            return "authentication"
        }
        if url.host == "chatgpt.com" {
            if url.fragment?.lowercased().contains("settings") == true || url.path.hasPrefix("/settings") {
                return "settings"
            }
            return "chatgpt"
        }
        return "outside"
    }

    static func recordRoute(_ route: String) {
        logger.notice("page=\(route, privacy: .public)")
    }
}
