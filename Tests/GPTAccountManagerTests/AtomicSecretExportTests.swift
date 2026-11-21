import Foundation
import Testing
@testable import GPTAccountManager

@Suite struct AtomicSecretExportTests {
    @Test func writesPrivateFileAndRejectsInternalDataSymlinkAndDirectory() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? manager.removeItem(at: root) }
        let protected = root.appendingPathComponent("private")
        try manager.createDirectory(at: protected, withIntermediateDirectories: true)
        let output = root.appendingPathComponent("export.json")
        try AtomicSecretExport.write(Data("fixture".utf8), to: output, excluding: protected)
        #expect(try Data(contentsOf: output) == Data("fixture".utf8))
        #expect((try manager.attributesOfItem(atPath: output.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        try AtomicSecretExport.write(Data("replacement".utf8), to: output, excluding: protected)
        #expect(try Data(contentsOf: output) == Data("replacement".utf8))
        let link = root.appendingPathComponent("link")
        try manager.createSymbolicLink(at: link, withDestinationURL: output)
        for target in [link, protected, protected.appendingPathComponent("accounts.json")] {
            #expect(throws: (any Error).self) { try AtomicSecretExport.write(Data("bad".utf8), to: target, excluding: protected) }
        }
        #expect(try Data(contentsOf: output) == Data("replacement".utf8))
    }

    @Test func cpaDocumentsPublishTogetherInNewPrivateFolder() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? manager.removeItem(at: root) }
        let protected = root.appendingPathComponent("private")
        try manager.createDirectory(at: protected, withIntermediateDirectories: true)
        let documents = [Data("{\"fixture\":1}".utf8), Data("{\"fixture\":2}".utf8)]
        let folder = try AtomicSecretExport.writeDirectory(documents: documents, in: root, excluding: protected)
        #expect((try manager.attributesOfItem(atPath: folder.path)[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        for (index, data) in documents.enumerated() {
            let file = folder.appendingPathComponent("codex-\(index + 1).json")
            #expect(try Data(contentsOf: file) == data)
            #expect((try manager.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        }
        #expect(throws: (any Error).self) { try AtomicSecretExport.writeDirectory(documents: documents, in: protected, excluding: protected) }
        #expect(throws: (any Error).self) { try AtomicSecretExport.writeDirectory(documents: [], in: root, excluding: protected) }
    }
}
