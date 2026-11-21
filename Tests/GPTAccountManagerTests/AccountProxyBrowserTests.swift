import AppKit
import Foundation
import Testing
import WebKit
@testable import GPTAccountManager

@MainActor
private final class ProxyToggle {
    var enabled = true
}

@MainActor
@Suite(.serialized)
struct AccountProxyBrowserTests {
    private let proxy = AccountProxy(scheme: .http, host: "127.0.0.1", port: 18080)

    private func account() -> AccountRecord {
        var account = AccountRecord(credential: .init(
            email: "proxy-fixture@example.com", password: "fixture", totpSecret: "JBSWY3DPEHPK3PXP"))
        account.proxy = proxy
        return account
    }

    @Test(arguments: ProxyScheme.allCases)
    func nativeProxyNeverFallsBackOrExcludesDestinations(scheme: ProxyScheme) {
        let native = AccountProxy(scheme: scheme, host: "127.0.0.1", port: 18080).nativeConfiguration()
        #expect(!native.allowFailover)
        #expect(native.matchDomains.isEmpty)
        #expect(native.excludedDomains.isEmpty)
    }

    @Test func proxyIsAppliedBeforeWebViewConstructionAndDirectModeClearsIt() {
        _ = NSApplication.shared
        let store = WKWebsiteDataStore.nonPersistent()
        var configuredBeforeCreation = false
        let session = BrowserSession(dataStore: store, proxy: proxy) { configuration in
            configuredBeforeCreation = configuration.websiteDataStore.proxyConfigurations.count == 1
            return WKWebView(frame: .zero, configuration: configuration)
        }
        #expect(configuredBeforeCreation)
        #expect(session.configuredProxy == proxy)
        let direct = BrowserSession(dataStore: store)
        #expect(direct.configuredProxy == nil)
        #expect(direct.webView.configuration.websiteDataStore.proxyConfigurations.isEmpty)
    }

    @Test func changingResolvedProxyRebuildsBrowserWithoutClearingAccountCookies() async throws {
        let toggle = ProxyToggle()
        let manager = WebSessionManager(proxyResolver: { toggle.enabled ? $0.proxy : nil })
        var account = account()
        let original = manager.session(for: account)
        let cookie = try #require(HTTPCookie(properties: [
            .domain: "chatgpt.com", .path: "/", .name: "proxy_fixture", .value: "retained",
        ]))
        await original.webView.configuration.websiteDataStore.httpCookieStore.setCookie(cookie)
        defer { original.cancelLoading() }
        #expect(manager.session(for: account) === original)

        account.proxy = AccountProxy(scheme: proxy.scheme, host: proxy.host, port: proxy.port,
                                     username: "fixture-user", password: "fixture-password")
        let authenticated = manager.session(for: account)
        #expect(authenticated !== original)
        #expect(authenticated.configuredProxy == account.proxy)
        #expect(await authenticated.webView.configuration.websiteDataStore.httpCookieStore.allCookies()
            .contains { $0.name == "proxy_fixture" && $0.value == "retained" })

        account.proxy = AccountProxy(scheme: .socks5, host: "127.0.0.1", port: 19080)
        #expect(manager.existingSession(for: account) == nil)
        let changed = manager.session(for: account)
        #expect(changed !== original)
        #expect(changed.configuredProxy == account.proxy)
        #expect(await changed.webView.configuration.websiteDataStore.httpCookieStore.allCookies()
            .contains { $0.name == "proxy_fixture" && $0.value == "retained" })

        toggle.enabled = false
        #expect(manager.existingSession(for: account) == nil)
        let direct = manager.session(for: account)
        #expect(direct !== changed)
        #expect(direct.configuredProxy == nil)
        #expect(direct.webView.configuration.websiteDataStore.proxyConfigurations.isEmpty)
        #expect(await direct.webView.configuration.websiteDataStore.httpCookieStore.allCookies()
            .contains { $0.name == "proxy_fixture" && $0.value == "retained" })
        await direct.webView.configuration.websiteDataStore.httpCookieStore.deleteCookie(cookie)
    }

    @Test func rotationReusesSavedProxySessionAndVerificationStaysIsolated() async throws {
        let account = account()
        let manager = WebSessionManager()
        let persistent = manager.session(for: account)
        let automation = ChatGPTAutomation(sessionManager: manager)
        let rotation = automation.twoFARotationSession(for: account)
        let verification = automation.cleanLoginSession(for: account)
        for session in [rotation, verification] {
            #expect(session.configuredProxy == proxy)
            #expect(session.webView.configuration.websiteDataStore.proxyConfigurations.count == 1)
        }
        #expect(rotation === persistent)
        #expect(!verification.webView.configuration.websiteDataStore.isPersistent)
        #expect(verification.webView.configuration.websiteDataStore !== persistent.webView.configuration.websiteDataStore)
        #expect(rotation !== verification)
        #expect(rotation.webView.configuration.websiteDataStore !== verification.webView.configuration.websiteDataStore)
    }

    @Test func injectedFactoriesReceiveResolvedProxyBeforeRequests() {
        let accountFixture = BrowserSession(dataStore: .nonPersistent())
        let verificationFixture = BrowserSession(dataStore: .nonPersistent())
        let manager = WebSessionManager(
            accountSessionFactory: { _ in accountFixture },
            verificationSessionFactory: { verificationFixture })
        #expect(manager.session(for: account()) === accountFixture)
        #expect(manager.verificationSession(for: account()) === verificationFixture)
        for session in [accountFixture, verificationFixture] {
            #expect(session.configuredProxy == proxy)
            #expect(session.webView.url == nil)
            #expect(session.webView.configuration.websiteDataStore.proxyConfigurations.count == 1)
        }
    }

    @Test(arguments: [false, true])
    func newRotationUsesCurrentSavedProfileAfterProxyChange(prepareFirst: Bool) {
        let toggle = ProxyToggle()
        let account = account()
        let manager = WebSessionManager(proxyResolver: { toggle.enabled ? $0.proxy : nil })
        let browser = ChatGPTAutomation(sessionManager: manager)
        browser.prepareBrowserSession(for: account)
        let original = browser.twoFARotationSession(for: account)
        original.setVisible(true)

        toggle.enabled = false
        if prepareFirst { browser.prepareBrowserSession(for: account) }
        let next = browser.twoFARotationSession(for: account)
        #expect(next !== original)
        #expect(next === manager.session(for: account))
        #expect(next.configuredProxy == nil)
        #expect(!original.isVisible)
    }
}
