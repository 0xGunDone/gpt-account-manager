import Foundation
import Testing
import WebKit
@testable import GPTAccountManager

@Suite struct QRCodeSecretExtractorTests {
    @Test func extractsAndNormalizesSecret() throws {
        let uri = "otpauth://totp/OpenAI:a@example.com?secret=jbswy3dpehpk3pxp&issuer=OpenAI"
        #expect(try QRCodeSecretExtractor.secret(from: uri) == "JBSWY3DPEHPK3PXP")
    }

    @Test func rejectsNonTOTPAndInvalidSecret() {
        #expect(throws: (any Error).self) {
            try QRCodeSecretExtractor.secret(from: "https://example.com")
        }
        #expect(throws: (any Error).self) {
            try QRCodeSecretExtractor.secret(
                from: "otpauth://totp/OpenAI:a@example.com?secret=INVALID_1")
        }
    }

    @MainActor
    @Test func extractsManualSecretOnlyFromAuthenticatorSetupDialog() async throws {
        let session = BrowserSession(dataStore: .nonPersistent())
        session.webView.navigationDelegate = nil
        session.webView.loadHTMLString(
            """
            <html><body>
              <code>KRUGS4ZANFZSAYJA</code>
              <div role="dialog">
                <h2>Подключите приложение для аутентификации</h2>
                <code>JBSWY3DPEHPK3PXP</code>
              </div>
            </body></html>
            """,
            baseURL: URL(string: "https://chatgpt.com/#settings/Security")!)
        while session.webView.isLoading {
            try await Task.sleep(for: .milliseconds(25))
        }

        let secret = try await QRCodeSecretExtractor.extract(from: session.webView)

        #expect(secret == "JBSWY3DPEHPK3PXP")
    }

    @MainActor
    @Test func ignoresManualSecretInHiddenSetupDialog() async throws {
        let session = BrowserSession(dataStore: .nonPersistent())
        session.webView.navigationDelegate = nil
        session.webView.loadHTMLString(
            """
            <html><body>
              <div role="dialog" style="display:none">
                <h2>Подключите приложение для аутентификации</h2>
                <code>KRUGS4ZANFZSAYJA</code>
              </div>
              <div role="dialog">
                <h2>Подключите приложение для аутентификации</h2>
                <code>JBSWY3DPEHPK3PXP</code>
              </div>
            </body></html>
            """,
            baseURL: URL(string: "https://chatgpt.com/#settings/Security")!)
        while session.webView.isLoading {
            try await Task.sleep(for: .milliseconds(25))
        }

        let secret = try await QRCodeSecretExtractor.extract(from: session.webView)

        #expect(secret == "JBSWY3DPEHPK3PXP")
    }
}
