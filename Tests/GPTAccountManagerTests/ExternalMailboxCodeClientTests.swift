import Foundation
import Testing
@testable import GPTAccountManager

@MainActor
struct ExternalMailboxCodeClientTests {
    private func fixture() throws -> ExternalMailboxConfiguration {
        try .init(address: " Login+alias@Example.test ", codeURL: "https://mail.example.test/code?key=fixture")
    }

    @Test func preservesAliasAndRejectsUnsafeURLs() throws {
        #expect(try fixture().address == "login+alias@example.test")
        for url in ["http://mail.example.test/code", "https://user:password@mail.example.test/code",
                    "https://mail.example.test/code#fragment", "file:///private/code"] {
            #expect(throws: ExternalMailboxError.invalidURL) {
                try ExternalMailboxConfiguration(address: "login@example.test", codeURL: url)
            }
        }
    }

    @Test func ignoresPreviousCodeAndKeepsLeadingZeros() async throws {
        var replies = [
            #"{"success":true,"code":"123456"}"#,
            #"{"success":false,"code":"no_code","message":"none"}"#,
            #"{"success":true,"code":"123456"}"#,
            #"{"success":true,"code":"004218"}"#,
        ]
        let configuration = try fixture()
        let client = ExternalMailboxCodeClient(configuration: configuration, load: { url in
            #expect(url == configuration.codeURL)
            return Data(replies.removeFirst().utf8)
        }, pollInterval: .milliseconds(1))

        let baseline = try await client.captureBaseline()
        #expect(ExternalMailboxCodeClient.baselineHasCode(baseline))
        let code = try await client.waitForCode(alias: configuration.address, since: Date(), excluding: baseline)
        #expect(code.code == "004218")
        #expect(replies.isEmpty)
    }

    @Test func requiresBaselineAndKnownProviderStatus() async throws {
        var reads = 0
        let configuration = try fixture()
        let client = ExternalMailboxCodeClient(configuration: configuration, load: { _ in
            reads += 1
            return Data(#"{"success":false,"code":"invalid_key"}"#.utf8)
        })
        await #expect(throws: MailVerificationError.baselineRequired) {
            try await client.waitForCode(alias: configuration.address, since: Date(), excluding: [])
        }
        #expect(reads == 0)
        await #expect(throws: ExternalMailboxError.unavailable) { try await client.captureBaseline() }
        #expect(throws: ExternalMailboxError.unsupportedResponse) {
            try ExternalMailboxCodeClient.decodeCode(Data(#"{"success":true,"code":123456}"#.utf8))
        }
    }
}
