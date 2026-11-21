import Foundation
import Testing
@testable import GPTAccountManager

struct BrowserAddressTests {
    @Test(arguments: [
        "https://auth.openai.com/log-in?state=a%2Bb%3D",
        "https://external.example/login#step",
        "http://omni.example:8080/callback?code=hello%2Bworld&state=test",
    ])
    func preservesManualURLs(value: String) {
        #expect(BrowserAddress.url(from: " \(value)\n")?.absoluteString == value)
    }

    @Test(arguments: [
        "javascript:alert(1)", "file:///tmp/private", "data:text/html,test", "not a url",
        "https://user:password@example.com/", "https:///", "https://example.com:99999/",
    ])
    func rejectsNonWebAddresses(value: String) {
        #expect(BrowserAddress.url(from: value) == nil)
    }
}
