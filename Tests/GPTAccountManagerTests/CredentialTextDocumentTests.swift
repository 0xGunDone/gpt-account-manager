import Testing
@testable import GPTAccountManager

@Suite struct CredentialTextDocumentTests {
    @Test func documentKeepsExactCredentialText() {
        let document = CredentialTextDocument(text: "a@example.com|p|JBSWY3DPEHPK3PXP\n")
        #expect(document.text == "a@example.com|p|JBSWY3DPEHPK3PXP\n")
    }
}
