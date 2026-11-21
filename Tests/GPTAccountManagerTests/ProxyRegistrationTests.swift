import AppKit
import Foundation
import Testing
import WebKit
@testable import GPTAccountManager

@MainActor
private final class ProxyRegistrationFixture: WKWebView {
    override func load(_ request: URLRequest) -> WKNavigation? {
        super.loadHTMLString("""
        <h1>Verify you are human</h1>
        <script>window.fetch=async()=>({ok:true,json:async()=>({})});</script>
        """, baseURL: request.url)
    }
}

@MainActor
@Suite(.serialized)
struct ProxyRegistrationTests {
    private func setup(available: Bool) throws -> (AccountStore, ProxyStore, RegistrationCoordinator, BrowserSession) {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let accounts = AccountStore(fileURL: directory.appendingPathComponent("accounts.json"))
        let proxies = ProxyStore(fileURL: directory.appendingPathComponent("proxies.json"), checker: { _ in
            .init(status: available ? .available : .unavailable, latencyMilliseconds: available ? 12 : nil,
                  exitIP: available ? "203.0.113.5" : nil, checkedAt: Date(), message: "fixture")
        })
        try proxies.add(text: "socks5://127.0.0.1:18081")
        try proxies.setEnabled(true)
        let session = BrowserSession(dataStore: .nonPersistent()) { configuration in
            ProxyRegistrationFixture(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        }
        let browser = ChatGPTAutomation(sessionManager: WebSessionManager(accountSessionFactory: { _ in session }))
        let coordinator = RegistrationCoordinator(store: accounts, browser: browser, mailbox: MailRuMailbox(),
                                                   proxyStore: proxies, configuredPassword: "registration-fixture-password")
        return (accounts, proxies, coordinator, session)
    }

    @Test func randomCheckedProxyIsSavedBeforeFirstAccountPageAndPreservedOnResume() async throws {
        let (accounts, proxies, coordinator, session) = try setup(available: true)
        defer { coordinator.stop(); try? FileManager.default.removeItem(at: accounts.fileURL.deletingLastPathComponent()) }
        try coordinator.start(email: "proxy-new@example.com")
        for _ in 0..<100 where accounts.accounts.isEmpty { try await Task.sleep(for: .milliseconds(50)) }
        let draft = try #require(accounts.accounts.first)
        #expect(draft.proxy == proxies.proxies.first?.proxy)
        #expect(session.configuredProxy == draft.proxy)
        #expect(session.webView.configuration.websiteDataStore.proxyConfigurations.count == 1)
        coordinator.stop()
        for _ in 0..<100 where coordinator.isRunning { try await Task.sleep(for: .milliseconds(50)) }
        try #require(!coordinator.isRunning)
        coordinator.resume(id: draft.id)
        coordinator.stop()
        for _ in 0..<100 where coordinator.isRunning { try await Task.sleep(for: .milliseconds(50)) }
        #expect(accounts.accounts.count == 1)
        #expect(accounts.accounts.first?.proxy == draft.proxy)
        #expect(accounts.accounts.first?.browserStoreID == draft.browserStoreID)
    }

    @Test func noReachableProxyDoesNotCreateAccountOrLoadDirectly() async throws {
        let (accounts, _, coordinator, session) = try setup(available: false)
        defer { coordinator.stop(); try? FileManager.default.removeItem(at: accounts.fileURL.deletingLastPathComponent()) }
        try coordinator.start(email: "proxy-new@example.com")
        for _ in 0..<100 where coordinator.isRunning { try await Task.sleep(for: .milliseconds(50)) }
        #expect(!coordinator.isRunning)
        #expect(accounts.accounts.isEmpty)
        #expect(session.webView.url == nil)
        #expect(coordinator.activeSession == nil)
        #expect(coordinator.message.contains("Рабочий прокси не найден"))
    }

    @Test func resumeReplacesDeadAssignmentWithoutChangingRegistrationOrCookiesStore() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let accounts = AccountStore(fileURL: directory.appendingPathComponent("accounts.json"))
        let old = AccountProxy(scheme: .socks5, host: "127.0.0.1", port: 18081)
        let replacement = AccountProxy(scheme: .socks5, host: "127.0.0.1", port: 18082)
        let proxies = ProxyStore(fileURL: directory.appendingPathComponent("proxies.json"), checker: { proxy in
            .init(status: proxy.port == 18082 ? .available : .unavailable,
                  checkedAt: Date(), message: "fixture")
        })
        try proxies.add(text: "\(old.urlString)\n\(replacement.urlString)")
        try proxies.setEnabled(true)
        let original = try accounts.beginRegistration(email: "resume@example.com", fullName: "Fixture Person", age: 26,
                                                      password: "fixture", proxy: old)
        let session = BrowserSession(dataStore: .nonPersistent()) { configuration in
            ProxyRegistrationFixture(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        }
        let browser = ChatGPTAutomation(sessionManager: WebSessionManager(accountSessionFactory: { _ in session }))
        let coordinator = RegistrationCoordinator(store: accounts, browser: browser, mailbox: MailRuMailbox(), proxyStore: proxies)
        defer { coordinator.stop(); try? FileManager.default.removeItem(at: directory) }
        coordinator.resume(id: original.id)
        for _ in 0..<100 where accounts.accounts.first?.proxy != replacement { try await Task.sleep(for: .milliseconds(50)) }
        let updated = try #require(accounts.accounts.first)
        #expect(updated.proxy == replacement)
        #expect(updated.browserStoreID == original.browserStoreID)
        #expect(updated.pendingRegistration == original.pendingRegistration)
        #expect(updated.password == original.password && updated.id == original.id)
        #expect(session.configuredProxy == replacement)
        coordinator.stop()
        for _ in 0..<100 where coordinator.isRunning { try await Task.sleep(for: .milliseconds(50)) }
        #expect(!coordinator.isRunning)
    }
}
