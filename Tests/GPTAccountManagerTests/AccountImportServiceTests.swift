import Foundation
import Testing
@testable import GPTAccountManager

@MainActor
@Suite struct AccountImportServiceTests {
    private func store() -> AccountStore {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("accounts.json")
        return AccountStore(fileURL: file)
    }

    @Test func importsOneAccountPerValidLineAndReportsRejectedLines() throws {
        let store = store()
        let summary = try AccountImportService.importText("""
        one@example.com|first|JBSWY3DPEHPK3PXP
        broken
        two@example.com|second|KRUGS4ZANFZSAYJA
        """, into: store)

        #expect(store.accounts.map(\.email) == ["one@example.com", "two@example.com"])
        #expect(summary == AccountImportSummary(imported: 2, duplicates: 0, rejected: 1))
        #expect(summary.message == "Импортировано: 2. Дубликаты: 0. Отклонено: 1.")
    }

    @Test func reimportKeepsRotatedTwoFAOnDiskAndReportsIt() throws {
        let store = store()
        _ = try AccountImportService.importText("one@example.com|original|JBSWY3DPEHPK3PXP", into: store)
        let id = try #require(store.accounts.first?.id)
        try store.mutate(id: id) { $0.totpSecret = "MFRGGZDFMZTWQ2LK" }
        let summary = try AccountImportService.importText("""
        ONE@example.com|updated|JBSWY3DPEHPK3PXP
        new@example.com|new|KRUGS4ZANFZSAYJA
        """, into: store)
        let reloaded = AccountStore(fileURL: store.fileURL)
        try reloaded.load()
        #expect(reloaded.accounts.first?.totpSecret == "MFRGGZDFMZTWQ2LK")
        #expect(reloaded.accounts.first?.password == "updated")
        #expect(reloaded.accounts.last?.totpSecret == "KRUGS4ZANFZSAYJA")
        #expect(summary.preservedTwoFA == 1)
    }

    @Test func duplicateCountUsesExistingLastValueWinsRule() throws {
        let store = store()
        let summary = try AccountImportService.importText("""
        same@example.com|old|JBSWY3DPEHPK3PXP
        SAME@example.com|new|KRUGS4ZANFZSAYJA
        """, into: store)

        #expect(store.accounts.count == 1)
        #expect(store.accounts[0].password == "new")
        #expect(summary == AccountImportSummary(imported: 1, duplicates: 1, rejected: 0))
    }

    @Test func automaticImportDeduplicatesMixedFormatsAndPreservesRotatedTwoFA() throws {
        let store = store()
        _ = try AccountImportService.importText(
            "same@example.com|original|JBSWY3DPEHPK3PXP", into: store)
        let id = try #require(store.accounts.first?.id)
        try store.mutate(id: id) { $0.totpSecret = "MFRGGZDFMZTWQ2LK" }

        let summary = try AccountImportService.importText("""
        same@example.com:old:JBSWY3DPEHPK3PXP
        SAME@example.com;  final:password  ;KRUGS4ZANFZSAYJA
        new@example.com,new-password,KRUGS4ZANFZSAYJA
        invalid
        """, into: store, separator: .automatic)
        let reloaded = AccountStore(fileURL: store.fileURL)
        try reloaded.load()

        #expect(reloaded.accounts.first?.password == "  final:password  ")
        #expect(reloaded.accounts.first?.totpSecret == "MFRGGZDFMZTWQ2LK")
        #expect(reloaded.accounts.last?.totpSecret == "KRUGS4ZANFZSAYJA")
        #expect(summary == AccountImportSummary(
            imported: 2, duplicates: 1, rejected: 1, preservedTwoFA: 1))
    }

    @Test func customSeparatorImportsExactPassword() throws {
        let store = store()
        let summary = try AccountImportService.importText(
            "custom@example.com <->  left <-> right  <-> JBSWY3DPEHPK3PXP",
            into: store,
            separator: .literal(" <-> "))

        #expect(store.accounts.first?.password == " left <-> right ")
        #expect(summary == AccountImportSummary(imported: 1, duplicates: 0, rejected: 0))
    }
}
