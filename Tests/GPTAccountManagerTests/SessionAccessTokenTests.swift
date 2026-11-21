import AppKit
import Testing
import WebKit
@testable import GPTAccountManager

@MainActor
private final class CheckedTokenWebView: WKWebView {
    override func load(_ request: URLRequest) -> WKNavigation? {
        super.loadHTMLString("""
        <h1>Local checked-token fixture</h1><script>
          window.fetch = async url => ({ok:true,status:200,json:async()=>
            String(url).startsWith('/backend-api/subscriptions')
              ? {account_id:'fixture-account',plan_type:'plus',active_until:'2027-01-01T00:00:00Z',will_renew:true}
              : {user:{email:'owner@example.com'},account:{id:'fixture-account'},accessToken:'fixture.checked.token'}
          });
        </script>
        """, baseURL: request.url)
    }
}

@MainActor
@Suite(.serialized)
struct SessionAccessTokenTests {
    private func fixture(_ script: String, url: String = "https://chatgpt.com/") async throws -> BrowserSession {
        _ = NSApplication.shared
        let session = BrowserSession(dataStore: .nonPersistent())
        session.webView.navigationDelegate = nil
        session.webView.loadHTMLString("<h1>Fixture</h1><script>\(script)</script>", baseURL: URL(string: url)!)
        for _ in 0..<100 where session.webView.isLoading { try await Task.sleep(for: .milliseconds(20)) }
        try #require(!session.webView.isLoading)
        return session
    }

    private var account: AccountRecord {
        AccountRecord(credential: .init(email: "owner@example.com", password: "fixture", totpSecret: "JBSWY3DPEHPK3PXP"))
    }

    @Test func ordinaryCheckPersistsTokenFromItsVerifiedSession() async throws {
        _ = NSApplication.shared
        let session = BrowserSession(dataStore: .nonPersistent()) { configuration in
            CheckedTokenWebView(frame: NSRect(x: 0, y: 0, width: 720, height: 500), configuration: configuration)
        }
        let browser = ChatGPTAutomation(sessionManager: WebSessionManager(accountSessionFactory: { _ in session }))
        let store = AccountStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("accounts.json"))
        defer { session.cancelLoading(); try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
        try store.merge([.init(email: account.email, password: account.password, totpSecret: account.totpSecret)])
        let group = try store.createGroup(name: "new-novoreg", tag: nil)
        let id = try #require(store.accounts.first?.id)
        try store.moveAccounts(ids: [id], to: group.id, protectedIDs: [])
        let coordinator = OperationCoordinator(store: store, checker: browser)

        await coordinator.check(id: id)

        #expect(store.accounts[0].status == .ready && store.accounts[0].accessToken == "fixture.checked.token")
        let exported = store.fileURL.deletingLastPathComponent().appendingPathComponent("new-novoreg-access-tokens.txt")
        #expect(try String(contentsOf: exported, encoding: .utf8) == "owner@example.com|fixture.checked.token\n")
        browser.finishSubscriptionCheck(accountID: id)
        await #expect(throws: (any Error).self) {
            try await browser.accessTokenAfterCheck(for: store.accounts[0])
        }
    }

    @Test func tokenComesOnlyFromMatchingAuthenticatedSession() async throws {
        let session = try await fixture("""
        window.fetch=async(url,options)=>{
          window.requestURL=url;window.credentials=options.credentials;
          return {ok:true,json:async()=>({user:{email:'OWNER@example.com'},accessToken:'fixture.access.token'})};
        };
        """)
        let browser = ChatGPTAutomation(sessionManager: WebSessionManager())
        #expect(try await browser.accessToken(for: account, in: session) == "fixture.access.token")
        #expect(try await session.evaluate("window.requestURL") as? String == "/api/auth/session")
        #expect(try await session.evaluate("window.credentials") as? String == "include")
    }

    @Test(arguments: ["other@example.com", "", "owner@example.com"])
    func missingTokenOrWrongIdentityCannotBeExported(email: String) async throws {
        let session = try await fixture("window.fetch=async()=>({ok:true,json:async()=>({user:{email:'\(email)'},accessToken:'\(email == "owner@example.com" ? "" : "fixture.token")'})});")
        let browser = ChatGPTAutomation(sessionManager: WebSessionManager())
        await #expect(throws: (any Error).self) { try await browser.accessToken(for: account, in: session) }
    }

    @Test(arguments: ["wrongOrigin", "navigation", "lineBreak"])
    func unsafeOrChangedSessionCannotReturnToken(reason: String) async throws {
        let script = reason == "navigation"
            ? "window.fetch=async()=>{history.replaceState({},'', '/other');return {ok:true,json:async()=>({user:{email:'owner@example.com'},accessToken:'fixture.token'})}};"
            : "window.fetch=async()=>({ok:true,json:async()=>({user:{email:'owner@example.com'},accessToken:'fixture\\nother'})});"
        let session = try await fixture(script, url: reason == "wrongOrigin" ? "https://other.example/" : "https://chatgpt.com/")
        let browser = ChatGPTAutomation(sessionManager: WebSessionManager())
        await #expect(throws: (any Error).self) { try await browser.accessToken(for: account, in: session) }
    }
}
