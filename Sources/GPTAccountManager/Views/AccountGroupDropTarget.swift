import AppKit
import SwiftUI

/// Register the group label itself as an AppKit destination inside List's outline view.
struct AccountGroupDropTarget: NSViewRepresentable {
    let onDrop: (AccountDragPayload) -> Bool

    func makeNSView(context: Context) -> AccountGroupDropView {
        AccountGroupDropView(onDrop: onDrop)
    }

    func updateNSView(_ view: AccountGroupDropView, context: Context) {
        view.onDrop = onDrop
    }
}

final class AccountGroupDropView: NSView {
    var onDrop: (AccountDragPayload) -> Bool

    init(onDrop: @escaping (AccountDragPayload) -> Bool) {
        self.onDrop = onDrop
        super.init(frame: .zero)
        registerForDraggedTypes([.string])
        wantsLayer = true
        layer?.cornerRadius = 6
    }

    required init?(coder: NSCoder) { nil }

    override func mouseDown(with event: NSEvent) {
        nextResponder?.mouseDown(with: event)
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        let accepted = payload(from: sender) != nil
        layer?.backgroundColor = accepted ? NSColor.controlAccentColor.withAlphaComponent(0.2).cgColor : nil
        return accepted ? .move : []
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        draggingEntered(sender)
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        layer?.backgroundColor = nil
    }

    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        payload(from: sender) != nil
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        layer?.backgroundColor = nil
        guard let payload = payload(from: sender) else { return false }
        return onDrop(payload)
    }

    private func payload(from sender: any NSDraggingInfo) -> AccountDragPayload? {
        // NSPasteboard.string joins multiple row items, which is not a single account token.
        let tokens = (sender.draggingPasteboard.pasteboardItems ?? []).compactMap {
            $0.string(forType: .string)
        }
        guard !tokens.isEmpty else { return nil }
        var ids: [UUID] = []
        for token in tokens {
            guard let payload = AccountDragToken.decode(token) else { return nil }
            ids.append(contentsOf: payload.accountIDs)
        }
        return AccountDragPayload(accountIDs: ids)
    }
}
