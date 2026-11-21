import Foundation

struct AccountDragPayload: Codable, Equatable, Sendable {
    let accountIDs: [UUID]

    init(accountID: UUID) {
        accountIDs = [accountID]
    }

    init(accountIDs: [UUID]) {
        var seen = Set<UUID>()
        self.accountIDs = accountIDs.filter { seen.insert($0).inserted }
    }

    var accountID: UUID? {
        accountIDs.first
    }

    private enum CodingKeys: String, CodingKey {
        case accountID
        case accountIDs
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let ids = try container.decodeIfPresent([UUID].self, forKey: .accountIDs) {
            self.init(accountIDs: ids)
            return
        }
        if let id = try container.decodeIfPresent(UUID.self, forKey: .accountID) {
            self.init(accountID: id)
            return
        }
        throw DecodingError.dataCorruptedError(
            forKey: .accountIDs,
            in: container,
            debugDescription: "Account drag payload has no account ID")
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if accountIDs.count == 1, let id = accountIDs.first {
            try container.encode(id, forKey: .accountID)
        } else {
            try container.encode(accountIDs, forKey: .accountIDs)
        }
    }
}

enum AccountDragToken {
    private static let prefix = "gpt-account-manager-ids:"

    static func encode(_ payload: AccountDragPayload) -> String {
        prefix + payload.accountIDs.map(\.uuidString).joined(separator: ",")
    }

    static func decode(_ token: String) -> AccountDragPayload? {
        guard token.hasPrefix(prefix) else { return nil }
        let rawIDs = token.dropFirst(prefix.count).split(separator: ",")
        guard !rawIDs.isEmpty else { return nil }

        let ids = rawIDs.compactMap { UUID(uuidString: String($0)) }
        guard ids.count == rawIDs.count else { return nil }
        return AccountDragPayload(accountIDs: ids)
    }
}

enum AccountDragSelection {
    static func effectiveSelectedIDs(
        for rowID: UUID,
        currentIDs: Set<UUID>,
        preservedIDs: Set<UUID>
    ) -> Set<UUID> {
        guard preservedIDs.count > currentIDs.count,
              preservedIDs.contains(rowID) else {
            return currentIDs
        }
        return preservedIDs
    }

    static func ids(
        for rowID: UUID,
        selectedIDs: Set<UUID>,
        orderedIDs: [UUID]
    ) -> [UUID] {
        guard selectedIDs.contains(rowID) else { return [rowID] }

        var result: [UUID] = []
        var seen = Set<UUID>()
        for id in orderedIDs where selectedIDs.contains(id) {
            guard seen.insert(id).inserted else { continue }
            result.append(id)
        }
        if selectedIDs.contains(rowID), seen.insert(rowID).inserted {
            result.append(rowID)
        }
        for id in selectedIDs.sorted(by: { $0.uuidString < $1.uuidString }) {
            guard seen.insert(id).inserted else { continue }
            result.append(id)
        }
        return result.isEmpty ? [rowID] : result
    }

    static func knownIDs(
        from payloads: [AccountDragPayload],
        knownIDs: Set<UUID>
    ) -> Set<UUID> {
        Set(payloads.flatMap(\.accountIDs)).intersection(knownIDs)
    }
}
