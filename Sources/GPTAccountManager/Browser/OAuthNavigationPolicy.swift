import Foundation

enum OAuthCallbackMode: String, CaseIterable, Identifiable {
    case automatic, copyLink

    var id: Self { self }
    var title: String {
        switch self {
        case .automatic: "Вернуть в приложение"
        case .copyLink: "Скопировать callback"
        }
    }
}

enum BrowserAddress {
    static func url(from text: String) -> URL? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !value.contains(where: \.isWhitespace),
              let url = URL(string: value, encodingInvalidCharacters: false),
              ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil,
              url.port.map({ (1...65535).contains($0) }) ?? true
        else { return nil }
        return url
    }
}

@MainActor
protocol AccountSessionProviding: AnyObject {
    func accountSession(for account: AccountRecord) -> BrowserSession
    func existingAccountSession(for account: AccountRecord) -> BrowserSession?
    func authorizationSession(for account: AccountRecord) async throws -> BrowserSession
}

extension AccountSessionProviding {
    func authorizationSession(for account: AccountRecord) async throws -> BrowserSession {
        accountSession(for: account)
    }
}

/// The authorization URL stays in memory. Only its exact callback destination
/// may leave OpenAI; this includes CodexAcc's dynamically allocated loopback port.
struct OAuthNavigationPolicy {
    let redirectURL: URL
    private let state: String?

    init?(authorizationURL: URL) {
        guard authorizationURL.scheme?.lowercased() == "https",
              authorizationURL.host?.lowercased() == "auth.openai.com",
              authorizationURL.port == nil || authorizationURL.port == 443,
              authorizationURL.user == nil, authorizationURL.password == nil,
              ["/oauth/authorize", "/authorize"].contains(authorizationURL.path),
              let items = URLComponents(url: authorizationURL, resolvingAgainstBaseURL: false)?.queryItems
        else { return nil }
        let clients = items.filter { $0.name == "client_id" }
        let redirects = items.filter { $0.name == "redirect_uri" }
        let states = items.filter { $0.name == "state" }
        guard clients.count == 1, clients[0].value?.isEmpty == false,
              redirects.count == 1, states.count <= 1,
              let rawRedirect = redirects[0].value,
              let redirect = URL(string: rawRedirect),
              redirect.user == nil, redirect.password == nil, redirect.fragment == nil,
              let host = redirect.host?.lowercased(), !host.isEmpty,
              BrowserAddress.url(from: rawRedirect) != nil
        else { return nil }
        redirectURL = redirect
        state = states.first?.value
    }

    func allowsCallback(_ url: URL?) -> Bool {
        guard let url,
              url.user == nil, url.password == nil, url.fragment == nil,
              url.scheme?.lowercased() == redirectURL.scheme?.lowercased(),
              url.host?.lowercased() == redirectURL.host?.lowercased(),
              effectivePort(url) == effectivePort(redirectURL),
              url.path == redirectURL.path
        else { return false }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let originalItems = URLComponents(url: redirectURL, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard originalItems.allSatisfy({ items.contains($0) }) else { return false }
        if let state {
            let values = items.filter { $0.name == "state" }
            guard values.count == 1, values[0].value == state else { return false }
        }
        return true
    }

    private func effectivePort(_ url: URL) -> Int {
        url.port ?? (url.scheme?.lowercased() == "https" ? 443 : 80)
    }
}
