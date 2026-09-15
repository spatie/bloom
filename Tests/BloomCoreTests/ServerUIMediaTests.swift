import Foundation
import Testing
@testable import BloomCore

@Suite("Remote media containment", .scratchDirectory)
struct ServerUIMediaTests {
    @Test func tempImageCannotBeMistakenForAnUnrelatedWorkspaceBasename() throws {
        let root = TestScratch.unique("media-root"), outside = TestScratch.unique("media-outside")
        for path in [root, outside] { try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true) }
        for path in [root, outside] { try Data([1, 2, 3]).write(to: URL(fileURLWithPath: path + "/screenshot.png")) }
        let workspace = Workspace(repoID: RepoID("fixture"), name: "Fixture", branch: "feature", path: root, baseBranch: "main")
        #expect(ServerUIBridgeTools.containedMedia(path: outside + "/screenshot.png", workspace: workspace) == nil)
        #expect(ServerUIBridgeTools.containedMedia(path: root + "/screenshot.png", workspace: workspace)?.relativePath == "screenshot.png")
        #expect(ServerUIBridgeTools.containedMedia(path: "screenshot.png", workspace: workspace)?.relativePath == "screenshot.png")
        try FileManager.default.createSymbolicLink(atPath: root + "/escaped.png", withDestinationPath: outside + "/screenshot.png")
        #expect(ServerUIBridgeTools.containedMedia(path: "escaped.png", workspace: workspace) == nil)
    }
}
