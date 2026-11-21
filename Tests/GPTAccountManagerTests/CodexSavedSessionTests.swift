import AppKit
import Foundation
import Testing
import WebKit
@testable import GPTAccountManager

@MainActor
final class SavedSessionFixtureWebView: WKWebView {
    var email: String? = "owner@example.com"
    var usesCookie = false
    var responseStatus = 200
    var loadedURLs: [URL] = []

    override func load(_ request: URLRequest) -> WKNavigation? {
        if let url = request.url { loadedURLs.append(url) }
        let encoded = String(decoding: try! JSONEncoder().encode(email), as: UTF8.self)
        return super.loadHTMLString("""
        <main>Local saved-session fixture</main>
        <script>
        window.fetch = async () => ({
          ok: \(responseStatus == 200), status: \(responseStatus),
          json: async () => ({user: \(usesCookie ? "document.cookie.includes('fixture_auth=valid')" : "true")
            ? {email:\(encoded), id:'fixture-user'} : null})
        });
        </script>
        """, baseURL: request.url)
    }
}

@MainActor
func savedSessionFixture(email: String? = "owner@example.com", usesCookie: Bool = false, status: Int = 200) -> BrowserSession {
    _ = NSApplication.shared
    return BrowserSession(dataStore: .nonPersistent()) { configuration in
        let web = SavedSessionFixtureWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 700), configuration: configuration)
        web.email = email
        web.usesCookie = usesCookie
        web.responseStatus = status
        return web
    }
}

@MainActor
@Suite(.serialized)
struct CodexSavedSessionTests {
    private let account = AccountRecord(credential: .init(
        email: "owner@example.com", password: "fixture-password", totpSecret: "JBSWY3DPEHPK3PXP"))

    private func load(_ session: BrowserSession) async throws {
        #expect(await session.loadInitialPage(URL(string: "https://chatgpt.com/")!, seconds: 3, attempts: 1))
    }

    private func cookie(_ name: String, value: String, domain: String, secure: Bool = true) throws -> HTTPCookie {
        var properties: [HTTPCookiePropertyKey: Any] = [
            .domain: domain, .path: "/", .name: name, .value: value,
            .expires: Date().addingTimeInterval(600),
        ]
        if secure { properties[.secure] = "TRUE" }
        return try #require(HTTPCookie(properties: properties))
    }

    @Test func reusesLivePersistentSessionWithoutNavigation() async throws {
        let session = savedSessionFixture()
        try await load(session)
        let browser = ChatGPTAutomation(sessionManager: WebSessionManager(accountSessionFactory: { _ in session }))
        let loads = (session.webView as! SavedSessionFixtureWebView).loadedURLs.count
        #expect(try await browser.authorizationSession(for: account) === session)
        #expect((session.webView as! SavedSessionFixtureWebView).loadedURLs.count == loads)
    }

    @Test(arguments: [200, 401, 403])
    func absentOrExpiredSessionRemainsAvailableForOAuth(status: Int) async throws {
        let session = savedSessionFixture(email: nil, status: status)
        let browser = ChatGPTAutomation(sessionManager: WebSessionManager(accountSessionFactory: { _ in session }))
        #expect(try await browser.authorizationSession(for: account) === session)
        #expect((session.webView as! SavedSessionFixtureWebView).loadedURLs == [URL(string: "https://chatgpt.com/")!])
    }

    @Test(arguments: ["wrong-account", "server-error", "pending-change"])
    func refusesUnprovenSession(behavior: String) async throws {
        let session = savedSessionFixture(email: behavior == "wrong-account" ? "other@example.com" : account.email,
                                          status: behavior == "server-error" ? 500 : 200)
        let browser = ChatGPTAutomation(sessionManager: WebSessionManager(accountSessionFactory: { _ in session }))
        var selected = account
        if behavior == "pending-change" { selected.pendingPassword = "pending-fixture" }
        do {
            _ = try await browser.authorizationSession(for: selected)
            Issue.record("Unproven session was accepted")
        } catch let error as ChatGPTAutomation.SavedSessionError {
            switch (behavior, error) {
            case ("wrong-account", .wrongAccount), ("server-error", .unavailable), ("pending-change", .pendingChange): break
            default: Issue.record("Wrong failure category")
            }
        }
    }

    @Test func verifiedLoginCopiesOnlyFirstPartySecureCookiesAndChecksDestination() async throws {
        let source = savedSessionFixture()
        let destination = savedSessionFixture(usesCookie: true)
        let sourceCookies = [
            try cookie("fixture_auth", value: "valid", domain: "chatgpt.com"),
            try cookie("fixture_sso", value: "valid", domain: ".openai.com"),
            try cookie("fixture_auth_sso", value: "valid", domain: "auth.openai.com"),
            try cookie("fixture_external", value: "blocked", domain: "example.com"),
            try cookie("fixture_insecure", value: "blocked", domain: "auth.openai.com", secure: false),
            try cookie("fixture_lookalike", value: "blocked", domain: "chatgpt.com.example.com"),
        ]
        for cookie in sourceCookies { await source.webView.configuration.websiteDataStore.httpCookieStore.setCookie(cookie) }
        let previous = try cookie("fixture_old", value: "old", domain: "chatgpt.com")
        let unrelated = try cookie("fixture_keep", value: "keep", domain: "example.org")
        let store = destination.webView.configuration.websiteDataStore.httpCookieStore
        await store.setCookie(previous)
        await store.setCookie(unrelated)
        try await load(source)
        let browser = ChatGPTAutomation(sessionManager: WebSessionManager(accountSessionFactory: { _ in destination }))
        try await browser.persistVerifiedSession(from: source, for: account)
        let names = Set(await store.allCookies().map(\.name))
        #expect(names == ["fixture_auth", "fixture_sso", "fixture_auth_sso", "fixture_keep"])
        #expect(try await browser.hasAuthenticatedSession(for: account, in: destination))
    }

    @Test func matchingChatGPTIdentityStillReceivesFreshSSOCookie() async throws {
        let source = savedSessionFixture()
        let destination = savedSessionFixture()
        let sourceStore = source.webView.configuration.websiteDataStore.httpCookieStore
        let destinationStore = destination.webView.configuration.websiteDataStore.httpCookieStore
        await sourceStore.setCookie(try cookie("fixture_sso", value: "fresh", domain: "auth.openai.com"))
        await destinationStore.setCookie(try cookie("fixture_sso", value: "stale", domain: "auth.openai.com"))
        try await load(source)
        try await load(destination)
        let browser = ChatGPTAutomation(sessionManager: WebSessionManager(accountSessionFactory: { _ in destination }))
        #expect(try await browser.hasAuthenticatedSession(for: account, in: destination))
        try await browser.persistVerifiedSession(from: source, for: account)
        let saved = await destinationStore.allCookies().first { $0.name == "fixture_sso" }
        #expect(saved?.value == "fresh")
        #expect(try await browser.hasAuthenticatedSession(for: account, in: destination))
    }

    @Test func failedPromotionRestoresPreviousCookies() async throws {
        let source = savedSessionFixture()
        let destination = savedSessionFixture(email: "other@example.com", usesCookie: true)
        let sourceStore = source.webView.configuration.websiteDataStore.httpCookieStore
        await sourceStore.setCookie(try cookie("fixture_auth", value: "valid", domain: "chatgpt.com"))
        let destinationStore = destination.webView.configuration.websiteDataStore.httpCookieStore
        await destinationStore.setCookie(try cookie("fixture_old", value: "original", domain: "chatgpt.com"))
        try await load(source)
        let browser = ChatGPTAutomation(sessionManager: WebSessionManager(accountSessionFactory: { _ in destination }))
        do {
            try await browser.persistVerifiedSession(from: source, for: account)
            Issue.record("Wrong identity accepted after promotion")
        } catch ChatGPTAutomation.SavedSessionError.wrongAccount {}
        let remaining = await destinationStore.allCookies()
        #expect(remaining.map(\.name) == ["fixture_old"])
        #expect(remaining.first?.value == "original")
    }

    @Test func failedSessionProbeDoesNotStartCredentialLogin() async throws {
        let session = savedSessionFixture(status: 500)
        let browser = ChatGPTAutomation(sessionManager: WebSessionManager(accountSessionFactory: { _ in session }))
        let outcome = await browser.check(account: account)
        guard case .manualActionRequired = outcome else { Issue.record("Unavailable session must pause"); return }
        #expect((session.webView as! SavedSessionFixtureWebView).loadedURLs.allSatisfy { $0.host == "chatgpt.com" })
    }
}
