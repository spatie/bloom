import Foundation
import Testing
@testable import BloomCore

@Suite("Folder terminal")
struct FolderTerminalTests {
    /// A real directory, removed when the test that made it is over.
    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("folder-terminal-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("A folder on disk is offered")
    func offersAFolder() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(FolderTerminal.canOpen(folder: root.path))
    }

    /// The changed file tree draws directories out of a diff, so it lists ones the agent has just
    /// deleted, and a workspace keeps its rows after its worktree is gone.
    @Test("A folder that is not on disk is not offered")
    func refusesAMissingFolder() throws {
        let root = try makeDirectory()
        let gone = root.appendingPathComponent("resources", isDirectory: true).path
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(!FolderTerminal.canOpen(folder: gone))
        #expect(FolderTerminal.target(folder: gone, taken: []) == nil)
    }

    /// A file has no shell to open in, and neither tree offers the item on a file row. This is the
    /// same answer said where it can be tested.
    @Test("A file is not a folder")
    func refusesAFile() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("README.md")
        try Data().write(to: file)

        #expect(!FolderTerminal.canOpen(folder: file.path))
        #expect(FolderTerminal.target(folder: file.path, taken: []) == nil)
    }

    @Test("The tab is named after the folder, not after Terminal")
    func namesAfterTheFolder() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let css = root.appendingPathComponent("resources/css", isDirectory: true)
        try FileManager.default.createDirectory(at: css, withIntermediateDirectories: true)

        let target = FolderTerminal.target(folder: css.path, taken: [])
        #expect(target?.title == "css")
        #expect(target?.directory == css.path)
    }

    /// Two shells in two folders of the same name are numbered apart by the rule every other pane
    /// is numbered by, rather than sitting in the strip as two rows nobody can tell apart.
    @Test("A second tab for a folder of the same name is numbered")
    func numbersASecondOfTheSameName() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let css = root.appendingPathComponent("css", isDirectory: true)
        try FileManager.default.createDirectory(at: css, withIntermediateDirectories: true)

        #expect(FolderTerminal.target(folder: css.path, taken: ["css"])?.title == "css 2")
        #expect(
            FolderTerminal.target(folder: css.path, taken: ["Terminal", "css"])?.title == "css 2"
        )
    }

    @Test("A tab asking for nothing in particular is forked at the worktree root")
    func rootWhenNothingIsAsked() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(FolderTerminal.launchDirectory(requested: "", root: root.path) == root.path)
    }

    @Test("A tab asking for a folder is forked in it")
    func forksInTheFolder() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let css = root.appendingPathComponent("css", isDirectory: true)
        try FileManager.default.createDirectory(at: css, withIntermediateDirectories: true)

        #expect(FolderTerminal.launchDirectory(requested: css.path, root: root.path) == css.path)
    }

    /// The tab outlives the folder: another branch checked out, or a relaunch reading the tab back
    /// out of user defaults. A shell forked into a path that is not there never draws a prompt.
    @Test("A tab whose folder has gone falls back to the worktree root")
    func fallsBackWhenTheFolderGoes() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let css = root.appendingPathComponent("css", isDirectory: true)
        try FileManager.default.createDirectory(at: css, withIntermediateDirectories: true)
        try FileManager.default.removeItem(at: css)

        #expect(FolderTerminal.launchDirectory(requested: css.path, root: root.path) == root.path)
    }
}
