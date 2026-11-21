import AppKit
import Testing
import WebKit
@testable import GPTAccountManager

@MainActor
private final class MetadataRetryWebView: WKWebView {
    var firstStatus = 503
    var alwaysFails = false
    override func load(_ request: URLRequest) -> WKNavigation? {
        super.loadHTMLString("""
        <h1>Metadata fixture</h1><script>
        window.reads=0;window.formSubmits=0;
        window.fetch=async()=>{
          window.reads++;
          if (\(alwaysFails ? "true" : "window.reads === 1")) return {ok:false,status:\(firstStatus),headers:{get:()=> '0'}};
          return {ok:true,status:200,json:async()=>({user:{email:'fixture@example.com'},
            account:{id:'fixture-account',planType:'plus'},accessToken:'fixture-token',
            account_id:'fixture-account',plan_type:'plus',active_until:'2027-01-01T00:00:00Z',will_renew:true})};
        };
        </script>
        """, baseURL: request.url)
    }
}

@MainActor
@Suite(.serialized)
struct SubscriptionMetadataRetryTests {
    private let account = AccountRecord(credential: .init(email: "fixture@example.com", password: "fixture", totpSecret: ""))

    private func fixture(status: Int, alwaysFails: Bool) -> (ChatGPTAutomation, BrowserSession) {
        _ = NSApplication.shared
        let session = BrowserSession(dataStore: .nonPersistent()) { configuration in
            let view = MetadataRetryWebView(frame: NSRect(x: 0, y: 0, width: 720, height: 500), configuration: configuration)
            view.firstStatus = status; view.alwaysFails = alwaysFails
            return view
        }
        return (ChatGPTAutomation(sessionManager: WebSessionManager(accountSessionFactory: { _ in session })), session)
    }

    @Test func transientSessionReadRetriesWithoutSubmittingForms() async throws {
        let (browser, session) = fixture(status: 503, alwaysFails: false)
        defer { session.cancelLoading() }
        let result = await browser.check(account: account)
        guard case .success = result else { Issue.record("Transient metadata read must recover"); return }
        #expect(try await session.evaluate("window.reads >= 2") as? Bool == true)
        #expect(try await session.evaluate("window.formSubmits") as? Int == 0)
    }

    @Test func repeatedRateLimitStopsAfterThreeReads() async throws {
        let (browser, session) = fixture(status: 429, alwaysFails: true)
        defer { session.cancelLoading() }
        let result = await browser.check(account: account)
        guard case .manualActionRequired = result else { Issue.record("Bounded retry must pause on persistent rate limit"); return }
        #expect(try await session.evaluate("window.reads") as? Int == 3)
        #expect(try await session.evaluate("window.formSubmits") as? Int == 0)
    }

    @Test func nonTransientReadDoesNotRetry() async throws {
        let (browser, session) = fixture(status: 400, alwaysFails: true)
        defer { session.cancelLoading() }
        _ = await browser.check(account: account)
        #expect(try await session.evaluate("window.reads") as? Int == 1)
    }
}
