import Foundation

struct DeletedAccountSnapshot: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var account: AccountRecord
    var group: AccountGroup?
    var deletedAt: Date

    init(id: UUID = UUID(), account: AccountRecord, group: AccountGroup? = nil, deletedAt: Date = Date()) {
        self.id = id
        self.account = account
        self.group = group
        self.deletedAt = deletedAt
    }
}
