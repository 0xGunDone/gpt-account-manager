import AppKit
import Foundation
import Testing
@testable import GPTAccountManager

@MainActor
@Suite(.serialized)
struct OAuthCallbackTests {
    @Test func externalLoginLearnsOAuthRedirectAndCapturesCallback() async throws {
        let session = BrowserSession(dataStore: .nonPersistent())
        #expect(session.openAddress("https://external.example/login", mode: .copyLink) != nil)
        session.cancelLoading()
        let auth = URL(string: "https://auth.openai.com/oauth/authorize?client_id=fixture&redirect_uri=http%3A%2F%2Flocalhost%3A1%2Fcallback&state=s")!
        session.webView.load(URLRequest(url: auth))
        for _ in 0..<100 {
            if !session.allowsNavigation(URL(string: "https://unrelated.example/")) { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(!session.allowsNavigation(URL(string: "https://unrelated.example/")))
        session.cancelLoading()
        let callback = URL(string: "http://localhost:1/callback?code=x&state=s")!
        let nav = session.webView.load(URLRequest(url: callback))
        _ = await session.waitForNavigation(nav, seconds: 5)
        #expect(session.callbackURL == callback)
        #expect(session.oauthMessage?.contains("Callback получен") == true)
    }

    @Test func copyModeCapturesCallbackWithoutOpeningDestination() async throws {
        let session = BrowserSession(dataStore: .nonPersistent())
        let auth = URL(string: "https://auth.openai.com/oauth/authorize?client_id=fixture&redirect_uri=http%3A%2F%2Flocalhost%3A1%2Fcallback&state=fixture-state")!
        #expect(session.loadOAuth(auth, mode: .copyLink) != nil)
        session.cancelLoading()
        let callback = URL(string: "http://localhost:1/callback?code=fixture%2Bcode&state=fixture-state")!
        let navigation = session.webView.load(URLRequest(url: callback))
        #expect(!(await session.waitForNavigation(navigation, seconds: 8)))
        #expect(session.callbackURL == callback)
        #expect(session.addressText == callback.absoluteString)
        #expect(session.oauthMessage?.contains("Callback получен") == true)
        #expect(session.webView.url != callback)
    }

    @Test func failedCallbackRemainsAvailableForCopying() async throws {
        let session = BrowserSession(dataStore: .nonPersistent())
        let auth = URL(string: "https://auth.openai.com/oauth/authorize?client_id=fixture&redirect_uri=http%3A%2F%2Flocalhost%3A1%2Fcallback&state=s")!
        #expect(session.loadOAuth(auth) != nil)
        session.cancelLoading()
        let callback = URL(string: "http://localhost:1/callback?code=c%2Bd&state=s")!
        let navigation = session.webView.load(URLRequest(url: callback))
        _ = await session.waitForNavigation(navigation, seconds: 3)
        #expect(session.addressText == callback.absoluteString)
        #expect(session.callbackURL == callback)
        session.endOAuth()
        #expect(session.callbackURL == nil)
        #expect(!session.allowsNavigation(callback))
    }

    @Test func manualBrowsingDoesNotAllowCredentialAutomationOnExternalPages() async throws {
        let session = BrowserSession(dataStore: .nonPersistent())
        #expect(session.openAddress("https://external.example/login") != nil)
        session.cancelLoading()
        #expect(session.allowsNavigation(URL(string: "http://external.example/callback")))
        #expect(!session.allowsNavigation(URL(string: "file:///tmp/private")))
        session.webView.navigationDelegate = nil
        let nav = session.webView.loadHTMLString("<input type='password'>", baseURL: URL(string: "https://external.example/"))
        _ = nav
        for _ in 0..<40 where session.webView.isLoading {
            try await Task.sleep(for: .milliseconds(50))
        }
        do {
            _ = try await session.evaluate("document.body.innerText")
            Issue.record("External page received credential automation")
        } catch BrowserSessionError.untrustedOrigin {}
        session.endOAuth()
        #expect(!session.allowsNavigation(URL(string: "https://external.example/")))
    }

    @Test func webKitDeliversOAuthCallbackToLocalApplication() async throws {
        _ = NSApplication.shared
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-u", "-c", """
        from http.server import HTTPServer, BaseHTTPRequestHandler
        class Handler(BaseHTTPRequestHandler):
            def do_GET(self):
                expected = '/auth/callback?code=fixture-code&state=fixture-state'
                body = ('callback received' if self.path == expected else 'wrong callback').encode()
                self.send_response(200)
                self.send_header('Content-Type', 'text/plain')
                self.send_header('Content-Length', str(len(body)))
                self.end_headers()
                self.wfile.write(body)
            def log_message(self, *args): pass
        server = HTTPServer(('127.0.0.1', 0), Handler)
        print(server.server_port, flush=True)
        server.timeout = 10
        server.handle_request()
        """]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer { if process.isRunning { process.terminate() } }
        let portData = output.fileHandleForReading.availableData
        let port = try #require(Int(String(decoding: portData, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)))
        var authorization = URLComponents(string: "https://auth.openai.com/oauth/authorize")!
        authorization.queryItems = [
            .init(name: "client_id", value: "fixture"),
            .init(name: "redirect_uri", value: "http://localhost:\(port)/auth/callback"),
            .init(name: "state", value: "fixture-state"),
        ]
        let session = BrowserSession(dataStore: .nonPersistent())
        #expect(session.loadOAuth(authorization.url!) != nil)
        session.cancelLoading()
        let callback = URL(string: "http://localhost:\(port)/auth/callback?code=fixture-code&state=fixture-state")!
        let navigation = session.webView.load(URLRequest(url: callback))
        #expect(await session.waitForNavigation(navigation, seconds: 8))
        let body = try await session.webView.evaluateJavaScript("document.body.innerText") as? String
        #expect(body == "callback received")
        #expect(session.oauthMessage?.contains("CodexAcc") == true)
        do {
            _ = try await session.evaluate("document.body.innerText")
            Issue.record("Account automation must not execute on callback pages")
        } catch BrowserSessionError.untrustedOrigin {
            // Navigation is allowed, credential automation remains restricted to OpenAI.
        }
    }
}
