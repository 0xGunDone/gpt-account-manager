import Foundation

enum SidebarSelection: Hashable {
    case account(UUID)
    case group(UUID)
    case ungrouped
}

enum SidebarSelectionSynchronization {
    static func selectedID(for selection: SidebarSelection?) -> UUID? {
        guard case .account(let id) = selection else { return nil }
        return id
    }

    static func sidebarSelection(
        for selectedID: UUID?,
        preserving selection: SidebarSelection?
    ) -> SidebarSelection? {
        guard let selectedID else { return selection }
        return .account(selectedID)
    }
}

enum SidebarAccountSelection {
    static func normalized(_ selections: Set<SidebarSelection>) -> Set<UUID> {
        Set(selections.compactMap { selection in
            guard case .account(let id) = selection else { return nil }
            return id
        })
    }

    static func normalizedRows(_ selections: Set<SidebarSelection>) -> Set<SidebarSelection> {
        if let group = selections
            .compactMap({ selection -> UUID? in
                guard case .group(let id) = selection else { return nil }
                return id
            })
            .sorted(by: { $0.uuidString < $1.uuidString })
            .first {
            return [.group(group)]
        }
        if selections.contains(.ungrouped) {
            return [.ungrouped]
        }
        return Set(selections.filter { selection in
            if case .account = selection { return true }
            return false
        })
    }

    static func navigationSelection(
        for selections: Set<SidebarSelection>,
        preserving selection: SidebarSelection?
    ) -> SidebarSelection? {
        navigationSelection(
            for: selections,
            previousSelections: [],
            preserving: selection,
            orderedAccountIDs: [])
    }

    static func navigationSelection(
        for selections: Set<SidebarSelection>,
        previousSelections: Set<SidebarSelection>,
        preserving selection: SidebarSelection?,
        orderedAccountIDs: [UUID]
    ) -> SidebarSelection? {
        let rows = normalizedRows(selections)
        if let category = rows.first(where: { row in
            switch row {
            case .group, .ungrouped: return true
            case .account: return false
            }
        }) {
            return category
        }

        let currentAccountIDs = normalized(rows)
        let previousAccountIDs = normalized(previousSelections)
        let addedIDs = orderedAccountIDs.filter {
            currentAccountIDs.contains($0) && !previousAccountIDs.contains($0)
        }
        if !addedIDs.isEmpty {
            if case .account(let anchorID) = selection,
               previousAccountIDs.contains(anchorID),
               let anchorIndex = orderedAccountIDs.firstIndex(of: anchorID),
               let firstAddedIndex = orderedAccountIDs.firstIndex(of: addedIDs[0]),
               let lastAddedIndex = orderedAccountIDs.firstIndex(of: addedIDs[addedIDs.count - 1]) {
                let firstDistance = abs(firstAddedIndex - anchorIndex)
                let lastDistance = abs(lastAddedIndex - anchorIndex)
                let clickedID = firstDistance >= lastDistance
                    ? addedIDs[0]
                    : addedIDs[addedIDs.count - 1]
                return .account(clickedID)
            }
            return .account(addedIDs[addedIDs.count - 1])
        }

        if let selection,
           case .account(let id) = selection,
           rows.contains(.account(id)) {
            return selection
        }

        return rows
            .compactMap { row -> UUID? in
                guard case .account(let id) = row else { return nil }
                return id
            }
            .sorted(by: { $0.uuidString < $1.uuidString })
            .first
            .map(SidebarSelection.account)
    }
}
