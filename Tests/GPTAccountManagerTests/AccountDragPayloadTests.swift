import Foundation
import Testing
@testable import GPTAccountManager

@Suite struct AccountDragPayloadTests {
    @Test func payloadRoundTripsOnlyAccountID() throws {
        let id = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let data = try JSONEncoder().encode(AccountDragPayload(accountID: id))
        let decoded = try JSONDecoder().decode(AccountDragPayload.self, from: data)
        #expect(decoded == AccountDragPayload(accountID: id))
    }

    @Test func payloadRoundTripsMultipleIDsWithoutCredentialFields() throws {
        let firstID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let secondID = UUID(uuidString: "66666666-7777-8888-9999-AAAAAAAAAAAA")!
        let payload = AccountDragPayload(accountIDs: [firstID, secondID, firstID])

        let data = try JSONEncoder().encode(payload)
        let decoded = try JSONDecoder().decode(AccountDragPayload.self, from: data)
        let json = String(decoding: data, as: UTF8.self)

        #expect(decoded.accountIDs == [firstID, secondID])
        #expect(json.contains("accountIDs"))
        #expect(!json.contains("login"))
        #expect(!json.contains("password"))
        #expect(!json.contains("totp"))
    }

    @Test func legacySingleIDPayloadDecodesAsOneIDCollection() throws {
        let id = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let data = Data("{\"accountID\":\"\(id.uuidString)\"}".utf8)

        let decoded = try JSONDecoder().decode(AccountDragPayload.self, from: data)

        #expect(decoded.accountIDs == [id])
    }

    @Test func dropSelectionFlattensPayloadsAndIgnoresUnknownIDs() {
        let knownID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let unknownID = UUID(uuidString: "66666666-7777-8888-9999-AAAAAAAAAAAA")!
        let payloads = [
            AccountDragPayload(accountIDs: [knownID, unknownID]),
            AccountDragPayload(accountID: knownID),
        ]

        #expect(AccountDragSelection.knownIDs(
            from: payloads,
            knownIDs: [knownID]) == [knownID])
    }

    @Test func dragTokenRoundTripsMultipleIDsAndRejectsUnrelatedText() throws {
        let firstID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let secondID = UUID(uuidString: "66666666-7777-8888-9999-AAAAAAAAAAAA")!
        let payload = AccountDragPayload(accountIDs: [firstID, secondID])

        let token = AccountDragToken.encode(payload)
        let decoded = AccountDragToken.decode(token)

        #expect(decoded == payload)
        #expect(AccountDragToken.decode("11111111-2222-3333-4444-555555555555") == nil)
        #expect(!token.localizedCaseInsensitiveContains("password"))
        #expect(!token.localizedCaseInsensitiveContains("totp"))
    }

    @Test func dragKeepsPreservedMultiSelectionDuringMouseDownCollapse() {
        let firstID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let secondID = UUID(uuidString: "66666666-7777-8888-9999-AAAAAAAAAAAA")!
        let thirdID = UUID(uuidString: "BBBBBBBB-CCCC-DDDD-EEEE-FFFFFFFFFFFF")!
        let currentIDs: Set<UUID> = [firstID]
        let preservedIDs: Set<UUID> = [firstID, secondID]

        #expect(AccountDragSelection.effectiveSelectedIDs(
            for: firstID,
            currentIDs: currentIDs,
            preservedIDs: preservedIDs) == preservedIDs)
        #expect(AccountDragSelection.effectiveSelectedIDs(
            for: thirdID,
            currentIDs: currentIDs,
            preservedIDs: preservedIDs) == currentIDs)
    }
}
