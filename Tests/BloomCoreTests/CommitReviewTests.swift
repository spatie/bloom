import Foundation
import Testing
@testable import BloomCore

@Suite("Commit and staging review", .tags(.git), .scratchDirectory)
struct CommitReviewTests {
    @Test("partially staged changes remain separate even when the working tree equals HEAD")
    func cancellingEdits() async throws {
        let repo = try await TempRepo()
        defer { repo.cleanUp() }
        try repo.write("notes.txt", "original\n")
        try await repo.commit("Baseline")
        try repo.write("notes.txt", "staged\n")
        try await Shell.check("git", ["add", "notes.txt"], cwd: repo.path)
        try repo.write("notes.txt", "original\n")

        let files = try await Git.changedFiles(worktree: repo.path, base: "main", scope: .uncommitted)
        #expect(files.count == 2)
        #expect(Set(files.map(\.id)).count == 2)
        let staged = try #require(files.first { $0.layer == .staged })
        let unstaged = try #require(files.first { $0.layer == .unstaged })
        let stagedPatch = try await Git.patch(worktree: repo.path, base: "main", file: staged, scope: .uncommitted)
        let unstagedPatch = try await Git.patch(worktree: repo.path, base: "main", file: unstaged, scope: .uncommitted)
        #expect(stagedPatch.contains("+staged"))
        #expect(unstagedPatch.contains("-staged"))
        #expect(unstagedPatch.contains("+original"))
        #expect(try await Git.reviewContents(worktree: repo.path, file: staged, scope: .uncommitted) == "staged\n")
        #expect(try await Git.reviewContents(worktree: repo.path, file: unstaged, scope: .uncommitted) == "original\n")
        let revisions = ReviewedFileFingerprint.revisions(for: files, worktree: repo.path, base: "main", scope: .uncommitted)
        #expect(revisions.count == 2)
        try repo.write("notes.txt", "another unstaged edit\n")
        let refreshed = try await Git.uncommittedFiles(worktree: repo.path)
        let freshRevisions = ReviewedFileFingerprint.revisions(for: refreshed, worktree: repo.path, base: "main", scope: .uncommitted)
        #expect(freshRevisions[staged.id] == revisions[staged.id])
        #expect(freshRevisions[unstaged.id] != revisions[unstaged.id])
    }

    @Test("historical patches and expanded context exclude later commits and local edits")
    func immutableCommit() async throws {
        let repo = try await TempRepo()
        defer { repo.cleanUp() }
        try await Shell.check("git", ["checkout", "-b", "work"], cwd: repo.path)
        try repo.write("notes.txt", "first\n")
        try await repo.commit("First step")
        let history = try await Git.branchCommits(worktree: repo.path, base: "main")
        let commit = try #require(history.commits.first)
        try repo.write("notes.txt", "first\nlater commit\n")
        try await repo.commit("Later step")
        try repo.write("notes.txt", "first\nstaged later\n")
        try await Shell.check("git", ["add", "notes.txt"], cwd: repo.path)
        try repo.write("notes.txt", "first\nnot committed\n")
        try repo.write("untracked.txt", "not part of history\n")
        let beforeStatus = try await Shell.check("git", ["status", "--porcelain=v1", "-z"], cwd: repo.path).stdout
        let beforeHead = try await Shell.check("git", ["rev-parse", "HEAD"], cwd: repo.path).stdout
        let indexPath = try await Shell.check("git", ["rev-parse", "--git-path", "index"], cwd: repo.path).trimmed
        let index = URL(fileURLWithPath: repo.path).appendingPathComponent(indexPath)
        let beforeIndex = try Data(contentsOf: index)

        let scope = DiffScope.commit(commit)
        let files = try await Git.changedFiles(worktree: repo.path, base: "main", scope: scope)
        #expect(files.map(\.path) == ["notes.txt"])
        let file = try #require(files.first)
        let patch = try await Git.patch(worktree: repo.path, base: "main", file: file, scope: scope)
        #expect(patch.contains("+first"))
        #expect(!patch.contains("later"))
        #expect(!patch.contains("not committed"))
        #expect(try await Git.reviewContents(worktree: repo.path, file: file, scope: scope) == "first\n")
        #expect(try Data(contentsOf: index) == beforeIndex)
        #expect(try await Shell.check("git", ["status", "--porcelain=v1", "-z"], cwd: repo.path).stdout == beforeStatus)
        #expect(try await Shell.check("git", ["rev-parse", "HEAD"], cwd: repo.path).stdout == beforeHead)
        #expect(try String(contentsOfFile: repo.path + "/notes.txt", encoding: .utf8) == "first\nnot committed\n")
        #expect(!scope.allowsWorktreeActions(for: file))
    }

    @Test("renames use both literal paths, including tabs, newlines and brackets")
    func rename() async throws {
        let repo = try await TempRepo()
        defer { repo.cleanUp() }
        let old = "old[1]\tname.txt"
        let new = "new[2]\nname.txt"
        try repo.write(old, "one\ntwo\nthree\nfour\nfive\n")
        try await repo.commit("Original")
        try await Shell.check("git", ["checkout", "-b", "work"], cwd: repo.path)
        try await Shell.check("git", ["mv", old, new], cwd: repo.path)
        try repo.write(new, "one\ntwo\nthree\nfour\nchanged\n")
        try await repo.commit("Rename and edit")
        let commit = try #require(try await Git.branchCommits(worktree: repo.path, base: "main").commits.first)
        let scope = DiffScope.commit(commit)
        let file = try #require(try await Git.changedFiles(worktree: repo.path, base: "main", scope: scope).first)
        #expect(file.path == new)
        #expect(file.oldPath == old)
        #expect(file.change == .renamed)
        let patch = try await Git.patch(worktree: repo.path, base: "main", file: file, scope: scope)
        #expect(patch.contains("rename from"))
        #expect(patch.contains("+changed"))
        #expect(!patch.contains("+one"))
    }

    @Test("root commits compare to an empty tree and deleted historical files still have patches")
    func rootAndDeletion() async throws {
        let repo = try await TempRepo()
        defer { repo.cleanUp() }
        let sha = try await Shell.check("git", ["rev-list", "--max-parents=0", "HEAD"], cwd: repo.path).trimmed
        let root = BranchCommit(sha: sha, subject: "Root", author: "Test", date: .now)
        let rootFiles = try await Git.changedFiles(worktree: repo.path, base: "main", scope: .commit(root))
        #expect(!rootFiles.isEmpty)
        #expect(rootFiles.allSatisfy { $0.change == .added })
        try repo.write("gone.txt", "removed content\n")
        try await repo.commit("Add a file")
        try await Shell.check("git", ["checkout", "-b", "work"], cwd: repo.path)
        try await Shell.check("git", ["rm", "gone.txt"], cwd: repo.path)
        try await repo.commit("Delete a file")
        let commit = try #require(try await Git.branchCommits(worktree: repo.path, base: "main").commits.first)
        let scope = DiffScope.commit(commit)
        let deleted = try #require(try await Git.changedFiles(worktree: repo.path, base: "main", scope: scope).first)
        #expect(deleted.change == .deleted)
        #expect(try await Git.patch(worktree: repo.path, base: "main", file: deleted, scope: scope).contains("-removed content"))
        #expect(try await Git.reviewContents(worktree: repo.path, file: deleted, scope: scope) == nil)
    }

    @Test("empty untracked files are text and binary files are identified")
    func untrackedFiles() async throws {
        let repo = try await TempRepo()
        defer { repo.cleanUp() }
        try repo.write("empty.txt", "")
        try Data([0, 1, 2, 255]).write(to: URL(fileURLWithPath: repo.path + "/image.bin"))
        let files = try await Git.uncommittedFiles(worktree: repo.path)
        let empty = try #require(files.first { $0.path == "empty.txt" })
        let binary = try #require(files.first { $0.path == "image.bin" })
        #expect(empty.layer == .untracked)
        #expect(!empty.isBinary)
        #expect(empty.additions == 0)
        #expect(binary.isBinary)
    }

    @Test("cache keys distinguish staging layers and rename sources")
    func cacheIdentity() {
        let staged = ChangedFile(path: "a.txt", change: .modified, layer: .staged)
        let unstaged = ChangedFile(path: "a.txt", change: .modified, layer: .unstaged)
        func patchKey(_ file: ChangedFile) -> PatchCache.Key {
            PatchCache.Key(worktree: "/tmp/test", base: "main", file: file, scope: .uncommitted, generation: 1)
        }
        func viewKey(_ file: ChangedFile) -> DiffPresentationCache.Key {
            DiffPresentationCache.Key(worktree: "/tmp/test", base: "main", file: file, scope: .uncommitted, ignoresWhitespace: false)
        }
        #expect(patchKey(staged) != patchKey(unstaged))
        #expect(viewKey(staged) != viewKey(unstaged))
        #expect(!DiffScope.uncommitted.allowsWorktreeActions(for: staged))
        #expect(DiffScope.all.allowsWorktreeActions(for: ChangedFile(path: "a.txt", change: .modified)))
    }

    @Test("a selected commit beyond the loaded page is retained")
    func pagedSelection() {
        let commit = BranchCommit(sha: "abcdef0", subject: "Earlier work", author: "Test", date: .now)
        let page = BranchCommitList(isTruncated: true)
        #expect(page.resolve(.commit(commit)) == .commit(commit))
        #expect(BranchCommitList().resolve(.commit(commit)) == .all)
    }

    @Test("conflicts are explicit and the resulting merge patch uses the first parent")
    func mergeResolution() async throws {
        let repo = try await TempRepo()
        defer { repo.cleanUp() }
        try repo.write("shared.txt", "base\n")
        try await repo.commit("Baseline")
        try await Shell.check("git", ["checkout", "-b", "side"], cwd: repo.path)
        try repo.write("shared.txt", "side\n")
        try await repo.commit("Side edit")
        try await Shell.check("git", ["checkout", "-b", "work", "main"], cwd: repo.path)
        try repo.write("shared.txt", "work\n")
        try await repo.commit("Work edit")
        let merge = try await Shell.run("git", ["merge", "--no-ff", "side"], cwd: repo.path)
        #expect(!merge.ok)
        let conflicts = try await Git.uncommittedFiles(worktree: repo.path)
        #expect(conflicts.filter { $0.path == "shared.txt" }.map(\.layer) == [.conflicted])
        try repo.write("shared.txt", "resolved\n")
        try await repo.commit("Resolve the merge")
        let commit = try #require(try await Git.branchCommits(worktree: repo.path, base: "main").commits.first)
        #expect(commit.parents.count == 2)
        let scope = DiffScope.commit(commit)
        let file = try #require(try await Git.changedFiles(worktree: repo.path, base: "main", scope: scope).first)
        let patch = try await Git.patch(worktree: repo.path, base: "main", file: file, scope: scope)
        #expect(patch.contains("-work"))
        #expect(patch.contains("+resolved"))
        #expect(!patch.contains("-side"))
    }

    @Test("staged files can be reviewed before the first commit")
    func unbornBranch() async throws {
        let repo = try await TempRepo()
        defer { repo.cleanUp() }
        try await Shell.check("git", ["checkout", "--orphan", "new-branch"], cwd: repo.path)
        try await Shell.check("git", ["rm", "-rf", "."], cwd: repo.path)
        try repo.write("first.txt", "first staged\n")
        try await Shell.check("git", ["add", "first.txt"], cwd: repo.path)
        let file = try #require(try await Git.uncommittedFiles(worktree: repo.path).first)
        #expect(file.layer == .staged)
        let patch = try await Git.patch(worktree: repo.path, base: "main", file: file, scope: .uncommitted)
        #expect(patch.contains("+first staged"))
    }

    @Test("amended commits disappear from ancestry even when their objects still exist")
    func amendedSelection() async throws {
        let repo = try await TempRepo()
        defer { repo.cleanUp() }
        try await Shell.check("git", ["checkout", "-b", "work"], cwd: repo.path)
        try repo.write("first.txt", "first\n")
        try await repo.commit("First")
        let commit = try #require(try await Git.branchCommits(worktree: repo.path, base: "main").commits.first)
        #expect(try await Git.containsCommit(commit, worktree: repo.path))
        try await Shell.check("git", ["commit", "--amend", "-m", "Amended"], cwd: repo.path)
        #expect(try await Git.containsCommit(commit, worktree: repo.path) == false)
        let history = try await Git.branchCommits(worktree: repo.path, base: "main")
        #expect(history.resolve(.commit(commit)) == .all)
    }

    @Test("full commit messages tolerate separators and empty bodies")
    func commitMetadata() async throws {
        let repo = try await TempRepo()
        defer { repo.cleanUp() }
        try await Shell.check("git", ["checkout", "-b", "work"], cwd: repo.path)
        try repo.write("notes.txt", "one\n")
        try await repo.commit("Subject with \u{1f} separator\n\nFirst body line\nSecond body line")
        let commit = try #require(try await Git.branchCommits(worktree: repo.path, base: "main").commits.first)
        #expect(commit.subject == "Subject with \u{1f} separator")
        #expect(commit.body == "First body line\nSecond body line")
        #expect(commit.parents.count == 1)
    }
}
