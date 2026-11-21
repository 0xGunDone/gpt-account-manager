import Foundation

struct AccountGroup: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var name: String
    var tag: String?

    init(id: UUID = UUID(), name: String, tag: String? = nil) {
        self.id = id
        self.name = name
        self.tag = tag
    }
}

struct PersistedAccountData: Codable, Equatable, Sendable {
    static let currentVersion = 2

    var version: Int
    var groups: [AccountGroup]
    var accounts: [AccountRecord]
    var emailAliases: [EmailAlias]
    var deletedAccounts: [DeletedAccountSnapshot]

    init(
        version: Int = PersistedAccountData.currentVersion,
        groups: [AccountGroup],
        accounts: [AccountRecord],
        emailAliases: [EmailAlias] = [],
        deletedAccounts: [DeletedAccountSnapshot] = []
    ) {
        self.version = version
        self.groups = groups
        self.accounts = accounts
        self.emailAliases = emailAliases
        self.deletedAccounts = deletedAccounts
    }

    private enum CodingKeys: String, CodingKey {
        case version, groups, accounts, emailAliases, deletedAccounts
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decode(Int.self, forKey: .version)
        groups = try values.decode([AccountGroup].self, forKey: .groups)
        accounts = try values.decode([AccountRecord].self, forKey: .accounts)
        emailAliases = try values.decodeIfPresent([EmailAlias].self, forKey: .emailAliases) ?? []
        deletedAccounts = try values.decodeIfPresent([DeletedAccountSnapshot].self, forKey: .deletedAccounts) ?? []
    }
}
