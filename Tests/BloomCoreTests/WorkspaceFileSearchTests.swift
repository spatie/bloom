import Foundation
import Testing
@testable import BloomCore

@Suite(.scratchDirectory) struct WorkspaceFileSearchTests {
    @Test func listsTrackedAndUntrackedFilesWithoutIgnoredFilesOrQuotedPaths() async throws {
        let root = TestScratch.unique("file-search")
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        _ = try await Shell.run("git", ["init", "-q"], cwd: root)
        let tracked = ["README.md", "file with spaces.txt", "café.txt", "two\nlines.txt"]
        for path in tracked {
            try Data("hello".utf8).write(to: URL(fileURLWithPath: root).appendingPathComponent(path))
        }
        _ = try await Shell.run("git", ["add", "."], cwd: root)
        try Data("ignored.txt\n".utf8).write(to: URL(fileURLWithPath: root + "/.gitignore"))
        for path in ["new.txt", "ignored.txt"] {
            try Data().write(to: URL(fileURLWithPath: root + "/" + path))
        }
        let paths = try await WorkspaceFileSearch.paths(in: root)
        #expect(paths == (tracked + [".gitignore", "new.txt"]).sorted())
        #expect(FileMatch.search(paths, query: "café", limit: 100).first?.path == "café.txt")
    }

    @Test func fileSearchHasItsOwnWorkspaceShortcut() {
        let item = MenuBarCatalogue[.searchFiles]
        #expect(item.key == .command("p"))
        #expect(item.menu == .file)
        #expect(item.availability == .needsWorkspace)
    }
}
