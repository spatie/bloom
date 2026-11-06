import Foundation
import Testing
@testable import BloomCore

/// Discarding one hunk. Every test here that touches a repository is the same promise seen from a
/// different side: the hunk that was pressed goes, everything else in the file stays, and a hunk
/// that is not what the reader saw any more writes nothing at all.
@Suite("Discarding a hunk", .tags(.git, .destructive), .scratchDirectory)
struct HunkDiscardTests {
    private static let before = (1...30).map { "line \($0)" }.joined(separator: "\n") + "\n"

    /// Line 2 and line 25 changed, far enough apart for git to print two hunks.
    private static let after = before
        .replacingOccurrences(of: "line 2\n", with: "line two\n")
        .replacingOccurrences(of: "line 25\n", with: "line twenty-five\n")

    private func repo(named path: String = "file.txt") async throws -> TempRepo {
        let repo = try await TempRepo()
        try repo.write(path, Self.before)
        try await repo.commit("Before")
        try repo.write(path, Self.after)
        return repo
    }

    private func hunks(_ repo: TempRepo, _ file: ChangedFile, scope: DiffScope = .all) async throws -> [DiffHunk] {
        let patch = try await Git.patch(worktree: repo.path, base: "main", file: file, scope: scope)
        return try #require(DiffParser.parse(patch).first).hunks
    }

    @Test("one hunk goes and the other stays")
    func discardsOnlyThePressedHunk() async throws {
        let repo = try await repo()
        defer { repo.cleanUp() }
        let file = ChangedFile(path: "file.txt", change: .modified)
        let shown = try await hunks(repo, file)
        #expect(shown.count == 2)

        try await Git.discardHunk(shown[0], of: file, worktree: repo.path, base: "main", scope: .all)

        let text = try #require(repo.read("file.txt"))
        #expect(text.contains("line 2\n"))
        #expect(text.contains("line twenty-five\n"))
    }

    @Test("a staged hunk is discarded from the index as well as the worktree")
    func stagedHunkLeavesBoth() async throws {
        let repo = try await repo()
        defer { repo.cleanUp() }
        try await Shell.check("git", ["add", "file.txt"], cwd: repo.path)
        let file = ChangedFile(path: "file.txt", change: .modified, layer: .staged)
        let shown = try await hunks(repo, file, scope: .uncommitted)

        try await Git.discardHunk(shown[1], of: file, worktree: repo.path, base: "main", scope: .uncommitted)

        let staged = try await Shell.check("git", ["show", ":file.txt"], cwd: repo.path).stdout
        #expect(staged.contains("line 25\n"))
        #expect(staged.contains("line two\n"))
        #expect(repo.read("file.txt")?.contains("line 25\n") == true)
        #expect(repo.read("file.txt")?.contains("line two\n") == true)
    }

    @Test("an unstaged hunk leaves the index alone")
    func unstagedHunkLeavesTheIndex() async throws {
        let repo = try await repo()
        defer { repo.cleanUp() }
        let file = ChangedFile(path: "file.txt", change: .modified, layer: .unstaged)
        let shown = try await hunks(repo, file, scope: .uncommitted)

        try await Git.discardHunk(shown[0], of: file, worktree: repo.path, base: "main", scope: .uncommitted)

        #expect(repo.read("file.txt")?.contains("line 2\n") == true)
        let staged = try await Shell.check("git", ["show", ":file.txt"], cwd: repo.path).stdout
        #expect(staged == Self.before)
    }

    @Test("a file changed under the diff refuses and writes nothing")
    func staleHunkRefuses() async throws {
        let repo = try await repo()
        defer { repo.cleanUp() }
        let file = ChangedFile(path: "file.txt", change: .modified)
        let shown = try await hunks(repo, file)
        let moved = Self.after.replacingOccurrences(of: "line two\n", with: "line deux\n")
        try repo.write("file.txt", moved)

        await #expect(throws: HunkDiscardRefusal.changed) {
            try await Git.discardHunk(shown[0], of: file, worktree: repo.path, base: "main", scope: .all)
        }
        #expect(repo.read("file.txt") == moved)
    }

    @Test("a hunk drawn against a base that has since moved refuses and writes nothing")
    func movedBaseRefuses() async throws {
        let repo = try await repo()
        defer { repo.cleanUp() }
        let file = ChangedFile(path: "file.txt", change: .modified)
        let shown = try await hunks(repo, file)
        let drawn = try await Git.baseline("main", in: repo.path)
        try repo.write("other.txt", "elsewhere\n")
        try await Shell.check("git", ["add", "other.txt"], cwd: repo.path)
        try await Shell.check("git", ["commit", "-q", "-m", "Moved"], cwd: repo.path)

        await #expect(throws: StaleDiffTarget()) {
            try await Git.discardHunk(
                shown[0], of: file, worktree: repo.path, base: "main", scope: .all, expected: drawn
            )
        }
        #expect(repo.read("file.txt") == Self.after)

        let current = try await Git.baseline("main", in: repo.path)
        try await Git.discardHunk(
            shown[0], of: file, worktree: repo.path, base: "main", scope: .all, expected: current
        )
        #expect(repo.read("file.txt")?.contains("line 2\n") == true)
    }

    @Test("a renamed file keeps its new name when one hunk of it is discarded")
    func renamedFileStaysRenamed() async throws {
        let repo = try await repo(named: "old name.txt")
        defer { repo.cleanUp() }
        try await Shell.check("git", ["mv", "old name.txt", "new \u{e9}.txt"], cwd: repo.path)
        let file = ChangedFile(path: "new \u{e9}.txt", oldPath: "old name.txt", change: .renamed)
        let shown = try await hunks(repo, file)

        try await Git.discardHunk(shown[0], of: file, worktree: repo.path, base: "main", scope: .all)

        #expect(!repo.exists("old name.txt"))
        let text = try #require(repo.read("new \u{e9}.txt"))
        #expect(text.contains("line 2\n"))
        #expect(text.contains("line twenty-five\n"))
    }

    @Test("isolating a hunk rebuilds the header from the destination path")
    func isolatedPatchHasAPlainHeader() {
        let patch = """
            diff --git a/old.txt b/new.txt
            similarity index 90%
            rename from old.txt
            rename to new.txt
            index 1111111..2222222 100644
            --- a/old.txt
            +++ b/new.txt
            @@ -1,2 +1,2 @@
            -a
            +A
             b
            @@ -9,2 +9,2 @@
             i
            -j
            +J

            """
        let hunk = DiffParser.parse(patch)[0].hunks[1]
        #expect(HunkPatch.isolate(hunk, from: patch) == """
            --- a/new.txt
            +++ b/new.txt
            @@ -9,2 +9,2 @@
             i
            -j
            +J

            """)
    }

    @Test("a quoted destination keeps its quotes")
    func quotedPaths() {
        #expect(HunkPatch.oldSide(of: "+++ \"b/moved \\303\\251.txt\"") == "--- \"a/moved \\303\\251.txt\"")
        #expect(HunkPatch.oldSide(of: "+++ /dev/null") == nil)
    }

    @Test("only a change within a file offers a hunk discard")
    func availability() {
        func offer(_ change: ChangedFile.Change, layer: ChangeLayer? = nil, scope: DiffScope = .all,
                   whitespace: Bool = false, running: Bool = false) -> HunkDiscard.Availability {
            HunkDiscard.availability(
                file: ChangedFile(path: "a", change: change, layer: layer),
                scope: scope, ignoringWhitespace: whitespace, agentIsRunning: running
            )
        }
        #expect(offer(.modified) == .enabled)
        #expect(offer(.renamed) == .enabled)
        #expect(offer(.added) == .hidden)
        #expect(offer(.untracked, layer: .untracked, scope: .uncommitted) == .hidden)
        #expect(offer(.deleted) == .hidden)
        #expect(offer(.modified, layer: .conflicted, scope: .uncommitted) == .hidden)
        let commit = BranchCommit(sha: "abc", subject: "s", author: "a", date: .now)
        #expect(offer(.modified, scope: .commit(commit)) == .hidden)
        #expect(offer(.modified, running: true) == .disabled(HunkDiscard.agentIsWorking))
        #expect(offer(.modified, whitespace: true) == .disabled(HunkDiscard.whitespaceIsHidden))
    }
}
