import AppKit
import Foundation
import Testing
import WebKit
@testable import GPTAccountManager

@MainActor
private final class CurrentSecurityRouteWebView: WKWebView {
    private(set) var requestedURLs: [URL] = []

    static let securityHTML = """
    <html><body>
      <h1>Безопасность и вход</h1>
      <button role="switch" aria-label="Приложение для аутентификации"
              aria-checked="false" style="width:44px;height:24px"></button>
    </body></html>
    """

    override func load(_ request: URLRequest) -> WKNavigation? {
        if let url = request.url { requestedURLs.append(url) }
        return super.loadHTMLString(Self.securityHTML, baseURL: request.url)
    }
}

@MainActor
@Suite(.serialized)
struct CurrentSecurityRouteTests {
    private func fixture(html: String, url: URL) async throws -> (BrowserSession, CurrentSecurityRouteWebView) {
        _ = NSApplication.shared
        let session = BrowserSession(dataStore: .nonPersistent()) { configuration in
            CurrentSecurityRouteWebView(
                frame: NSRect(x: 0, y: 0, width: 800, height: 600),
                configuration: configuration)
        }
        let webView = try #require(session.webView as? CurrentSecurityRouteWebView)
        webView.navigationDelegate = nil
        webView.loadHTMLString(html, baseURL: url)
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while webView.isLoading, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(30))
        }
        try #require(!webView.isLoading && webView.url == url)
        return (session, webView)
    }

    @Test func openingSecurityFromHomeRequestsTheCurrentDirectRoute() async throws {
        let (session, webView) = try await fixture(
            html: "<html><body><p>Home</p></body></html>",
            url: URL(string: "https://chatgpt.com/")!)
        let automation = ChatGPTAutomation(sessionManager: WebSessionManager())

        let opened = await automation.openSecuritySettings(in: session, seconds: 3)

        #expect(opened)
        #expect(webView.requestedURLs == [URL(string: "https://chatgpt.com/settings/security")!])
    }

    @Test(arguments: [
        "https://chatgpt.com/settings/security?action=disable&factor=totp&factor_id=fixture",
        "https://chatgpt.com/?action=disable&factor=totp&factor_id=fixture#settings/Security",
    ])
    func anOpenSecurityActionKeepsItsOriginalURL(address: String) async throws {
        let url = try #require(URL(string: address))
        let (session, webView) = try await fixture(html: CurrentSecurityRouteWebView.securityHTML, url: url)
        let automation = ChatGPTAutomation(sessionManager: WebSessionManager())

        let opened = await automation.openSecuritySettings(in: session, seconds: 1)

        #expect(opened)
        #expect(webView.requestedURLs.isEmpty)
        #expect(webView.url == url)
    }
}
