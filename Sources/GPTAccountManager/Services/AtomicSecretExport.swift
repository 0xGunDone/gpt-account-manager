import Foundation

enum AtomicSecretExport {
    enum ExportError: Error, LocalizedError {
        case unsafeDestination
        var errorDescription: String? { "Выберите обычный файл вне папки данных приложения." }
    }

    static func write(_ data: Data, to url: URL, excluding directory: URL) throws {
        let manager = FileManager.default
        let parent = url.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
        let protected = directory.resolvingSymlinksInPath().standardizedFileURL.path
        guard url.isFileURL, !url.lastPathComponent.isEmpty,
              parent.path != protected, !parent.path.hasPrefix(protected + "/") else { throw ExportError.unsafeDestination }
        let destination = parent.appendingPathComponent(url.lastPathComponent)
        if (try? destination.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
            throw ExportError.unsafeDestination
        }
        if manager.fileExists(atPath: destination.path) {
            guard try destination.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
                throw ExportError.unsafeDestination
            }
        }
        let temporary = parent.appendingPathComponent(".account-export-\(UUID().uuidString).tmp")
        guard manager.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        defer { try? manager.removeItem(at: temporary) }
        let handle = try FileHandle(forWritingTo: temporary)
        do { try handle.write(contentsOf: data); try handle.synchronize(); try handle.close() }
        catch { try? handle.close(); throw error }
        if manager.fileExists(atPath: destination.path) {
            _ = try manager.replaceItemAt(destination, withItemAt: temporary, options: [.usingNewMetadataOnly])
        } else { try manager.moveItem(at: temporary, to: destination) }
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
    }

    static func writeDirectory(documents: [Data], in folder: URL, excluding directory: URL) throws -> URL {
        guard folder.isFileURL, !documents.isEmpty else { throw ExportError.unsafeDestination }
        let parent = folder.resolvingSymlinksInPath().standardizedFileURL
        let protected = directory.resolvingSymlinksInPath().standardizedFileURL.path
        guard parent.path != protected, !parent.path.hasPrefix(protected + "/") else { throw ExportError.unsafeDestination }
        let manager = FileManager.default
        let temporary = parent.appendingPathComponent(".cpa-export-\(UUID().uuidString)")
        let destination = parent.appendingPathComponent("chatgpt-cpa-\(UUID().uuidString)")
        try manager.createDirectory(at: temporary, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? manager.removeItem(at: temporary) }
        for (index, data) in documents.enumerated() {
            try write(data, to: temporary.appendingPathComponent("codex-\(index + 1).json"), excluding: directory)
        }
        try manager.moveItem(at: temporary, to: destination)
        return destination
    }
}
