import AppKit
import Foundation
import Testing
import WebKit
@testable import GPTAccountManager

@MainActor
private final class PasswordLoginWebView: WKWebView {
    var fixtureHTML = ""
    var preauthenticated = false
    var guestLanding = false
    override func load(_ request: URLRequest) -> WKNavigation? {
        super.loadHTMLString(fixtureHTML, baseURL: preauthenticated || guestLanding
            ? request.url : URL(string: "https://auth.openai.com/log-in/password"))
    }
}

@MainActor
private final class PasswordLoginCompletion: NSObject, WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        let email = message.body as? String ?? ""
        let emailJSON = String(decoding: try! JSONEncoder().encode(email), as: UTF8.self)
        message.webView?.loadHTMLString("""
        <main>Signed in</main><script>
        window.fetch = async () => ({ok:true,json:async()=>({user:{email:\(emailJSON)}})});
        </script>
        """, baseURL: URL(string: "https://chatgpt.com/"))
    }
}

@MainActor
private final class PasswordLandingTransition: NSObject, WKScriptMessageHandler {
    var loginClicks = 0
    var stages: [String] = []
    var passwordAttempts: [String] = []

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let payload = message.body as? [String: String], let stage = payload["stage"] else { return }
        stages.append(stage)
        switch stage {
        case "login":
            loginClicks += 1
            message.webView?.loadHTMLString("""
            <form onsubmit="event.preventDefault();window.webkit.messageHandlers.landingTransition.postMessage({stage:'email',value:document.querySelector('input').value})">
              <input type="email" name="username"><button type="submit">Continue</button>
            </form>
            """, baseURL: URL(string: "https://auth.openai.com/log-in"))
        case "email":
            guard payload["value"] == "owner@example.com" else { return }
            message.webView?.loadHTMLString("""
            <p>Sign in to owner@example.com</p>
            <form onsubmit="event.preventDefault();window.webkit.messageHandlers.landingTransition.postMessage({stage:'password',value:document.querySelector('input').value})">
              <input type="password" autocomplete="current-password"><button type="submit">Continue</button>
            </form>
            """, baseURL: URL(string: "https://auth.openai.com/log-in/password"))
        case "password":
            passwordAttempts.append(payload["value"] ?? "")
            guard payload["value"] == "candidate-fixture" else { return }
            message.webView?.loadHTMLString("""
            <main>Signed in</main><script>
            window.fetch=async()=>({ok:true,json:async()=>({user:{email:'owner@example.com'}})});
            </script>
            """, baseURL: URL(string: "https://chatgpt.com/"))
        default:
            Issue.record("Unexpected password verification stage: \(stage)")
        }
    }
}

@MainActor
@Suite(.serialized)
struct PasswordVerificationTests {
    @Test(arguments: ["Вход", "Sign in", "Войти"])
    func candidateLoginFromGuestLandingClicksVisibleLoginOnce(label: String) async throws {
        _ = NSApplication.shared
        let transition = PasswordLandingTransition()
        var windows: [NSWindow] = []
        defer { for window in windows { window.contentView = nil } }
        let manager = WebSessionManager(accountSessionFactory: { _ in savedSessionFixture() }, verificationSessionFactory: {
            let session = BrowserSession(dataStore: .nonPersistent()) { configuration in
                configuration.userContentController.add(transition, name: "landingTransition")
                let web = PasswordLoginWebView(frame: NSRect(x: 0, y: 0, width: 720, height: 500), configuration: configuration)
                web.guestLanding = true
                web.fixtureHTML = """
                <main>
                  <div hidden><button onclick="window.webkit.messageHandlers.landingTransition.postMessage({stage:'hidden'})">\(label)</button></div>
                  <div inert><button onclick="window.webkit.messageHandlers.landingTransition.postMessage({stage:'inert'})">\(label)</button></div>
                  <div aria-hidden="true"><button onclick="window.webkit.messageHandlers.landingTransition.postMessage({stage:'aria-hidden'})">\(label)</button></div>
                  <button onclick="window.webkit.messageHandlers.landingTransition.postMessage({stage:'login'})">\(label)</button>
                </main><script>window.fetch=async()=>({ok:true,json:async()=>({})});</script>
                """
                return web
            }
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 500), styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = session.webView
            windows.append(window)
            return session
        })
        let automation = ChatGPTAutomation(sessionManager: manager)
        let timeout = Task {
            try await Task.sleep(for: .seconds(10))
            automation.cancelActiveOperation()
        }
        defer { timeout.cancel() }
        var account = AccountRecord(credential: .init(email: "owner@example.com", password: "old-fixture", totpSecret: "JBSWY3DPEHPK3PXP"))
        account.pendingPassword = "candidate-fixture"
        let result = await automation.changePassword(account: account, newPassword: "candidate-fixture") {
            Issue.record("Guest verification attempted another password change")
        }
        #expect(transition.loginClicks == 1)
        #expect(transition.stages == ["login", "email", "password"])
        #expect(transition.passwordAttempts == ["candidate-fixture"])
        guard case .success(let email) = result else {
            Issue.record("Guest landing did not complete a fresh candidate password login")
            return
        }
        #expect(email == account.email)
    }

    @Test(arguments: ["accept", "reject", "preauthenticated", "wrong-account"])
    func candidateRequiresFreshSuccessfulLogin(behavior: String) async throws {
        _ = NSApplication.shared
        var windows: [NSWindow] = []
        var sessions: [BrowserSession] = []
        let manager = WebSessionManager(accountSessionFactory: { _ in savedSessionFixture() }, verificationSessionFactory: {
            let session = BrowserSession(dataStore: .nonPersistent()) { configuration in
                configuration.userContentController.add(PasswordLoginCompletion(), name: "passwordLoginCompleted")
                let web = PasswordLoginWebView(frame: NSRect(x: 0, y: 0, width: 720, height: 500), configuration: configuration)
                web.preauthenticated = behavior == "preauthenticated"
                web.fixtureHTML = """
                <form onsubmit="event.preventDefault(); if ('\(behavior)' === 'reject') {document.body.innerHTML = 'Incorrect email address or password';} else if (document.querySelector('input').value === 'candidate-fixture') {window.webkit.messageHandlers.passwordLoginCompleted.postMessage('\(behavior == "wrong-account" ? "other@example.com" : "owner@example.com")');}">
                  <p>Sign in to owner@example.com</p>
                  <input type="password" autocomplete="current-password"><button type="submit">Continue</button>
                </form>
                <script>
                  window.authenticated = '\(behavior)' === 'preauthenticated';
                  window.fetch = async () => ({ok: true, json: async () => window.authenticated
                    ? {user:{email:'\(behavior == "wrong-account" ? "other@example.com" : "owner@example.com")'}} : {}});
                </script>
                """
                return web
            }
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 500), styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = session.webView
            windows.append(window)
            sessions.append(session)
            return session
        })
        defer { for window in windows { window.contentView = nil } }
        let automation = ChatGPTAutomation(sessionManager: manager)
        var account = AccountRecord(credential: .init(email: "owner@example.com", password: "old-fixture", totpSecret: "JBSWY3DPEHPK3PXP"))
        account.pendingPassword = "candidate-fixture"
        let result = await automation.changePassword(account: account, newPassword: "candidate-fixture") {
            Issue.record("Verification attempted another password change")
        }
        if behavior == "accept" {
            guard case .success(let email) = result else { Issue.record("Fresh candidate login was not accepted"); return }
            #expect(email == "owner@example.com")
        } else {
            if case .success = result { Issue.record("Unproven password was accepted") }
        }
        if behavior == "reject" {
            _ = try await sessions[0].evaluate("(() => { window.authenticated = true; document.body.innerHTML = 'Signed in manually'; return true; })()")
            let retry = await automation.changePassword(account: account, newPassword: "candidate-fixture") {}
            if case .success = retry { Issue.record("Manual login after rejected candidate was accepted") }
            #expect(sessions.count == 2)
        }
    }
}
