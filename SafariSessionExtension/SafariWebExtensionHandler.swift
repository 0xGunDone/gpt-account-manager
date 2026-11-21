import Darwin
import SafariServices

final class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {
    func beginRequest(with context: NSExtensionContext) {
        let item = context.inputItems.first as? NSExtensionItem
        let message = item?.userInfo?[SFExtensionMessageKey] as? [String: String]
        let accepted = message?["type"] == "claim" && message?.count == 2 &&
            message?["requestId"].flatMap(UUID.init(uuidString:)).map(Self.claim) == true

        let reply = NSExtensionItem()
        reply.userInfo = [SFExtensionMessageKey: ["accepted": accepted]]
        context.completeRequest(returningItems: [reply], completionHandler: nil)
    }

    private static func claim(_ requestID: UUID) -> Bool {
        let fileManager = FileManager.default
        guard let support = try? fileManager.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        ) else { return false }
        return claim(requestID, in: support.appendingPathComponent("SafariSessionClaims", isDirectory: true))
    }

    static func claim(_ requestID: UUID, in directory: URL) -> Bool {
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(
                at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } catch {
            return false
        }

        let marker = directory.appendingPathComponent(requestID.uuidString)
        let descriptor = Darwin.open(
            marker.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { return false }
        Darwin.close(descriptor)

        let expired = Date().addingTimeInterval(-300)
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .isRegularFileKey]
        if let markers = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys)) {
            for marker in markers {
                guard UUID(uuidString: marker.lastPathComponent) != nil,
                      let properties = try? marker.resourceValues(forKeys: keys),
                      properties.isRegularFile == true,
                      let modified = properties.contentModificationDate, modified < expired else { continue }
                try? fileManager.removeItem(at: marker)
            }
        }
        return true
    }
}
