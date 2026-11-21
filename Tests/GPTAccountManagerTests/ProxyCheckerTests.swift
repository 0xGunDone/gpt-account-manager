import Foundation
import Testing
@testable import GPTAccountManager

@Suite struct ProxyCheckerTests {
    private let proxy = AccountProxy(scheme: .http, host: "127.0.0.1", port: 18080,
                                     username: "fixture-user", password: "fixture-password")

    @Test func primarySuccessDoesNotRequestFallback() async {
        let result = await ProxyChecker.check(proxy) { url, configuration in
            #expect(url.host == "api.ipify.org")
            #expect(configuration.proxyConfigurations.count == 1)
            #expect(configuration.proxyConfigurations.first?.allowFailover == false)
            return Data(#"{"ip":"198.51.100.1"}"#.utf8)
        }
        #expect(result.status == .available && result.exitIP == "198.51.100.1")
    }

    @Test(arguments: ["timeout", "bad-response"])
    func primaryServiceFailureUsesIndependentHTTPSServiceThroughSameProxy(behavior: String) async {
        let result = await ProxyChecker.check(proxy) { url, configuration in
            #expect(configuration.proxyConfigurations.count == 1)
            #expect(configuration.proxyConfigurations.first?.allowFailover == false)
            #expect(configuration.timeoutIntervalForResource == 15)
            if url.host == "api.ipify.org" {
                if behavior == "timeout" { throw URLError(.timedOut) }
                return Data("<html>Unavailable</html>".utf8)
            }
            #expect(url == URL(string: "https://www.cloudflare.com/cdn-cgi/trace"))
            return Data("fl=fixture\nip=2001:db8::1\ntls=TLSv1.3\n".utf8)
        }
        #expect(result.status == .available && result.exitIP == "2001:db8::1")
    }

    @Test(arguments: ["ip=not-an-ip", "ip=198.51.100.1\nip=198.51.100.2", "<html>Error</html>"])
    func neitherInvalidResponseNorFailedEndpointCanMarkProxyAvailable(body: String) async {
        let result = await ProxyChecker.check(proxy) { url, _ in
            if url.host == "api.ipify.org" { throw URLError(.timedOut) }
            return Data(body.utf8)
        }
        #expect(result.status == .unavailable && result.exitIP == nil)
        #expect(result.message.contains("оба проверочных сервиса"))
    }

    @Test func cancellationDoesNotTryAnotherEndpoint() async {
        let result = await ProxyChecker.check(proxy) { url, _ in
            #expect(url.host == "api.ipify.org")
            throw CancellationError()
        }
        #expect(result.message == "Проверка отменена.")
    }
}
