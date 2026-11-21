import Foundation
import Testing
@testable import GPTAccountManager

@Suite struct ImportExportServiceTests {
    @Test func editableCredentialLinePreservesPipesInsidePassword() throws {
        let value = try ImportExportService.parseCredentialLine(
            "one@example.com|part|two|JBSWY3DPEHPK3PXP")

        #expect(value == ImportedCredential(
            email: "one@example.com",
            password: "part|two",
            totpSecret: "JBSWY3DPEHPK3PXP"))
    }

    @Test func editableCredentialLineRejectsInvalidSecret() {
        #expect(throws: CredentialLineError.invalidSecret) {
            try ImportExportService.parseCredentialLine("one@example.com|password|bad")
        }
    }

    @Test func clipboardHasOneCredentialPerLineWithoutTrailingBlankLine() {
        let accounts = [
            AccountRecord(credential: .init(email: "one@example.com", password: "p1", totpSecret: "JBSWY3DPEHPK3PXP")),
            AccountRecord(credential: .init(email: "two@example.com", password: "p2", totpSecret: "KRUGS4ZANFZSAYJA")),
        ]
        #expect(ImportExportService.serializeForClipboard(accounts) == "one@example.com|p1|JBSWY3DPEHPK3PXP\ntwo@example.com|p2|KRUGS4ZANFZSAYJA")
    }

    @Test func passwordMayContainPipesAndRoundTrips() {
        let result = ImportExportService.parse("owner@example.com|left|right|JBSWY3DPEHPK3PXP")
        #expect(result.records == [
            ImportedCredential(
                email: "owner@example.com",
                password: "left|right",
                totpSecret: "JBSWY3DPEHPK3PXP")
        ])
        #expect(result.issues.isEmpty)

        let account = AccountRecord(credential: result.records[0])
        #expect(ImportExportService.serialize([account]) ==
            "owner@example.com|left|right|JBSWY3DPEHPK3PXP\n")
    }

    @Test func lastDuplicateWinsAndMalformedLinesAreReported() {
        let text = """
        same@example.com|old|JBSWY3DPEHPK3PXP
        malformed
        same@example.com|new|KRUGS4ZANFZSAYJA
        """
        let result = ImportExportService.parse(text)

        #expect(result.records.count == 1)
        #expect(result.records[0].password == "new")
        #expect(result.duplicateEmails == ["same@example.com"])
        #expect(result.issues == [ImportIssue(lineNumber: 2, message: "Expected LOGIN|PASS|2FA")])
    }

    @Test(arguments: ["Ссылка для кода с почты", "Mailbox code link"], [
        "https://mail.example.test/code?key=fixture",
        "[Получить код](https://mail.example.test/code?key=fixture)",
        "[https://mail.example.test/code?key=fixture](https://mail.example.test/code?key=fixture)",
    ])
    func labeledImportAcceptsRawAndMarkdownEndpoints(label: String, link: String) throws {
        let result = ImportExportService.parse("""
        Email: One@example.com
        Password:  with:literal|delimiters
        2FA: JBSWY3DPEHPK3PXP

        Mailbox email: inbox@example.com
        \(label): \(link)
        two@example.com|fixture|KRUGS4ZANFZSAYJA
        """, separator: .automatic)

        #expect(result.issues.isEmpty)
        #expect(result.records.map(\.email) == ["One@example.com", "two@example.com"])
        let first = try #require(result.records.first)
        #expect(first.password == " with:literal|delimiters")
        let mailbox = try #require(first.externalMailbox)
        #expect(mailbox.address == "inbox@example.com")
        #expect(mailbox.codeURL.absoluteString == "https://mail.example.test/code?key=fixture")
        #expect(result.records.last?.externalMailbox == nil)
    }

    @Test(arguments: [
        "",
        "http://mail.example.test/code?key=fixture",
        "[https://mail.example.test/code](https://other.example.test/code?key=fixture)",
    ])
    func invalidMailboxBlockDoesNotFallBackToPartialCredentials(link: String) {
        let result = ImportExportService.parse("""
        Email: invalid@example.com
        Password: fixture
        2FA: JBSWY3DPEHPK3PXP
        Mailbox email: inbox@example.com
        Ссылка для кода с почты: \(link)
        Email: valid@example.com
        Password: fixture
        2FA: JBSWY3DPEHPK3PXP
        Mailbox email: valid@example.com
        Ссылка для кода с почты: https://mail.example.test/code?key=valid-fixture
        """)

        #expect(result.records.map(\.email) == ["valid@example.com"])
        #expect(result.issues == [ImportIssue(
            lineNumber: 1, message: "Expected Email, Password, 2FA, Mailbox email, and Mailbox code link with an HTTPS URL")])
    }

    @Test func detectsMultipleBlocksWithMixedLabelsAndFormatting() {
        let result = ImportExportService.parse("""
        Email: one@example.test
        Password:  exact:password|value
        2FA: JBSWY3DPEHPK3PXP
        Mailbox email: inbox@example.test
        Mailbox code link: https://mail.example.test/code?key=one

        - **Логин:** two@example.test
        - **Пароль**: **literal**
        - Ключ 2FA: JBSWY3DPEHPK3PXP
        - Адрес ящика: inbox+two@example.test
        - Ссылка для кода с почты: [Код](https://mail.example.test/code?key=two)
        E-mail： three@example.test
        Pass: third
        TOTP secret: JBSWY3DPEHPK3PXP
        MAILBOX_EMAIL: inbox+three@example.test
        Mailbox code URL: https://mail.example.test/code?key=three
        """, separator: .automatic)

        #expect(result.issues.isEmpty)
        #expect(result.records.map(\.email) == ["one@example.test", "two@example.test", "three@example.test"])
        #expect(result.records.map(\.password) == [" exact:password|value", "**literal**", "third"])
        #expect(result.records.compactMap { $0.externalMailbox?.codeURL.query } == ["key=one", "key=two", "key=three"])
    }

    @Test func preservesLiteralImportsAndLineNumbersWithCRLF() {
        let result = ImportExportService.parse(
            "login:one:JBSWY3DPEHPK3PXP\r\npassword:two:JBSWY3DPEHPK3PXP\r\nbroken",
            separator: .literal(":"))

        #expect(result.records.map(\.email) == ["login", "password"])
        #expect(result.issues.map(\.lineNumber) == [3])
    }

    @Test func invalidTOTPSecretIsRejectedAtImportBoundary() {
        let result = ImportExportService.parse("owner@example.com|secret|NOT_VALID_1")
        #expect(result.records.isEmpty)
        #expect(result.issues == [
            ImportIssue(lineNumber: 1, message: "2FA must be a valid Base32 secret")
        ])
    }

    @Test func automaticImportDetectsEachLineAndPreservesMixedPasswordSeparators() {
        let password = "  left|middle:right;more,with\ttabs  "
        let separators = ["|", ":", ";", ",", "\t"]
        let text = separators.enumerated().map { offset, separator in
            "user\(offset)@example.com\(separator)\(password)\(separator)JBSWY3DPEHPK3PXP"
        }.joined(separator: "\n")

        let result = ImportExportService.parse(text, separator: .automatic)

        #expect(result.issues.isEmpty)
        #expect(result.records.map(\.email) == (0..<5).map { "user\($0)@example.com" })
        #expect(result.records.allSatisfy { $0.password == password })
    }

    @Test(arguments: ["|", ":", ";", ",", "\t", "::", "👩🏽‍💻::", " <-> "])
    func literalSeparatorPreservesPasswordBytesAndSecretFormatting(separator: String) throws {
        let password = " \te\u{301}\(separator)inside|:;,\t "
        let secret = "jbsw-y3dp ehpk3pxp"
        let result = ImportExportService.parse(
            "  owner@example.com \(separator)\(password)\(separator) \(secret) ",
            separator: .literal(separator))
        let credential = try #require(result.records.first)

        #expect(result.issues.isEmpty)
        #expect(credential.email == "owner@example.com")
        #expect(Array(credential.password.utf8) == Array(password.utf8))
        #expect(credential.totpSecret == secret)
    }

    @Test func overlappingLiteralSeparatorUsesFirstAndLastNonOverlappingBounds() {
        let result = ImportExportService.parse(
            "owner@example.comabababaJBSWY3DPEHPK3PXP",
            separator: .literal("aba"))
        #expect(result.records.first?.password == "b")
        #expect(result.issues.isEmpty)

        let malformed = ImportExportService.parse(
            "owner@example.comababaJBSWY3DPEHPK3PXP",
            separator: .literal("aba"))
        #expect(malformed.records.isEmpty)
        #expect(malformed.issues.count == 1)
    }

    @Test(arguments: ["", "\n", "\r", "|\n|", "\u{2028}"])
    func invalidSeparatorIsRejectedWithoutIncludingCredentials(separator: String) {
        let result = ImportExportService.parse(
            "owner@example.com|private-password|JBSWY3DPEHPK3PXP",
            separator: .literal(separator))
        #expect(result.records.isEmpty)
        #expect(result.issues == [
            ImportIssue(lineNumber: 1, message: "Separator must not be empty or contain line breaks")
        ])
    }

    @Test func automaticImportRejectsAmbiguousPasswordBoundaries() {
        let text = "owner@example.com\t:private-password:\tJBSWY3DPEHPK3PXP"
        let result = ImportExportService.parse(text, separator: .automatic)
        #expect(result.records.isEmpty)
        #expect(result.issues == [
            ImportIssue(lineNumber: 1, message: "Ambiguous separators; choose a separator manually")
        ])
        #expect(ImportExportService.parse(text, separator: .literal(":")).records.first?.password ==
            "private-password")
        #expect(ImportExportService.parse(text, separator: .literal("\t")).records.first?.password ==
            ":private-password:")
    }

    @Test func automaticImportRequiresEmailBoundaryAndValidSecret() {
        let result = ImportExportService.parse("""
        owner@example.com|password:another:JBSWY3DPEHPK3PXP
        username:password:JBSWY3DPEHPK3PXP
        owner@example.com:password:bad
        """, separator: .automatic)
        #expect(result.records.isEmpty)
        #expect(result.issues.map(\.lineNumber) == [1, 2, 3])
    }

    @Test func legacyPipeModeRetainsExistingValidationAndDoesNotDetectOtherSeparators() {
        let result = ImportExportService.parse("""
        username|password|JBSWY3DPEHPK3PXP
        owner@example.com:password:JBSWY3DPEHPK3PXP
        owner@example.com||JBSWY3DPEHPK3PXP
        """)
        #expect(result.records.first?.email == "username")
        #expect(result.issues == [
            ImportIssue(lineNumber: 2, message: "Expected LOGIN|PASS|2FA"),
            ImportIssue(lineNumber: 3, message: "LOGIN, PASS and 2FA are required")
        ])
    }
}
