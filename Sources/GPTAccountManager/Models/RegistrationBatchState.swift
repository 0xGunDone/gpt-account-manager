import Foundation

/// Queue metadata only. Credentials and registration proof stay in AccountStore.
struct RegistrationBatchState: Codable, Equatable {
    var version = 1
    var totalCount: Int
    var completedCount: Int
    var remainingEmails: [String]
    var batchAccountID: UUID?
    var blockedAccountIDs: [UUID]?
    var skippedAccountIDs: [UUID]?
    var removedBlockedAccountIDs: [UUID]?

    static func fileURL(for accountsURL: URL) -> URL {
        accountsURL.deletingPathExtension().appendingPathExtension("registration-batch.json")
    }

    func validate() throws {
        guard version == 1, totalCount >= 0, completedCount >= 0,
              completedCount <= totalCount,
              remainingEmails.count + (blockedAccountIDs?.count ?? 0) + (skippedAccountIDs?.count ?? 0) == totalCount - completedCount,
              Set(blockedAccountIDs ?? []).count == (blockedAccountIDs?.count ?? 0),
              Set(skippedAccountIDs ?? []).count == (skippedAccountIDs?.count ?? 0),
              Set(removedBlockedAccountIDs ?? []).count == (removedBlockedAccountIDs?.count ?? 0),
              Set(removedBlockedAccountIDs ?? []).isSubset(of: Set(blockedAccountIDs ?? [])),
              Set(skippedAccountIDs ?? []).isDisjoint(with: blockedAccountIDs ?? []),
              batchAccountID.map({ !(blockedAccountIDs ?? []).contains($0) }) ?? true,
              batchAccountID.map({ !(skippedAccountIDs ?? []).contains($0) }) ?? true,
              batchAccountID == nil || !remainingEmails.isEmpty,
              remainingEmails.allSatisfy({ MailVerificationMatcher.normalizedAddress($0) == $0 }),
              Set(remainingEmails).count == remainingEmails.count
        else { throw RegistrationBatchError.invalidSavedBatch }
    }

    func save(to url: URL) throws {
        try validate()
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        if manager.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
            throw AccountStoreError.temporaryFileCreationFailed
        }
        let directory = url.deletingLastPathComponent()
        try manager.createDirectory(at: directory, withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let temporary = directory.appendingPathComponent(".registration-batch-\(UUID().uuidString).tmp")
        guard manager.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600])
        else { throw AccountStoreError.temporaryFileCreationFailed }
        defer { try? manager.removeItem(at: temporary) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let handle = try FileHandle(forWritingTo: temporary)
        do {
            try handle.write(contentsOf: encoder.encode(self))
            try handle.synchronize()
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }
        if manager.fileExists(atPath: url.path) {
            _ = try manager.replaceItemAt(url, withItemAt: temporary, options: [.usingNewMetadataOnly])
        } else {
            try manager.moveItem(at: temporary, to: url)
        }
        guard (try manager.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600,
              (try manager.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber)?.intValue == 0o700
        else { throw AccountStoreError.insecurePermissions }
    }
}
