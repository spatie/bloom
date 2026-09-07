import Foundation
import Testing
@testable import BloomCore

@Suite(.scratchDirectory)
struct ContainedPathTests {
    @Test func previewAndCopyRefuseTraversalAndExternalSymlinks() throws {
        let root = URL(filePath: TestScratch.unique("containment"), directoryHint: .isDirectory)
        let source = root.appending(path: "source")
        let destination = root.appending(path: "destination")
        let outside = root.appending(path: "outside")
        for directory in [source, destination, outside] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try Data("secret".utf8).write(to: outside.appending(path: "secret.env"))
        try Data("safe".utf8).write(to: source.appending(path: ".env"))
        try FileManager.default.createSymbolicLink(at: source.appending(path: "escape"), withDestinationURL: outside)
        try FileManager.default.createSymbolicLink(at: source.appending(path: "linked.env"), withDestinationURL: outside.appending(path: "secret.env"))
        let patterns = ["../outside/*.env", "escape/*.env", "linked.env", "./.env"]
        let plan = FilesToCopyResolver.resolve(patterns: patterns, in: source.path)
        #expect(plan.matches.map(\.path) == ["./.env"])
        let manager = WorkspaceManager(store: try makeTestStore("contained-copy"))
        try manager.copyFiles(patterns, from: source.path, to: destination.path)
        #expect(try String(contentsOf: destination.appending(path: ".env"), encoding: .utf8) == "safe")
        #expect(!FileManager.default.fileExists(atPath: destination.appending(path: "escape").path))
        #expect(!FileManager.default.fileExists(atPath: destination.appending(path: "linked.env").path))
    }

    @Test func branchControlledDestinationCannotRedirectCopiedSecrets() throws {
        let root = URL(filePath: TestScratch.unique("destination"), directoryHint: .isDirectory)
        let source = root.appending(path: "source")
        let destination = root.appending(path: "destination")
        let outside = root.appending(path: "outside")
        for directory in [source.appending(path: "config"), destination, outside] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try Data("secret".utf8).write(to: source.appending(path: "config/.env"))
        try FileManager.default.createSymbolicLink(at: destination.appending(path: "config"), withDestinationURL: outside)
        let manager = WorkspaceManager(store: try makeTestStore("destination-copy"))
        try manager.copyFiles(["config/.env"], from: source.path, to: destination.path)
        #expect(!FileManager.default.fileExists(atPath: outside.appending(path: ".env").path))
    }

    @Test func localPagesResolveInternalLinksButRefuseExternalOnes() throws {
        let root = URL(filePath: TestScratch.unique("page-links"), directoryHint: .isDirectory)
        let worktree = root.appending(path: "worktree")
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        let page = worktree.appending(path: "page.html")
        try Data("page".utf8).write(to: page)
        let external = root.appending(path: "private.html")
        try Data("private".utf8).write(to: external)
        let link = worktree.appending(path: "linked.html")
        let escape = worktree.appending(path: "escape.html")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: page)
        try FileManager.default.createSymbolicLink(at: escape, withDestinationURL: external)
        #expect(LocalPage.fileURL(from: link.absoluteString, root: worktree.path) == page.resolvingSymlinksInPath())
        #expect(LocalPage.fileURL(from: escape.absoluteString, root: worktree.path) == nil)
    }
}
