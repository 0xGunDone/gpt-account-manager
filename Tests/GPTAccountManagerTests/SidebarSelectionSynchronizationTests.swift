import Foundation
import Testing
@testable import GPTAccountManager

@Suite struct SidebarSelectionSynchronizationTests {
    @Test func automationReselectsAccountAfterGroupOrUngroupedSelection() {
        let accountID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let groupID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!

        for nonAccountSelection in [SidebarSelection.group(groupID), .ungrouped] {
            var sidebarSelection: SidebarSelection? = .account(accountID)
            var selectedID: UUID? = accountID

            sidebarSelection = nonAccountSelection
            selectedID = SidebarSelectionSynchronization.selectedID(
                for: sidebarSelection)
            #expect(selectedID == nil)

            selectedID = accountID
            sidebarSelection = SidebarSelectionSynchronization.sidebarSelection(
                for: selectedID,
                preserving: sidebarSelection)
            #expect(sidebarSelection == .account(accountID))
        }
    }

    @Test func nilStoreSelectionPreservesGroupAndUngroupedSelection() {
        let groupID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!

        #expect(SidebarSelectionSynchronization.sidebarSelection(
            for: nil,
            preserving: .group(groupID)) == .group(groupID))
        #expect(SidebarSelectionSynchronization.sidebarSelection(
            for: nil,
            preserving: .ungrouped) == .ungrouped)
    }

    @Test func accountAndCoordinatorSelectionsMapNormally() {
        let firstID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let secondID = UUID(uuidString: "66666666-7777-8888-9999-AAAAAAAAAAAA")!

        #expect(SidebarSelectionSynchronization.selectedID(
            for: .account(firstID)) == firstID)
        #expect(SidebarSelectionSynchronization.sidebarSelection(
            for: secondID,
            preserving: .account(firstID)) == .account(secondID))
    }

    @Test func accountSelectionFiltersOutGroupsAndUngroupedRows() {
        let firstID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let secondID = UUID(uuidString: "66666666-7777-8888-9999-AAAAAAAAAAAA")!
        let groupID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let rows: Set<SidebarSelection> = [
            .account(firstID),
            .account(secondID),
            .group(groupID),
            .ungrouped,
        ]

        #expect(SidebarAccountSelection.normalized(rows) == [firstID, secondID])
    }

    @Test func categorySelectionIsSingleAndClearsAccountSelection() {
        let accountID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let groupID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let rows: Set<SidebarSelection> = [
            .account(accountID),
            .group(groupID),
            .ungrouped,
        ]

        let normalizedRows = SidebarAccountSelection.normalizedRows(rows)
        #expect(normalizedRows == [.group(groupID)])
        #expect(SidebarAccountSelection.normalized(normalizedRows).isEmpty)
        #expect(SidebarAccountSelection.navigationSelection(
            for: rows,
            preserving: .account(accountID)) == .group(groupID))
    }

    @Test func ungroupedSelectionIsAValidSingleNavigationTarget() {
        let accountID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let rows: Set<SidebarSelection> = [.account(accountID), .ungrouped]

        #expect(SidebarAccountSelection.normalizedRows(rows) == [.ungrouped])
        #expect(SidebarAccountSelection.navigationSelection(
            for: rows,
            preserving: .account(accountID)) == .ungrouped)
    }

    @Test func selectedRowDragUsesStableSelectedOrderOrOnlyDraggedRow() {
        let firstID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let secondID = UUID(uuidString: "66666666-7777-8888-9999-AAAAAAAAAAAA")!
        let thirdID = UUID(uuidString: "BBBBBBBB-CCCC-DDDD-EEEE-FFFFFFFFFFFF")!
        let selectedIDs: Set<UUID> = [firstID, thirdID]
        let orderedIDs = [secondID, thirdID, firstID]

        #expect(AccountDragSelection.ids(
            for: thirdID,
            selectedIDs: selectedIDs,
            orderedIDs: orderedIDs) == [thirdID, firstID])
        #expect(AccountDragSelection.ids(
            for: secondID,
            selectedIDs: selectedIDs,
            orderedIDs: orderedIDs) == [secondID])
    }

    @Test func newlySelectedAccountBecomesNavigationTarget() {
        let firstID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let secondID = UUID(uuidString: "66666666-7777-8888-9999-AAAAAAAAAAAA")!
        let previous: Set<SidebarSelection> = [.account(firstID)]
        let current: Set<SidebarSelection> = [.account(firstID), .account(secondID)]

        #expect(SidebarAccountSelection.navigationSelection(
            for: current,
            previousSelections: previous,
            preserving: .account(firstID),
            orderedAccountIDs: [firstID, secondID]) == .account(secondID))
    }

    @Test func shiftRangeChoosesTheClickedEndOfTheRange() {
        let firstID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let secondID = UUID(uuidString: "66666666-7777-8888-9999-AAAAAAAAAAAA")!
        let thirdID = UUID(uuidString: "BBBBBBBB-CCCC-DDDD-EEEE-FFFFFFFFFFFF")!
        let fourthID = UUID(uuidString: "12345678-1234-1234-1234-123456789012")!
        let previous: Set<SidebarSelection> = [.account(fourthID)]
        let current: Set<SidebarSelection> = [
            .account(secondID),
            .account(thirdID),
            .account(fourthID),
        ]

        #expect(SidebarAccountSelection.navigationSelection(
            for: current,
            previousSelections: previous,
            preserving: .account(fourthID),
            orderedAccountIDs: [firstID, secondID, thirdID, fourthID]) == .account(secondID))
    }
}
