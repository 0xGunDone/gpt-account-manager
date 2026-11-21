import AppKit
import Foundation
import SwiftUI
import Testing
import WebKit
@testable import GPTAccountManager

/// Replaces only network delivery so timeouts can be reproduced without a live account.
@MainActor
private final class LoadingWebView: WKWebView {
    enum Response {
        case failure(URLError.Code)
        case success
        case stall
        case committed
    }
    var responses: [Response] = []
    var requests: [URLRequest] = []
    var stoppedLoads = 0
    private var loadedURL: URL?
    private lazy var navigationSource = WKWebView()
    override var url: URL? { loadedURL }

    override func load(_ request: URLRequest) -> WKNavigation? {
        requests.append(request)
        // WebKit exposes the requested URL even before the first document commits.
        loadedURL = request.url
        // WKNavigation has a public NSObject initializer, but WebKit requires
        // its internal navigation object even during deallocation.
        guard let navigation = navigationSource.loadHTMLString("<p>Fixture</p>", baseURL: nil)
        else { return nil }
        let response = responses.isEmpty ? .stall : responses.removeFirst()
        Task { @MainActor in
            self.navigationDelegate?.webView?(self, didStartProvisionalNavigation: navigation)
            switch response {
            case .failure(let code):
                self.navigationDelegate?.webView?(self, didFailProvisionalNavigation: navigation,
                                                  withError: URLError(code))
            case .success, .committed:
                self.loadedURL = request.url
                self.navigationDelegate?.webView?(self, didCommit: navigation)
                if case .success = response {
                    self.navigationDelegate?.webView?(self, didFinish: navigation)
                }
            case .stall:
                break
            }
        }
        return navigation
    }

    override func stopLoading() { stoppedLoads += 1 }
}

@MainActor
@Suite(.serialized)
struct BrowserLoadingTests {
    @Test func stalledEphemeralConnectionIsReplacedWithoutLosingCookiesOrBrowserMount() async throws {
        _ = NSApplication.shared
        var views: [LoadingWebView] = []
        let proxy = AccountProxy(scheme: .http, host: "127.0.0.1", port: 18080)
        let session = BrowserSession(dataStore: .nonPersistent(), proxy: proxy) { configuration in
            #expect(configuration.websiteDataStore.proxyConfigurations.count == 1)
            let view = LoadingWebView(frame: .zero, configuration: configuration)
            // Retrying the original connection never succeeds.
            view.responses = views.isEmpty ? [.stall, .stall] : [.success]
            views.append(view)
            return view
        }
        let original = session.webView
        let cookie = try #require(HTTPCookie(properties: [
            .domain: "chatgpt.com", .path: "/", .name: "fixture", .value: "retained",
        ]))
        await original.configuration.websiteDataStore.httpCookieStore.setCookie(cookie)
        let host = NSHostingView(rootView: BrowserView(session: session))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 500),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        host.layoutSubtreeIfNeeded()

        #expect(await session.loadInitialPage(URL(string: "https://chatgpt.com/")!, seconds: 1))
        try #require(views.count == 2)
        #expect(views.allSatisfy { $0.requests.count == 1 })
        #expect(session.webView !== original)
        #expect(session.webView.configuration.websiteDataStore !== original.configuration.websiteDataStore)
        #expect(!session.webView.configuration.websiteDataStore.isPersistent)
        #expect(session.configuredProxy == proxy)
        #expect(session.webView.configuration.websiteDataStore.proxyConfigurations.count == 1)
        #expect(session.webView.configuration.websiteDataStore.proxyConfigurations.allSatisfy { !$0.allowFailover })
        #expect(await session.webView.configuration.websiteDataStore.httpCookieStore.allCookies()
            .contains { $0.name == "fixture" && $0.value == "retained" })
        #expect(await session.waitUntilAttached(seconds: 1))
        #expect(session.webView.window === window)
        #expect(original.superview == nil)

        // Already queued callbacks from the retired WebView must be ignored.
        _ = original.load(URLRequest(url: URL(string: "https://auth.openai.com/stale")!))
        session.webView(original, didCommit: nil)
        session.webView(original, didFinish: nil)
        #expect(session.currentURL?.absoluteString == "https://chatgpt.com/")
    }

    @Test func ephemeralConnectionRecoveryIsBounded() async {
        var views: [LoadingWebView] = []
        let session = BrowserSession(dataStore: .nonPersistent()) { configuration in
            let view = LoadingWebView(frame: .zero, configuration: configuration)
            view.responses = [.failure(.timedOut), .failure(.timedOut)]
            views.append(view)
            return view
        }
        #expect(!(await session.loadInitialPage(URL(string: "https://chatgpt.com/")!, seconds: 1)))
        #expect(views.count == 2)
        #expect(views.reduce(0) { $0 + $1.requests.count } == 2)
        #expect(session.pageLoadMessage?.contains("-1001") == true)
    }

    @Test func committedEphemeralPageAndTLSFailureDoNotReplaceTheBrowser() async {
        for response: LoadingWebView.Response in [.committed, .failure(.serverCertificateUntrusted)] {
            var created = 0
            let session = BrowserSession(dataStore: .nonPersistent()) { configuration in
                created += 1
                let view = LoadingWebView(frame: .zero, configuration: configuration)
                view.responses = [response]
                return view
            }
            _ = await session.loadInitialPage(URL(string: "https://chatgpt.com/")!, seconds: 1)
            #expect(created == 1)
        }
    }

    @Test func cancellingEphemeralLoadDoesNotRecreateTheBrowser() async throws {
        var created = 0
        let session = BrowserSession(dataStore: .nonPersistent()) { configuration in
            created += 1
            return LoadingWebView(frame: .zero, configuration: configuration)
        }
        let task = Task { await session.loadInitialPage(URL(string: "https://chatgpt.com/")!, seconds: 1) }
        try await Task.sleep(for: .milliseconds(30))
        session.cancelLoading()
        #expect(!(await task.value))
        #expect(created == 1)
    }

    @Test func rebuildingCleanLoginBrowserDoesNotConfirmOrReplaceThePendingFactor() async {
        var views: [LoadingWebView] = []
        let session = BrowserSession(dataStore: .nonPersistent()) { configuration in
            let view = LoadingWebView(frame: .zero, configuration: configuration)
            view.responses = [.failure(.timedOut)]
            views.append(view)
            return view
        }
        let rotation = BrowserSession(dataStore: .nonPersistent())
        var created = 0
        let automation = ChatGPTAutomation(sessionManager: WebSessionManager(verificationSessionFactory: {
            created += 1
            return created == 1 ? rotation : session
        }))
        var account = AccountRecord(credential: .init(
            email: "fixture@example.com", password: "fixture", totpSecret: "JBSWY3DPEHPK3PXP"))
        account.rotationStage = .awaitingCleanLogin
        account.pendingTOTPSecret = "KRUGS4ZANFZSAYJA"
        var checkpoints: [RotationCheckpointEvent] = []

        let outcome = await automation.rotate2FA(account: account) { checkpoints.append($0) }

        guard case .manualActionRequired(stage: .awaitingCleanLogin, _) = outcome else {
            Issue.record("A rebuilt browser must still require proof of the pending factor")
            return
        }
        #expect(views.count == 3)
        #expect(checkpoints.isEmpty)
        #expect(automation.cleanLoginSession(for: account) === session)
        #expect(account.pendingTOTPSecret == "KRUGS4ZANFZSAYJA")
        #expect(account.totpSecret == "JBSWY3DPEHPK3PXP")
    }

    @Test func reloadCanRecoverBeforeTheFirstPageCommits() async throws {
        _ = NSApplication.shared
        let session = BrowserSession(dataStore: .nonPersistent())
        let navigation = try #require(session.load(URL(string: "https://chatgpt.com/")!))
        session.cancelLoading()
        session.webView(session.webView, didFailProvisionalNavigation: navigation,
                        withError: URLError(.timedOut))

        #expect(session.webView.backForwardList.currentItem == nil)
        #expect(session.reloadTrustedPage() != nil)
        session.cancelLoading()
    }

    @Test func initialNetworkTimeoutIsRetriedInTheSameCookieStore() async throws {
        let (session, webView) = fixture([.failure(.timedOut), .success])
        let cookie = try #require(HTTPCookie(properties: [
            .domain: "chatgpt.com", .path: "/", .name: "fixture", .value: "kept",
        ]))
        await webView.configuration.websiteDataStore.httpCookieStore.setCookie(cookie)

        #expect(await session.loadInitialPage(URL(string: "https://chatgpt.com/")!, seconds: 1))
        #expect(webView.requests.count == 2)
        #expect(webView.requests.allSatisfy { $0.url?.absoluteString == "https://chatgpt.com/" })
        #expect(await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
            .contains { $0.name == "fixture" && $0.value == "kept" })
    }

    @Test func stalledInitialRequestIsStoppedAndRetried() async {
        let (session, webView) = fixture([.stall, .success])
        #expect(await session.loadInitialPage(URL(string: "https://chatgpt.com/")!, seconds: 1))
        #expect(webView.requests.count == 2)
        #expect(webView.stoppedLoads > 0)
    }

    @Test func committedLoginPageDoesNotGetRestartedForSlowSubresources() async {
        let (session, webView) = fixture([.committed])
        let start = ContinuousClock.now
        #expect(await session.loadInitialPage(URL(string: "https://chatgpt.com/")!, seconds: 1))
        #expect(ContinuousClock.now - start < .milliseconds(700))
        #expect(webView.requests.count == 1)
    }

    @Test func cleanLoginCanRecoverTwoUnresponsiveConnectionsBeforeItRequestsManualHelp() async {
        var views: [LoadingWebView] = []
        let session = BrowserSession(dataStore: .nonPersistent()) { configuration in
            let view = LoadingWebView(frame: .zero, configuration: configuration)
            view.responses = views.count < 2 ? [.failure(.timedOut)] : [.success]
            views.append(view)
            return view
        }

        #expect(await session.loadInitialPage(URL(string: "https://chatgpt.com/")!, seconds: 1, attempts: 3))
        #expect(views.count == 3)
        #expect(views.allSatisfy { $0.requests.count == 1 })
    }

    @Test func repeatedNetworkFailuresHaveABoundedRetry() async {
        let (session, webView) = fixture([.failure(.timedOut), .failure(.timedOut), .success])
        #expect(!(await session.loadInitialPage(URL(string: "https://chatgpt.com/")!, seconds: 1)))
        #expect(webView.requests.count == 2)
    }

    @Test func cancellingInitialLoadDoesNotStartAnotherRequest() async throws {
        let (session, webView) = fixture([.stall, .success])
        let task = Task { await session.loadInitialPage(URL(string: "https://chatgpt.com/")!, seconds: 2) }
        try await Task.sleep(for: .milliseconds(30))
        session.cancelLoading()
        #expect(!(await task.value))
        #expect(webView.requests.count == 1)
    }

    @Test func permanentTLSFailureIsNotRetried() async {
        let (session, webView) = fixture([.failure(.serverCertificateUntrusted), .success])
        #expect(!(await session.loadInitialPage(URL(string: "https://chatgpt.com/")!, seconds: 1)))
        #expect(webView.requests.count == 1)
    }

    @Test func aNewNavigationDuringRetryDelayIsNotOverwritten() async throws {
        let (session, webView) = fixture([.failure(.timedOut), .stall, .success])
        let task = Task { await session.loadInitialPage(URL(string: "https://chatgpt.com/")!, seconds: 1) }
        try await Task.sleep(for: .milliseconds(200))
        _ = session.load(URL(string: "https://auth.openai.com/log-in")!)
        #expect(!(await task.value))
        #expect(webView.requests.count == 2)
        #expect(webView.requests.last?.url?.path == "/log-in")
    }

    @Test func exhaustedCleanLoginCanContinueWithoutChangingThePendingFactor() async throws {
        let (session, webView) = fixture(Array(repeating: .failure(.timedOut), count: 6))
        let rotation = BrowserSession(dataStore: .nonPersistent())
        var factoryCalls = 0
        let automation = ChatGPTAutomation(sessionManager: WebSessionManager(verificationSessionFactory: {
            factoryCalls += 1
            return factoryCalls == 1 ? rotation : session
        }))
        var account = AccountRecord(credential: .init(
            email: "fixture@example.com", password: "fixture", totpSecret: "JBSWY3DPEHPK3PXP"))
        account.rotationStage = .awaitingCleanLogin
        account.pendingTOTPSecret = "KRUGS4ZANFZSAYJA"
        var checkpoints: [RotationCheckpointEvent] = []

        for _ in 0..<2 {
            let outcome = await automation.rotate2FA(account: account) { checkpoints.append($0) }
            guard case .manualActionRequired(stage: .awaitingCleanLogin, let message) = outcome else {
                Issue.record("Unreachable page must keep the pending factor unverified")
                return
            }
            #expect(message.contains("-1001"))
        }
        #expect(checkpoints.isEmpty)
        #expect(webView.requests.count == 6)
        #expect(factoryCalls == 2)
        #expect(automation.cleanLoginSession(for: account) === session)
        #expect(account.pendingTOTPSecret == "KRUGS4ZANFZSAYJA")
        #expect(account.totpSecret == "JBSWY3DPEHPK3PXP")
    }

    @Test func reloadRetriesTheOriginalURLWhenWebKitHasNoDocument() async {
        let (session, webView) = fixture([.failure(.timedOut), .failure(.timedOut), .success])
        #expect(!(await session.loadInitialPage(URL(string: "https://chatgpt.com/")!, seconds: 1)))
        #expect(session.canReloadTrustedPage)
        let navigation = session.reloadTrustedPage()
        #expect(await session.waitForNavigation(navigation, seconds: 1))
        #expect(webView.requests.count == 3)
        #expect(session.pageLoadMessage == nil)
    }

    @Test func subscriptionCheckAndContinueRetryABlankPageWithoutResettingTheAccountSession() async throws {
        let (session, webView) = fixture(Array(repeating: .failure(.timedOut), count: 4))
        let manager = WebSessionManager(accountSessionFactory: { _ in session })
        let automation = ChatGPTAutomation(sessionManager: manager)
        let account = AccountRecord(credential: .init(
            email: "fixture@example.com", password: "fixture", totpSecret: "JBSWY3DPEHPK3PXP"))
        let cookie = try #require(HTTPCookie(properties: [
            .domain: "chatgpt.com", .path: "/", .name: "fixture", .value: "retained",
        ]))
        await webView.configuration.websiteDataStore.httpCookieStore.setCookie(cookie)

        for resuming in [false, true] {
            let deadline = Task { @MainActor in
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                automation.cancelActiveOperation()
            }
            let outcome = resuming
                ? await automation.continueCheck(account: account)
                : await automation.check(account: account)
            deadline.cancel()
            guard case .manualActionRequired(let message) = outcome else {
                Issue.record("Network failure must offer recovery rather than try to log in on an empty document")
                continue
            }
            #expect(message.contains("-1001"))
            #expect(webView.requests.count == (resuming ? 4 : 2))
        }
        #expect(manager.existingSession(for: account) === session)
        #expect(await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
            .contains { $0.name == "fixture" && $0.value == "retained" })
    }

    private func fixture(_ responses: [LoadingWebView.Response]) -> (BrowserSession, LoadingWebView) {
        var webView: LoadingWebView!
        // Persistent account profiles must keep their store and browser on retry.
        let session = BrowserSession(dataStore: WKWebsiteDataStore(forIdentifier: UUID())) { configuration in
            webView = LoadingWebView(frame: .zero, configuration: configuration)
            webView.responses = responses
            return webView
        }
        return (session, webView)
    }
}
