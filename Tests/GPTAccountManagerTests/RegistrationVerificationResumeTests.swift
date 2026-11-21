import AppKit
import Foundation
import Testing
import WebKit
@testable import GPTAccountManager

@MainActor
private final class RegistrationBaselineWebView: WKWebView {
    override func load(_ request: URLRequest) -> WKNavigation? {
        super.loadHTMLString("""
        <title>Входящие - owner@mail.ru - Почта Mail.ru</title><span>owner@mail.ru</span>
        <a href="https://auth.mail.ru/cgi-bin/logout">Выйти</a>
        <table><tr class="messageline" id="msglist-1000"><td class="messageline__subject">
        <a class="messageline__link" href="/message/1000/?folder=0">Old fixture message</a>
        </td></tr></table>
        """, baseURL: request.url)
    }

    override func reload() -> WKNavigation? {
        load(URLRequest(url: url ?? URL(string: "https://e.mail.ru/inbox/")!))
    }
}

@MainActor
private final class RegistrationVerificationCreationCount {
    var value = 0
}

@MainActor
@Suite(.serialized)
struct RegistrationVerificationResumeTests {
    private let email = "new@icloud.com"
    private let secret = "JBSWY3DPEHPK3PXP"
    private let token = "fixture.current.session.token"

    private func mailbox() -> MailRuMailbox {
        MailRuMailbox(expectedMailbox: "owner@mail.ru") { configuration in
            configuration.websiteDataStore = .nonPersistent()
            return RegistrationBaselineWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        }
    }

    private func session(html: String, url: String = "https://chatgpt.com/settings/security") async throws -> BrowserSession {
        _ = NSApplication.shared
        let session = BrowserSession(dataStore: .nonPersistent())
        session.webView.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        session.webView.navigationDelegate = nil
        session.webView.loadHTMLString(html, baseURL: URL(string: url))
        for _ in 0..<100 where session.webView.isLoading { try await Task.sleep(for: .milliseconds(30)) }
        try #require(!session.webView.isLoading && !session.needsInitialPageLoad)
        return session
    }

    private func securityPage(email: String? = nil, token: String? = "fixture.current.session.token",
                              enabled: Bool = true, extra: String = "") throws -> String {
        let emailJSON = String(decoding: try JSONEncoder().encode(email ?? self.email), as: UTF8.self)
        let tokenJSON = String(decoding: try JSONEncoder().encode(token), as: UTF8.self)
        return """
        <script>
        window.fixtureMarker='persistent session retained';window.factorClicks=0;
        window.fixtureToken=\(tokenJSON);
        window.fetch=async()=>({ok:true,json:async()=>({user:{email:\(emailJSON),id:'fixture-user'},accessToken:window.fixtureToken})});
        </script>
        <button role="switch" aria-label="Authenticator app" aria-checked="\(enabled)"
          onclick="window.factorClicks++">Authenticator app</button>\(extra)
        """
    }

    private func storeWithDraft(phase: RegistrationPhase = .verifyingLogin) throws -> (AccountStore, AccountRecord) {
        let store = AccountStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathComponent("accounts.json"))
        let original = try store.beginRegistration(email: email, fullName: "Fixture Person", age: 29, password: "fixture-password")
        var pending = try #require(original.pendingRegistration)
        pending.passwordWasSubmitted = true
        pending.phase = phase
        pending.pendingSecret = secret
        try store.checkpointRegistration(id: original.id, registration: pending)
        return (store, try #require(store.accounts.first))
    }

    private func browser(persistent: BrowserSession, creations: RegistrationVerificationCreationCount) -> ChatGPTAutomation {
        ChatGPTAutomation(sessionManager: WebSessionManager(accountSessionFactory: { _ in persistent },
            verificationSessionFactory: {
                creations.value += 1
                return BrowserSession(dataStore: .nonPersistent())
            }))
    }

    private func waitUntilPaused(_ coordinator: RegistrationCoordinator) async throws {
        for _ in 0..<200 where coordinator.isRunning { try await Task.sleep(for: .milliseconds(30)) }
        try #require(!coordinator.isRunning)
    }

    @Test(arguments: [RegistrationPhase.enablingTwoFA, .verifyingLogin])
    func completedSetupSavesCurrentSessionWithoutAnotherLogin(phase: RegistrationPhase) async throws {
        let persistent = try await session(html: securityPage())
        let (store, draft) = try storeWithDraft(phase: phase)
        let creations = RegistrationVerificationCreationCount()
        let browser = browser(persistent: persistent, creations: creations)
        let coordinator = RegistrationCoordinator(store: store, browser: browser, mailbox: mailbox())
        defer {
            coordinator.stop(); persistent.cancelLoading()
            try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent())
        }
        coordinator.resume(id: draft.id)
        try await waitUntilPaused(coordinator)
        let saved = try #require(store.accounts.first)
        #expect(saved.pendingRegistration == nil && saved.status == .ready)
        #expect(saved.id == draft.id && saved.browserStoreID == draft.browserStoreID)
        #expect(saved.password == draft.password && saved.totpSecret == secret && saved.accessToken == token)
        #expect(saved.groupID == store.groups.first(where: { $0.name == "new-novoreg" })?.id)
        #expect(coordinator.completedCount == 1 && !coordinator.hasPendingBatch)
        #expect(creations.value == 0 && coordinator.activeSession === persistent)
        #expect(browser.accountSession(for: saved) === persistent)
        #expect(try await persistent.evaluate("window.factorClicks") as? Int == 0)
        #expect(try await persistent.evaluate("window.fixtureMarker") as? String == "persistent session retained")
        let tokenFile = store.fileURL.deletingLastPathComponent().appendingPathComponent("new-novoreg-access-tokens.txt")
        #expect(try String(contentsOf: tokenFile, encoding: .utf8) == "\(email)|\(token)\n")
    }

    @Test(arguments: ["disabled", "setup", "backup", "wrongIdentity", "missingToken"])
    func incompleteCurrentSessionRemainsDraftWithoutFreshLogin(reason: String) async throws {
        let extra: String
        switch reason {
        case "setup": extra = "<div role='dialog'><h2>Connect your authenticator app</h2><input name='code' autocomplete='one-time-code'><button>Continue</button></div>"
        case "backup": extra = "<div role='dialog'><h2>Authenticator app added</h2><p>Add SMS as a backup method</p><button onclick='window.factorClicks++'>Not now</button></div>"
        default: extra = ""
        }
        let persistent = try await session(html: securityPage(email: reason == "wrongIdentity" ? "other@icloud.com" : email,
            token: reason == "missingToken" ? nil : token, enabled: reason != "disabled", extra: extra))
        let (store, draft) = try storeWithDraft()
        let creations = RegistrationVerificationCreationCount()
        let browser = browser(persistent: persistent, creations: creations)
        let coordinator = RegistrationCoordinator(store: store, browser: browser, mailbox: mailbox())
        defer {
            coordinator.stop(); persistent.cancelLoading()
            try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent())
        }
        coordinator.resume(id: draft.id)
        try await waitUntilPaused(coordinator)
        let saved = try #require(store.accounts.first)
        #expect(saved.pendingRegistration == draft.pendingRegistration && saved.status != .ready)
        #expect(saved.accessToken == nil && saved.totpSecret.isEmpty && store.groups.isEmpty)
        #expect(saved.browserStoreID == draft.browserStoreID && saved.password == draft.password)
        #expect(creations.value == 0 && coordinator.activeSession === persistent)
        #expect(coordinator.completedCount == 0)
        #expect(try await persistent.evaluate("window.factorClicks") as? Int == 0)
    }

    @Test func tokenFailureResumesInSameSessionWithoutReenrollment() async throws {
        let persistent = try await session(html: securityPage(token: nil))
        let (store, draft) = try storeWithDraft()
        let creations = RegistrationVerificationCreationCount()
        let coordinator = RegistrationCoordinator(store: store, browser: browser(persistent: persistent, creations: creations), mailbox: mailbox())
        defer {
            coordinator.stop(); persistent.cancelLoading()
            try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent())
        }
        coordinator.resume(id: draft.id)
        try await waitUntilPaused(coordinator)
        #expect(store.accounts.first?.pendingRegistration == draft.pendingRegistration && store.groups.isEmpty)
        let tokenJSON = String(decoding: try JSONEncoder().encode(token), as: UTF8.self)
        _ = try await persistent.evaluate("(() => { window.fixtureToken=\(tokenJSON); return true; })()")
        coordinator.resume(id: draft.id)
        try await waitUntilPaused(coordinator)
        #expect(store.accounts.first?.status == .ready && store.accounts.first?.accessToken == token)
        #expect(store.accounts.first?.pendingRegistration == nil)
        #expect(creations.value == 0 && coordinator.activeSession === persistent)
        #expect(try await persistent.evaluate("window.factorClicks") as? Int == 0)
        #expect(try await persistent.evaluate("window.fixtureMarker") as? String == "persistent session retained")
    }

    @Test func expiredSessionRecoversInPersistentBrowserWithoutVerificationFactory() async throws {
        let persistent = try await session(html: """
        <script>window.passwordSubmissions=0;window.fetch=async()=>({ok:true,json:async()=>({})});</script>
        <form onsubmit="event.preventDefault();window.passwordSubmissions++;document.body.innerHTML='<h1>Verify you are human</h1>'">
        <input type="password"><button>Continue</button></form>
        """, url: "https://auth.openai.com/log-in/password")
        let (store, draft) = try storeWithDraft()
        let creations = RegistrationVerificationCreationCount()
        let coordinator = RegistrationCoordinator(store: store, browser: browser(persistent: persistent, creations: creations), mailbox: mailbox())
        defer {
            coordinator.stop(); persistent.cancelLoading()
            try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent())
        }
        coordinator.resume(id: draft.id)
        for _ in 0..<200 {
            if (try? await persistent.evaluate("window.passwordSubmissions")) as? Int == 1 { break }
            try await Task.sleep(for: .milliseconds(30))
        }
        #expect(try await persistent.evaluate("window.passwordSubmissions") as? Int == 1)
        #expect(creations.value == 0 && coordinator.activeSession === persistent)
        #expect(store.accounts.first?.pendingRegistration != nil && store.groups.isEmpty)
        coordinator.stop()
        try await waitUntilPaused(coordinator)
    }

    @Test func deactivatedPersistentAccountRemainsBlockedDraft() async throws {
        let persistent = try await session(html: """
        <h1>Authentication error</h1><p>Your account has been deleted or deactivated.</p>
        <p>error_code: account_deactivated</p>
        """, url: "https://auth.openai.com/mfa-challenge/fixture")
        let (store, draft) = try storeWithDraft()
        let creations = RegistrationVerificationCreationCount()
        let coordinator = RegistrationCoordinator(store: store, browser: browser(persistent: persistent, creations: creations), mailbox: mailbox())
        defer {
            coordinator.stop(); persistent.cancelLoading()
            try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent())
        }
        coordinator.resume(id: draft.id)
        try await waitUntilPaused(coordinator)
        let saved = try #require(store.accounts.first)
        #expect(coordinator.blockedCount == 1 && coordinator.completedCount == 0)
        #expect(saved.pendingRegistration == draft.pendingRegistration && saved.status != .ready)
        #expect(saved.lastError == RegistrationCoordinator.deactivatedAccountMessage)
        #expect(saved.browserStoreID == draft.browserStoreID && saved.totpSecret.isEmpty && store.groups.isEmpty)
        #expect(!coordinator.hasPendingBatch && coordinator.accountID == nil && creations.value == 0)
    }
}
