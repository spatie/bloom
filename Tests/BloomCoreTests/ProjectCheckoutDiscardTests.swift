import Foundation
import Testing
@testable import BloomCore

@Suite("Project checkout Discard", .tags(.git, .destructive), .scratchDirectory)
struct ProjectCheckoutDiscardTests {
    private func workspace(in repo: TempRepo) -> Workspace {
        Workspace(
            repoID: RepoID("project"), name: "Project checkout", branch: "main", path: repo.path,
            baseBranch: "main", kind: .projectCheckout
        )
    }

    @Test("Review and Discard follow HEAD without waiting for the stored branch", arguments: [false, true])
    func followsCheckout(detached: Bool) async throws {
        let repo = try await TempRepo()
        defer { repo.cleanUp() }
        let workspace = workspace(in: repo)
        try await Shell.check("git", ["checkout", "-b", "feature"], cwd: repo.path)
        try repo.write("feature.txt", "committed feature\n")
        try await repo.commit("Feature")
        if detached { try await Shell.check("git", ["checkout", "--detach"], cwd: repo.path) }

        #expect(workspace.reviewBase == "HEAD")
        #expect(workspace.with { $0.kind = .worktree }.reviewBase == "main")
        #expect(try await Git.changedFiles(worktree: repo.path, base: workspace.reviewBase).isEmpty)
        try repo.write("feature.txt", "uncommitted edit\n")
        let files = try await Git.changedFiles(worktree: repo.path, base: workspace.reviewBase)
        let file = try #require(files.first)
        #expect(files.count == 1)
        #expect(file.change == .modified)
        #expect(file.reviewRevision == (try await Git.headSHA(of: repo.path)))
        let patch = try await Git.patch(worktree: repo.path, base: workspace.reviewBase, file: file)
        #expect(patch.contains("-committed feature"))
        #expect(patch.contains("+uncommitted edit"))
        try await Git.revertTrackedFile(file, worktree: repo.path, base: workspace.reviewBase)
        #expect(repo.read("feature.txt") == "committed feature\n")
        #expect(try await Git.changedFiles(worktree: repo.path, base: workspace.reviewBase).isEmpty)
    }

    @Test("A retained added row cannot delete a file that has since been committed")
    func committedAddition() async throws {
        let repo = try await TempRepo()
        defer { repo.cleanUp() }
        try repo.write("new.txt", "keep this commit\n")
        try await Shell.check("git", ["add", "new.txt"], cwd: repo.path)
        let file = try #require(try await Git.changedFiles(worktree: repo.path, base: "HEAD").first)
        #expect(file.change == .added)
        try await repo.commit("Keep addition")

        await #expect(throws: FileRevertRefusal.self) {
            try await Git.revertTrackedFile(file, worktree: repo.path, base: "HEAD")
        }
        #expect(repo.read("new.txt") == "keep this commit\n")
        #expect(try await Git.changedFiles(worktree: repo.path, base: "HEAD").isEmpty)
    }

    @Test("A retained rename cannot remove the committed destination or resurrect its old name")
    func committedRename() async throws {
        let repo = try await TempRepo()
        defer { repo.cleanUp() }
        try repo.write("old.txt", "keep this file\n")
        try await repo.commit("Original")
        try await Shell.check("git", ["mv", "old.txt", "new.txt"], cwd: repo.path)
        let file = try #require(try await Git.changedFiles(worktree: repo.path, base: "HEAD").first)
        #expect(file.change == .renamed)
        try await repo.commit("Rename")

        await #expect(throws: FileRevertRefusal.self) {
            try await Git.revertTrackedFile(file, worktree: repo.path, base: "HEAD")
        }
        #expect(repo.read("new.txt") == "keep this file\n")
        #expect(!repo.exists("old.txt"))
        #expect(try await Git.changedFiles(worktree: repo.path, base: "HEAD").isEmpty)
    }

    @Test("An untracked row cannot be trashed after the file enters the index")
    func newlyTrackedFile() async throws {
        let repo = try await TempRepo()
        defer { repo.cleanUp() }
        try repo.write("new.txt", "keep staged work\n")
        let file = try #require(try await Git.changedFiles(worktree: repo.path, base: "HEAD").first)
        #expect(file.change == .untracked)
        try await Shell.check("git", ["add", "new.txt"], cwd: repo.path)

        await #expect(throws: FileRevertRefusal.self) {
            try await Git.validateRevertTarget(file, worktree: repo.path)
        }
        #expect(repo.read("new.txt") == "keep staged work\n")
        let staged = try await Shell.check("git", ["show", ":new.txt"], cwd: repo.path)
        #expect(staged.stdout == "keep staged work\n")
    }

    @Test("A retained hunk cannot reverse work that has since been committed")
    func committedHunk() async throws {
        let repo = try await TempRepo()
        defer { repo.cleanUp() }
        try repo.write("file.txt", "before\n")
        try await repo.commit("Original")
        try repo.write("file.txt", "after\n")
        let file = try #require(try await Git.changedFiles(worktree: repo.path, base: "HEAD").first)
        let patch = try await Git.patch(worktree: repo.path, base: "HEAD", file: file)
        let hunk = try #require(DiffParser.parse(patch).first?.hunks.first)
        try await repo.commit("Keep edit")

        await #expect(throws: FileRevertRefusal.self) {
            try await Git.discardHunk(hunk, of: file, worktree: repo.path, base: "HEAD", scope: .all)
        }
        #expect(repo.read("file.txt") == "after\n")
        #expect(try await Git.changedFiles(worktree: repo.path, base: "HEAD").isEmpty)
    }
}
