import Foundation
import Testing
@testable import BloomCore

@Suite("Workspace file descriptor confinement", .scratchDirectory)
struct WorkspaceFileAccessTests {
    private func fixture() throws -> (Workspace, String) {
        let root = TestScratch.unique("workspace"), outside = TestScratch.unique("outside")
        for path in [root + "/nested", outside] { try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true) }
        try Data("inside".utf8).write(to: URL(fileURLWithPath: root + "/nested/value.txt"))
        try Data("outside secret".utf8).write(to: URL(fileURLWithPath: outside + "/value.txt"))
        return (Workspace(repoID: .new(), name: "Fixture", branch: "main", path: root, baseBranch: "main"), outside)
    }

    @Test func replacingACheckedDirectoryWithASymlinkCannotRedirectReadOrWrite() throws {
        let (workspace, outside) = try fixture()
        let file = try WorkspaceFileAccess(workspace: workspace, path: "nested/value.txt")
        try FileManager.default.moveItem(atPath: workspace.path + "/nested", toPath: workspace.path + "/original")
        try FileManager.default.createSymbolicLink(atPath: workspace.path + "/nested", withDestinationPath: outside)
        #expect(try file.read(limit: 1024) == Data("inside".utf8))
        try file.replace(Data("updated".utf8), expectedRevision: ServerFileOperations.revision(Data("inside".utf8)), limit: 1024)
        #expect(try Data(contentsOf: URL(fileURLWithPath: outside + "/value.txt")) == Data("outside secret".utf8))
        #expect(try Data(contentsOf: URL(fileURLWithPath: workspace.path + "/original/value.txt")) == Data("updated".utf8))
        #expect(throws: ServerFailure.self) { _ = try ServerFileOperations.download(workspace: workspace, path: "nested/value.txt") }
    }

    @Test func replacingTheLastComponentWithASymlinkIsRefused() throws {
        let (workspace, outside) = try fixture()
        let file = try WorkspaceFileAccess(workspace: workspace, path: "nested/value.txt")
        try FileManager.default.removeItem(atPath: workspace.path + "/nested/value.txt")
        try FileManager.default.createSymbolicLink(atPath: workspace.path + "/nested/value.txt", withDestinationPath: outside + "/value.txt")
        #expect(throws: ServerFailure.self) { _ = try file.read(limit: 1024) }
        #expect(throws: ServerFailure.self) { try file.replace(Data("bad".utf8), expectedRevision: "unused", limit: 1024) }
        #expect(try Data(contentsOf: URL(fileURLWithPath: outside + "/value.txt")) == Data("outside secret".utf8))
    }

    @Test func uploadsAndTheirGitignoreCannotFollowASwappedScratchDirectory() throws {
        let (workspace, outside) = try fixture()
        let upload = try WorkspaceFileAccess(workspace: workspace, path: ".bloom/attachments/fixture/file.txt", creatingParents: true)
        try FileManager.default.moveItem(atPath: workspace.path + "/.bloom", toPath: workspace.path + "/original-scratch")
        try FileManager.default.createSymbolicLink(atPath: workspace.path + "/.bloom", withDestinationPath: outside)
        try upload.create(Data("upload".utf8))
        #expect(try Data(contentsOf: URL(fileURLWithPath: workspace.path + "/original-scratch/attachments/fixture/file.txt")) == Data("upload".utf8))
        #expect(!FileManager.default.fileExists(atPath: outside + "/attachments"))
        #expect(throws: ServerFailure.self) { _ = try ServerFileOperations.upload(workspace: workspace, name: "new.txt", data: Data()) }
        #expect(!FileManager.default.fileExists(atPath: outside + "/attachments/.gitignore"))
    }

    @Test func anExistingSymlinkCannotBeAcceptedAsTheScratchShield() throws {
        let (workspace, outside) = try fixture()
        try FileManager.default.createDirectory(atPath: workspace.path + "/.bloom/attachments", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: workspace.path + "/.bloom/attachments/.gitignore", withDestinationPath: outside + "/value.txt")
        #expect(throws: ServerFailure.self) { _ = try ServerFileOperations.upload(workspace: workspace, name: "new.txt", data: Data()) }
        #expect(try Data(contentsOf: URL(fileURLWithPath: outside + "/value.txt")) == Data("outside secret".utf8))
    }

    @Test func concurrentSavesCannotBothReplaceTheSameRevision() async throws {
        let (workspace, _) = try fixture()
        let revision = try ServerReview.file(workspace: workspace, path: "nested/value.txt").revision
        let gate = FileSaveGate()
        let successes = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
            for text in ["first save", "second save"] {
                group.addTask {
                    await gate.arrive()
                    do {
                        _ = try ServerFileOperations.write(workspace: workspace, path: "nested/value.txt", text: text, revision: revision)
                        return true
                    } catch { return false }
                }
            }
            var successes = 0
            for await saved in group where saved { successes += 1 }
            return successes
        }
        #expect(successes == 1)
        let final = try ServerReview.file(workspace: workspace, path: "nested/value.txt").text
        #expect(["first save", "second save"].contains(final))
    }
}

private actor FileSaveGate {
    private var first: CheckedContinuation<Void, Never>?
    private var count = 0
    func arrive() async {
        count += 1
        if count == 2 { first?.resume(); first = nil; return }
        await withCheckedContinuation { first = $0 }
    }
}
