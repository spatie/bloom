import Foundation
import Testing
@testable import BloomCore

@Suite("ServerReview", .tags(.git, .security), .scratchDirectory)
struct ServerReviewTests {
    @Test func changedFilePatchAndCurrentContentsComeFromTheServerWorkspace() async throws {
        let fixture = try await ReviewFixture()
        try fixture.repo.write("new.txt", "created on server\n")
        let changed = try await ServerReview.changes(workspace: fixture.workspace, scope: .branch)
        #expect(changed.map(\.path) == ["new.txt"])
        let patch = try await ServerReview.patch(workspace: fixture.workspace, path: "new.txt", scope: .branch)
        #expect(patch.contains("+created on server"))
        let file = try ServerReview.file(workspace: fixture.workspace, path: "new.txt")
        #expect(file.text == "created on server\n")
    }

    @Test func pathspecMagicIsTreatedAsALiteralFilename() async throws {
        let fixture = try await ReviewFixture()
        let path = ":(glob)*.txt"
        try fixture.repo.write(path, "literal file\n")
        try fixture.repo.write("other.txt", "do not include this file\n")
        try await fixture.repo.commit("Add filenames")
        try fixture.repo.write(path, "changed literal file\n")
        try fixture.repo.write("other.txt", "unrelated edit\n")
        let patch = try await ServerReview.patch(workspace: fixture.workspace, path: path, scope: .uncommitted)
        #expect(patch.contains("+changed literal file"))
        #expect(!patch.contains("unrelated edit"))
    }

    @Test func fileReadsRefuseTraversalAndExternalSymlinks() async throws {
        let fixture = try await ReviewFixture()
        let outside = TestScratch.path("outside.txt")
        try Data("private outside contents\n".utf8).write(to: URL(fileURLWithPath: outside))
        try fixture.repo.write("inside.txt", "inside contents\n")
        try FileManager.default.createSymbolicLink(atPath: fixture.repo.path + "/external", withDestinationPath: outside)
        try FileManager.default.createSymbolicLink(atPath: fixture.repo.path + "/internal", withDestinationPath: "inside.txt")
        for path in ["../outside.txt", outside, "external", "nested/../../outside.txt", "\0"] {
            #expect(throws: ServerFailure.self) { _ = try ServerReview.file(workspace: fixture.workspace, path: path) }
        }
        let internalFile = try ServerReview.file(workspace: fixture.workspace, path: "internal")
        #expect(internalFile.text == "inside contents\n")
    }

    @Test func symlinkDiffAndLineCountUseTheLinkInsteadOfItsTargetContents() async throws {
        let fixture = try await ReviewFixture()
        let outside = TestScratch.path("outside.txt")
        try Data("private one\nprivate two\nprivate three\n".utf8).write(to: URL(fileURLWithPath: outside))
        try FileManager.default.createSymbolicLink(atPath: fixture.repo.path + "/link", withDestinationPath: outside)
        let files = try await ServerReview.changes(workspace: fixture.workspace, scope: .branch)
        let link = try #require(files.first(where: { $0.path == "link" }))
        #expect(link.additions == 1)
        let patch = try await ServerReview.patch(workspace: fixture.workspace, path: "link", scope: .branch)
        #expect(!patch.contains("private one"))
        #expect(patch.contains(outside))
    }

    @Test func binaryLargeAndSpecialFilesAreRefusedWithoutBlocking() async throws {
        let fixture = try await ReviewFixture()
        try Data([0, 1, 2]).write(to: URL(fileURLWithPath: fixture.repo.path + "/binary"))
        try Data([0xff, 0xfe]).write(to: URL(fileURLWithPath: fixture.repo.path + "/non-utf8"))
        let large = fixture.repo.path + "/large"
        FileManager.default.createFile(atPath: large, contents: nil)
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: large))
        try handle.truncate(atOffset: UInt64(ServerReview.fileLimit + 1))
        try handle.close()
        let fifo = fixture.repo.path + "/fifo"
        let made = mkfifo(fifo, 0o600)
        #expect(made == 0)
        for path in ["binary", "non-utf8", "large", "fifo"] {
            #expect(throws: ServerFailure.self) { _ = try ServerReview.file(workspace: fixture.workspace, path: path) }
        }
    }

    @Test func renamedAndDeletedFilesCanStillBeReviewed() async throws {
        let fixture = try await ReviewFixture()
        try fixture.repo.write("old.txt", "keep this content\n")
        try fixture.repo.write("deleted.txt", "remove this content\n")
        try await fixture.repo.commit("Add original files")
        try FileManager.default.moveItem(atPath: fixture.repo.path + "/old.txt", toPath: fixture.repo.path + "/renamed.txt")
        try FileManager.default.removeItem(atPath: fixture.repo.path + "/deleted.txt")
        _ = try await Shell.run("git", ["add", "-A"], cwd: fixture.repo.path)
        let rename = try await ServerReview.patch(workspace: fixture.workspace, path: "renamed.txt", scope: .uncommitted)
        #expect(rename.contains("rename from old.txt"))
        #expect(rename.contains("rename to renamed.txt"))
        let deletion = try await ServerReview.patch(workspace: fixture.workspace, path: "deleted.txt", scope: .uncommitted)
        #expect(deletion.contains("-remove this content"))
    }

    @Test func unchangedOrForgedPathsCannotBeRequestedAsDiffs() async throws {
        let fixture = try await ReviewFixture()
        for path in ["README.md", "../outside", "/etc/passwd"] {
            do {
                _ = try await ServerReview.patch(workspace: fixture.workspace, path: path, scope: .branch)
                Issue.record("Accepted a path that was not a changed workspace file")
            } catch { #expect(error is ServerFailure) }
        }
    }

    @Test func emptyUntrackedTextIsNotBinary() async throws {
        let fixture = try await ReviewFixture()
        try fixture.repo.write("empty", "")
        let files = try await ServerReview.changes(workspace: fixture.workspace, scope: .branch)
        let empty = try #require(files.first(where: { $0.path == "empty" }))
        #expect(empty.additions == 0)
        #expect(!empty.isBinary)
    }
}

private struct ReviewFixture {
    let repo: TempRepo
    let workspace: Workspace

    init() async throws {
        repo = try await TempRepo()
        workspace = Workspace(repoID: .new(), name: "Review", branch: "main", path: repo.path, baseBranch: "main")
    }
}
