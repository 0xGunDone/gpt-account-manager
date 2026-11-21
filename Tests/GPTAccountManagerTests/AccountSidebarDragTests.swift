import AppKit
import SwiftUI
import Testing
@testable import GPTAccountManager

@MainActor
private struct AccountSidebarDragFixture: View {
    let store: AccountStore
    @State var selection: SidebarSelection?
    @State var selectedAccountIDs: Set<UUID>
    var onRequestMoveAccounts: (Set<UUID>, UUID?) -> Void = { _, _ in }

    var body: some View {
        AccountSidebarView(
            store: store,
            selection: $selection,
            selectedAccountIDs: $selectedAccountIDs,
            rotationStates: [:],
            onCreateGroup: {},
            onRequestMoveAccounts: onRequestMoveAccounts)
    }
}

@MainActor
private final class AccountSidebarDraggingInfo: NSObject, NSDraggingInfo {
    let draggingDestinationWindow: NSWindow?
    let draggingPasteboard: NSPasteboard
    let draggingLocation: NSPoint
    let draggingSource: Any?
    let draggingSourceOperationMask: NSDragOperation = [.copy, .move]
    let draggingSequenceNumber = 1
    let draggedImageLocation: NSPoint = .zero
    nonisolated var draggedImage: NSImage? { nil }
    var draggingFormation: NSDraggingFormation = .none
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    let springLoadingHighlight: NSSpringLoadingHighlight = .none

    init(pasteboard: NSPasteboard, table: NSTableView, row: Int) {
        draggingDestinationWindow = table.window
        draggingPasteboard = pasteboard
        let rect = table.rect(ofRow: row)
        draggingLocation = table.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
        draggingSource = table
    }

    func slideDraggedImage(to screenPoint: NSPoint) {}
    func resetSpringLoading() {}
    nonisolated override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? { nil }

    func enumerateDraggingItems(
        options enumOpts: NSDraggingItemEnumerationOptions,
        for view: NSView?,
        classes classArray: [AnyClass],
        searchOptions: [NSPasteboard.ReadingOptionKey: Any],
        using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void
    ) {
        let objects = draggingPasteboard.readObjects(forClasses: classArray, options: searchOptions) ?? []
        var stop = ObjCBool(false)
        for (index, object) in objects.enumerated() {
            guard let writer = object as? any NSPasteboardWriting else { continue }
            block(NSDraggingItem(pasteboardWriter: writer), index, &stop)
            if stop.boolValue { break }
        }
    }
}

@MainActor
@Suite(.serialized)
struct AccountSidebarDragTests {
    @Test(arguments: [1, 8])
    func nativeAccountRowsProvideIDOnlyTokensForCurrentSelection(selectedCount: Int) async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AccountStore(fileURL: directory.appendingPathComponent("accounts.json"))
        try store.merge((0..<8).map {
            .init(email: "drag\($0)@example.com", password: "drag-fixture-password", totpSecret: "JBSWY3DPEHPK3PXP")
        })
        _ = try store.createGroup(name: "Drop destination", tag: nil)
        let accountIDs = store.accounts.map(\.id)
        let selectedIDs = Set(accountIDs.prefix(selectedCount))
        let host = NSHostingView(rootView: AccountSidebarDragFixture(
            store: store,
            selection: .account(accountIDs[0]),
            selectedAccountIDs: selectedIDs))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 480),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }

        let expectedRowCount = store.groups.count + 1 + accountIDs.count
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while ContinuousClock.now < deadline {
            host.layoutSubtreeIfNeeded()
            if let table = nativeTable(in: host),
               table.numberOfRows == expectedRowCount,
               table.selectedRowIndexes.count == selectedCount {
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        let table = try #require(nativeTable(in: host), "Sidebar must mount its native list")
        try #require(table.numberOfRows == expectedRowCount)
        try #require(table.selectedRowIndexes.count == selectedCount)

        // Empty destination group and expanded ungrouped header precede both accounts.
        for (offset, accountID) in accountIDs.enumerated() {
            let row = store.groups.count + 1 + offset
            let writer = try #require(
                pasteboardWriter(for: row, in: table),
                "Native list must expose a drag writer for each account row")
            let pasteboard = NSPasteboard.withUniqueName()
            defer { pasteboard.releaseGlobally() }
            try #require(pasteboard.writeObjects([writer]))
            let token = try #require(pasteboard.string(forType: .string))
            let payload = try #require(AccountDragToken.decode(token))
            let expectedIDs = selectedIDs.contains(accountID)
                ? Array(accountIDs.prefix(selectedCount)) : [accountID]

            #expect(payload.accountIDs == expectedIDs)
            #expect(!token.contains("@example.com"))
            #expect(!token.contains("drag-fixture-password"))
            #expect(!token.contains("JBSWY3DPEHPK3PXP"))
        }

        let selectedWriters = try (0..<selectedCount).map { offset in
            try #require(pasteboardWriter(for: store.groups.count + 1 + offset, in: table))
        }
        let batchPasteboard = NSPasteboard.withUniqueName()
        defer { batchPasteboard.releaseGlobally() }
        try #require(batchPasteboard.writeObjects(selectedWriters))
        var acceptedIDs: [UUID] = []
        let target = AccountGroupDropView { acceptedIDs = $0.accountIDs; return true }
        let dragging = AccountSidebarDraggingInfo(pasteboard: batchPasteboard, table: table, row: 0)
        #expect(target.draggingEntered(dragging) == .move)
        #expect(target.performDragOperation(dragging))
        #expect(acceptedIDs == Array(accountIDs.prefix(selectedCount)))
    }

    @Test(arguments: [false, true])
    func nativeGroupLabelRejectsInvalidTextAndRequestsMove(toUngrouped: Bool) async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AccountStore(fileURL: directory.appendingPathComponent("accounts.json"))
        try store.merge([
            .init(email: "drag@example.com", password: "fixture", totpSecret: "JBSWY3DPEHPK3PXP"),
        ])
        let group = try store.createGroup(name: "Drop destination", tag: nil)
        let accountID = try #require(store.accounts.first?.id)
        if toUngrouped {
            try store.moveAccounts(ids: [accountID], to: group.id, protectedIDs: [])
        }
        let originalGroupID = store.accounts.first?.groupID
        var requests: [(ids: Set<UUID>, groupID: UUID?)] = []
        let host = NSHostingView(rootView: AccountSidebarDragFixture(
            store: store,
            selection: .group(group.id),
            selectedAccountIDs: [],
            onRequestMoveAccounts: { requests.append(($0, $1)) }))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 480),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }

        let expectedRowCount = toUngrouped ? 2 : 3
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while ContinuousClock.now < deadline {
            host.layoutSubtreeIfNeeded()
            if nativeTable(in: host)?.numberOfRows == expectedRowCount { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let table = try #require(nativeTable(in: host))
        try #require(table.numberOfRows == expectedRowCount)
        let targetRow = toUngrouped ? 1 : 0
        let rowView = try #require(table.rowView(atRow: targetRow, makeIfNecessary: true))
        rowView.layoutSubtreeIfNeeded()
        let target = try #require(groupDropView(in: rowView), "Group label must mount its AppKit drop target")
        #expect(target.registeredDraggedTypes.contains(.string))
        #expect(target.bounds.width > 0 && target.bounds.height > 0)
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let dragging = AccountSidebarDraggingInfo(pasteboard: pasteboard, table: table, row: targetRow)
        try #require(pasteboard.setString("unrelated text", forType: .string))
        #expect(target.draggingEntered(dragging) == [])
        #expect(!target.prepareForDragOperation(dragging))
        #expect(!target.performDragOperation(dragging))
        #expect(requests.isEmpty)

        pasteboard.clearContents()
        let token = AccountDragToken.encode(AccountDragPayload(accountID: accountID))
        try #require(pasteboard.setString(token, forType: .string))
        #expect(target.draggingEntered(dragging) == .move)
        #expect(target.prepareForDragOperation(dragging))
        try #require(target.performDragOperation(dragging))
        try #require(requests.count == 1)
        #expect(requests[0].ids == [accountID])
        #expect(requests[0].groupID == (toUngrouped ? nil : group.id))
        #expect(store.accounts.first?.groupID == originalGroupID, "Drop requests confirmation before changing groups")
    }

    private func nativeTable(in view: NSView) -> NSTableView? {
        if let table = view as? NSTableView { return table }
        return view.subviews.lazy.compactMap { nativeTable(in: $0) }.first
    }

    @Test(arguments: [false, true])
    func groupDropCollectsEveryPasteboardItemOnce(repeatedBatchTokens: Bool) throws {
        let ids = (0..<8).map { _ in UUID() }
        var received: [AccountDragPayload] = []
        let target = AccountGroupDropView { received.append($0); return true }
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let items = ids.map { id in
            let item = NSPasteboardItem()
            let payload = AccountDragPayload(accountIDs: repeatedBatchTokens ? ids : [id])
            item.setString(AccountDragToken.encode(payload), forType: .string)
            return item
        }
        try #require(pasteboard.writeObjects(items))
        let dragging = AccountSidebarDraggingInfo(pasteboard: pasteboard, table: NSTableView(), row: 0)
        #expect(target.draggingEntered(dragging) == .move)
        #expect(target.prepareForDragOperation(dragging))
        #expect(target.performDragOperation(dragging))
        #expect(received == [AccountDragPayload(accountIDs: ids)])
    }

    private func groupDropView(in view: NSView) -> AccountGroupDropView? {
        if let target = view as? AccountGroupDropView { return target }
        return view.subviews.lazy.compactMap { groupDropView(in: $0) }.first
    }

    private func pasteboardWriter(for row: Int, in table: NSTableView) -> (any NSPasteboardWriting)? {
        if let outline = table as? NSOutlineView {
            guard let item = outline.item(atRow: row) else { return nil }
            return outline.dataSource?.outlineView?(outline, pasteboardWriterForItem: item)
        }
        return table.dataSource?.tableView?(table, pasteboardWriterForRow: row)
    }
}
