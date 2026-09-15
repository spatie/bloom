import Foundation
import Testing
@testable import BloomCore

/// Whether the owner's token is being presented from inside a workspace.
///
/// Pure paths, because the decision is. The two facts it is handed come from the kernel and the
/// store in `BridgeServer.handshake`, and what is pinned here is the part that is easy to get
/// subtly wrong: a prefix match that takes `/a/bc` for a directory inside `/a/b`.
@Suite("BridgeOwnerPlacement")
struct BridgeOwnerPlacementTests {
    private let repo = Repo(name: "bloom", path: "/Users/someone/code/bloom")

    private func workspace(_ name: String, at path: String, archived: Bool = false) -> Workspace {
        var workspace = Workspace(
            repoID: repo.id, name: name, branch: "bloom/\(name)", path: path, baseBranch: "main"
        )
        if archived { workspace.archive() }
        return workspace
    }

    private var live: [Workspace] {
        [
            workspace("bothnian-sea", at: "/Users/someone/bloom/workspaces/bothnian-sea"),
            workspace("baltic", at: "/Users/someone/bloom/workspaces/baltic/"),
        ]
    }

    @Test("a directory inside a live workspace is refused, and the sentence names the workspace", arguments: [
        "/Users/someone/bloom/workspaces/bothnian-sea/Sources/BloomCore",
        "/Users/someone/bloom/workspaces/bothnian-sea",
        "/Users/someone/bloom/workspaces/bothnian-sea/",
        "/Users/someone/bloom/workspaces/bothnian-sea/./Tests",
    ])
    func insideIsRefused(_ directory: String) throws {
        let refusal = try #require(BridgeOwnerPlacement.refusal(workingDirectory: directory, workspaces: live))
        #expect(refusal.contains("'bothnian-sea'"))
        #expect(refusal.contains("/Users/someone/bloom/workspaces/bothnian-sea"))
        #expect(refusal.contains("outside Bloom's workspaces"))
    }

    /// The workspace row carrying the trailing slash rather than the directory.
    @Test("a trailing slash on the workspace's own path makes no difference")
    func trailingSlashOnTheRow() throws {
        let refusal = BridgeOwnerPlacement.refusal(
            workingDirectory: "/Users/someone/bloom/workspaces/baltic", workspaces: live
        )
        #expect(try #require(refusal).contains("'baltic'"))
        #expect(BridgeOwnerPlacement.refusal(
            workingDirectory: "/Users/someone/bloom/workspaces/baltic/src", workspaces: live
        ) != nil)
    }

    @Test("a directory in no workspace is let through", arguments: [
        // A sibling whose name only begins with a workspace's.
        "/Users/someone/bloom/workspaces/bothnian-sea-2",
        "/Users/someone/bloom/workspaces/balticsea/src",
        // The directory holding the workspaces, and one above it.
        "/Users/someone/bloom/workspaces",
        "/Users/someone",
        // Where Ask Bloom's shim runs, which really is the owner.
        "/Users/someone/Library/Application Support/Bloom/Ask",
        "/",
    ])
    func outsideIsLetThrough(_ directory: String) {
        #expect(BridgeOwnerPlacement.refusal(workingDirectory: directory, workspaces: live) == nil)
    }

    /// Failing to read where a caller is, is not evidence that it is somewhere it should not be.
    @Test("no directory at all is let through")
    func unreadableDirectory() {
        #expect(BridgeOwnerPlacement.refusal(workingDirectory: nil, workspaces: live) == nil)
        #expect(BridgeOwnerPlacement.refusal(workingDirectory: "", workspaces: live) == nil)
    }

    /// Its worktree is gone, so whatever now sits at that path is not a workspace.
    @Test("an archived workspace never refuses")
    func archivedIsIgnored() {
        let archived = [workspace("old", at: "/Users/someone/bloom/workspaces/old", archived: true)]
        #expect(BridgeOwnerPlacement.refusal(
            workingDirectory: "/Users/someone/bloom/workspaces/old/src", workspaces: archived
        ) == nil)
    }

    /// An empty path standardises to nothing, and a prefix of nothing would match every directory.
    @Test("a workspace with no path never refuses")
    func emptyPathIsIgnored() {
        let pathless = [workspace("nowhere", at: "")]
        for directory in ["/", "/Users/someone", "/tmp/anything"] {
            #expect(BridgeOwnerPlacement.refusal(workingDirectory: directory, workspaces: pathless) == nil)
        }
    }

    @Test("with no workspaces at all, nothing is refused")
    func noWorkspaces() {
        #expect(BridgeOwnerPlacement.refusal(workingDirectory: "/Users/someone", workspaces: []) == nil)
    }
}
