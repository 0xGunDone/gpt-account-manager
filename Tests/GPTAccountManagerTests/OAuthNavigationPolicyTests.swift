import Foundation
import Testing
@testable import GPTAccountManager

struct OAuthNavigationPolicyTests {
    private func policy(redirect: String = "http://localhost:1455/auth/callback") throws -> OAuthNavigationPolicy {
        var url = URLComponents(string: "https://auth.openai.com/oauth/authorize")!
        url.queryItems = [
            .init(name: "client_id", value: "fixture"),
            .init(name: "redirect_uri", value: redirect),
            .init(name: "state", value: "fixture-state"),
        ]
        return try #require(OAuthNavigationPolicy(authorizationURL: url.url!))
    }

    @Test func codexAccCallbackAcceptsDynamicPortAndRetainsState() throws {
        let policy = try policy(redirect: "http://localhost:23456/auth/callback")
        #expect(policy.allowsCallback(URL(string: "http://localhost:23456/auth/callback?code=fixture&state=fixture-state")))
        #expect(policy.allowsCallback(URL(string: "http://localhost:23456/auth/callback?error=access_denied&state=fixture-state")))
    }

    @Test(arguments: [
        "http://localhost:1456/auth/callback?code=x&state=fixture-state",
        "http://localhost:1455/unrelated?code=x&state=fixture-state",
        "http://localhost.evil.example:1455/auth/callback?code=x&state=fixture-state",
        "http://127.0.0.1:1455/auth/callback?code=x&state=fixture-state",
        "http://localhost:1455/auth/callback?code=x&state=wrong",
        "http://localhost:1455/auth/callback?code=x",
        "http://localhost:1455/auth/callback?state=fixture-state&state=other",
        "http://user:password@localhost:1455/auth/callback?state=fixture-state",
    ])
    func callbackRejectsOtherDestinationsAndStaleRequests(value: String) throws {
        #expect(try !policy().allowsCallback(URL(string: value)))
    }

    @Test(arguments: [
        "http://auth.openai.com/oauth/authorize?client_id=x&redirect_uri=https://example.com/cb",
        "https://auth.openai.com.evil.example/oauth/authorize?client_id=x&redirect_uri=https://example.com/cb",
        "https://auth.openai.com:8443/oauth/authorize?client_id=x&redirect_uri=https://example.com/cb",
        "https://user@auth.openai.com/oauth/authorize?client_id=x&redirect_uri=https://example.com/cb",
        "https://auth.openai.com/logout?client_id=x&redirect_uri=https://example.com/cb",
        "https://auth.openai.com/oauth/authorize?client_id=x&redirect_uri=javascript:alert(1)",
        "https://auth.openai.com/oauth/authorize?client_id=x&redirect_uri=file:///tmp/cb",
        "https://auth.openai.com/oauth/authorize?client_id=x&redirect_uri=https://example.com/cb&redirect_uri=https://other.example/cb",
        "https://auth.openai.com/oauth/authorize",
    ])
    func rejectsMalformedOrUntrustedAuthorizationLinks(value: String) {
        #expect(OAuthNavigationPolicy(authorizationURL: URL(string: value)!) == nil)
    }

    @Test func remoteHTTPCallbackKeepsExactDestinationAndState() throws {
        let policy = try policy(redirect: "http://omni.example:8080/callback")
        #expect(policy.allowsCallback(URL(string: "http://omni.example:8080/callback?code=x&state=fixture-state")))
        #expect(!policy.allowsCallback(URL(string: "http://omni.example:8081/callback?code=x&state=fixture-state")))
        #expect(!policy.allowsCallback(URL(string: "http://omni.example:8080/callback?code=x&state=wrong")))
    }

    @Test func httpsCallbackCannotNavigateElsewhereOnItsHost() throws {
        let policy = try policy(redirect: "https://app.example/callback?flow=codex")
        #expect(policy.allowsCallback(URL(string: "https://app.example/callback?flow=codex&code=x&state=fixture-state")))
        #expect(!policy.allowsCallback(URL(string: "https://app.example/other?flow=codex&state=fixture-state")))
        #expect(!policy.allowsCallback(URL(string: "https://app.example/callback?state=fixture-state")))
    }
}
