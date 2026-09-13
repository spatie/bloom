import Foundation
import Testing
@testable import BloomCore

struct ServerSkillFolderImportTests {
    @Test("An explicitly selected skill retains relative support files and excludes hidden metadata")
    func readsSelectedFolder() throws {
        try withFolder { folder in
            try Data("# Example".utf8).write(to: folder.appendingPathComponent("SKILL.md"))
            try Data("private".utf8).write(to: folder.appendingPathComponent(".env"))
            try FileManager.default.createDirectory(at: folder.appendingPathComponent("references"), withIntermediateDirectories: false)
            try Data("Reference".utf8).write(to: folder.appendingPathComponent("references/guide.md"))
            let files = try ServerSkillFolderImport.read(folder)
            #expect(files.map(\.path) == ["example/SKILL.md", "example/references/guide.md"])
        }
    }

    @Test("Linked files, linked directories and credential filenames cannot be uploaded", arguments: ["file-link", "directory-link", "auth.json"])
    func rejectsUnsafeEntries(_ kind: String) throws {
        try withFolder { folder in
            try Data("# Example".utf8).write(to: folder.appendingPathComponent("SKILL.md"))
            if kind == "auth.json" { try Data("credential".utf8).write(to: folder.appendingPathComponent(kind)) } else {
                let target = kind == "file-link" ? folder.appendingPathComponent("SKILL.md") : folder.deletingLastPathComponent()
                try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent(kind), withDestinationURL: target)
            }
            #expect(throws: (any Error).self) { try ServerSkillFolderImport.read(folder) }
        }
    }

    @Test("A folder without instructions and an oversized file are rejected", arguments: [false, true])
    func rejectsIncompleteOrOversizedFolder(_ oversized: Bool) throws {
        try withFolder { folder in
            if oversized {
                try Data("# Example".utf8).write(to: folder.appendingPathComponent("SKILL.md"))
                try Data(repeating: 65, count: 1_048_577).write(to: folder.appendingPathComponent("large.txt"))
            }
            #expect(throws: (any Error).self) { try ServerSkillFolderImport.read(folder) }
        }
    }

    private func withFolder(_ operation: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        let folder = root.appendingPathComponent("example")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try operation(folder)
    }
}
