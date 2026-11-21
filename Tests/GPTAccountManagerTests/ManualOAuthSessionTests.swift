import AppKit
import Foundation
import Testing
import WebKit
@testable import GPTAccountManager

@MainActor
private final class ManualOAuthFixtureWebView: WKWebView {
    var requestedURLs: [URL] = []

    override func load(_ request: URLRequest) -> WKNavigation? {
        if let url = request.url { requestedURLs.append(url) }
        return super.loadHTMLString("<p>Local authorization fixture</p>", baseURL: request.url)
    }
}

@MainActor
final class ManualOAuthFixtureSessions: AccountSessionProviding {
    var holdPreflight = false
    var preflightError: ChatGPTAutomation.SavedSessionError?
    var suspendedPreflight: CheckedContinuation<Void, Never>?
    private(set) var preflightAccountIDs: [UUID] = []
    private var sessions: [UUID: BrowserSession] = [:]

    func accountSession(for account: AccountRecord) -> BrowserSession {
        if let session = sessions[account.id] { return session }
        _ = NSApplication.shared
        let session = BrowserSession(dataStore: .nonPersistent()) { configuration in
            ManualOAuthFixtureWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 700), configuration: configuration)
        }
        sessions[account.id] = session
        return session
    }

    func existingAccountSession(for account: AccountRecord) -> BrowserSession? {
        sessions[account.id]
    }

    func authorizationSession(for account: AccountRecord) async throws -> BrowserSession {
        preflightAccountIDs.append(account.id)
        let session = accountSession(for: account)
        if holdPreflight { await withCheckedContinuation { suspendedPreflight = $0 } }
        if let preflightError { throw preflightError }
        return session
    }

    func requestedURLs(for account: AccountRecord) -> [URL] {
        (sessions[account.id]?.webView as? ManualOAuthFixtureWebView)?.requestedURLs ?? []
    }

    func finishPreflight() {
        suspendedPreflight?.resume()
        suspendedPreflight = nil
    }
}

@MainActor
private final class ManualOAuthFixtureChecker: SubscriptionChecking {
    var activeSession: BrowserSession?
    private(set) var checks = 0

    func check(account: AccountRecord) async -> SubscriptionCheckOutcome {
        checks += 1
        return .failure("Unexpected check during authorization")
    }
}

@MainActor
@Suite(.serialized)
struct ManualOAuthSessionTests {
    private let authorizationURL = "https://auth.openai.com/oauth/authorize?client_id=fixture&redirect_uri=http%3A%2F%2Flocalhost%3A1455%2Fauth%2Fcallback&state=a%2Bb%26c&prompt=none"

    private func store() throws -> AccountStore {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("accounts.json")
        let store = AccountStore(fileURL: file)
        try store.merge([
            .init(email: "first@example.com", password: "fixture-password", totpSecret: "JBSWY3DPEHPK3PXP"),
            .init(email: "second@example.com", password: "fixture-password", totpSecret: "JBSWY3DPEHPK3PXP"),
        ])
        return store
    }

    private func waitForPreflight(_ sessions: ManualOAuthFixtureSessions) async throws {
        for _ in 0..<100 where sessions.suspendedPreflight == nil { await Task.yield() }
        _ = try #require(sessions.suspendedPreflight)
    }

    @Test func waitsForPreflightAndKeepsExactAuthorizationURL() async throws {
        let store = try store()
        let account = store.accounts[0]
        store.selectedID = store.accounts[1].id
        let sessions = ManualOAuthFixtureSessions()
        sessions.holdPreflight = true
        let checker = ManualOAuthFixtureChecker()
        let coordinator = OperationCoordinator(store: store, checker: checker, accountSessions: sessions)
        let opening = Task { await coordinator.openOAuthURL(for: account.id, text: authorizationURL, mode: .copyLink) }
        try await waitForPreflight(sessions)

        #expect(coordinator.isRunning)
        #expect(coordinator.protectedAccountIDs.contains(account.id))
        #expect(sessions.requestedURLs(for: account).isEmpty)
        #expect(store.selectedID == store.accounts[1].id)
        #expect(await coordinator.openOAuthURL(for: account.id, text: authorizationURL) != nil)
        await coordinator.check(id: account.id)
        #expect(checker.checks == 0)
        sessions.finishPreflight()

        #expect(await opening.value == nil)
        #expect(sessions.preflightAccountIDs == [account.id])
        #expect(sessions.requestedURLs(for: account).map(\.absoluteString) == [authorizationURL])
        #expect(store.selectedID == account.id)
        #expect(!coordinator.isRunning)
        #expect(!coordinator.protectedAccountIDs.contains(account.id))
        #expect(coordinator.browserSession(for: account.id) === sessions.accountSession(for: account))
        sessions.accountSession(for: account).cancelLoading()
    }

    @Test(arguments: [false, true])
    func cancelledPreflightCannotOpenAuthorizationURL(cancelTask: Bool) async throws {
        let store = try store()
        let account = store.accounts[0]
        let sessions = ManualOAuthFixtureSessions()
        sessions.holdPreflight = true
        let coordinator = OperationCoordinator(store: store, checker: ManualOAuthFixtureChecker(), accountSessions: sessions)
        let opening = Task { await coordinator.openOAuthURL(for: account.id, text: authorizationURL) }
        try await waitForPreflight(sessions)
        if cancelTask { opening.cancel() } else { coordinator.stop() }
        sessions.finishPreflight()

        #expect(await opening.value != nil)
        #expect(sessions.requestedURLs(for: account).isEmpty)
        #expect(!coordinator.isRunning)
        #expect(!coordinator.protectedAccountIDs.contains(account.id))
    }

    @Test func changedCredentialsCannotUseCompletedPreflight() async throws {
        let store = try store()
        let account = store.accounts[0]
        let sessions = ManualOAuthFixtureSessions()
        sessions.holdPreflight = true
        let coordinator = OperationCoordinator(store: store, checker: ManualOAuthFixtureChecker(), accountSessions: sessions)
        let opening = Task { await coordinator.openOAuthURL(for: account.id, text: authorizationURL) }
        try await waitForPreflight(sessions)
        try store.mutate(id: account.id) { $0.password = "changed-fixture-password" }
        sessions.finishPreflight()

        #expect(await opening.value != nil)
        #expect(sessions.requestedURLs(for: account).isEmpty)
        #expect(!coordinator.isRunning)
    }

    @Test func mismatchedSessionDoesNotOpenAuthorizationURL() async throws {
        let store = try store()
        let account = store.accounts[0]
        store.selectedID = store.accounts[1].id
        let sessions = ManualOAuthFixtureSessions()
        sessions.preflightError = .wrongAccount
        let coordinator = OperationCoordinator(store: store, checker: ManualOAuthFixtureChecker(), accountSessions: sessions)

        #expect(await coordinator.openOAuthURL(for: account.id, text: authorizationURL) == ChatGPTAutomation.SavedSessionError.wrongAccount.localizedDescription)
        #expect(sessions.requestedURLs(for: account).isEmpty)
        #expect(store.selectedID == store.accounts[1].id)
        #expect(!coordinator.isRunning)
    }
}
