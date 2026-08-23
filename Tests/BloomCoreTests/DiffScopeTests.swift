import Foundation
import Testing
@testable import BloomCore

/// What the three scopes mean, said without a window: which revision each one diffs against, what
/// the strip and the band say about it, and what becomes of a review comment on a file the scope
/// leaves out.
@Suite("Diff scope")
struct DiffScopeTests {

    private func commit(
        _ sha: String = "0f1e2d3c4b5a69788796a5b4c3d2e1f00f1e2d3c",
        subject: String = "Teach the parser about renames"
    ) -> BranchCommit {
        BranchCommit(sha: sha, subject: subject, author: "Freek", date: Date(timeIntervalSince1970: 1_700_000_000))
    }

    // MARK: - What git is asked

    @Test("every scope is the worktree against one revision")
    func revisions() {
        let picked = commit()
        #expect(DiffScope.all.revision(baseline: "abc123") == "abc123")
        #expect(DiffScope.uncommitted.revision(baseline: "abc123") == "HEAD")
        #expect(DiffScope.since(picked).revision(baseline: "abc123") == picked.sha)
    }

    /// The reason `since` means "since" rather than "including": it makes uncommitted the named
    /// case of the same idea instead of a fourth kind of thing.
    @Test("uncommitted is since the newest commit, said in a shorter way")
    func uncommittedIsSinceHead() {
        #expect(DiffScope.uncommitted.revision(baseline: "abc123") == "HEAD")
    }

    @Test("only All changes is the whole of it")
    func narrowing() {
        #expect(DiffScope.all.isNarrowed == false)
        #expect(DiffScope.uncommitted.isNarrowed)
        #expect(DiffScope.since(commit()).isNarrowed)
    }

    // MARK: - What it says

    @Test("the badge identifies a commit by its sha, not by a truncated sentence")
    func badges() {
        let long = commit(subject: "A subject long enough that no band would ever fit it on one line")
        #expect(DiffScope.all.badge == "All changes")
        #expect(DiffScope.uncommitted.badge == "Uncommitted")
        #expect(DiffScope.since(long).badge == "Since 0f1e2d3")
        #expect(DiffScope.since(long).title == "Since \(long.subject)")
    }

    @Test("an empty list means something different in each scope")
    func emptyMessages() {
        #expect(DiffScope.all.emptyMessage(base: "main").contains("main"))
        #expect(DiffScope.uncommitted.emptyMessage(base: "main") == "Everything in this worktree is committed.")
        #expect(DiffScope.since(commit()).emptyMessage(base: "main").contains("0f1e2d3"))
    }

    // MARK: - Review comments the scope leaves out

    private func comment(_ path: String) -> ReviewComment {
        ReviewComment(
            workspaceID: WorkspaceID("w1"),
            filePath: path,
            side: .new,
            anchor: ReviewCommentAnchor(line: 12, text: "let x = 1", before: [], after: []),
            body: "This retries for ever."
        )
    }

    private func file(_ path: String) -> ChangedFile {
        ChangedFile(path: path, change: .modified, additions: 3, deletions: 1)
    }

    @Test("narrowing counts the comments it took off screen")
    func strandedWhileNarrowed() {
        let comments = [comment("a.swift"), comment("b.swift"), comment("b.swift")]
        let shown = [file("a.swift")]

        let stranded = DiffScope.uncommitted.strandedComments(comments, among: shown)
        #expect(stranded.count == 2)
        #expect(stranded.allSatisfy { $0.filePath == "b.swift" })
        #expect(DiffScope.uncommitted.strandedNote(comments, among: shown)?.contains("2 review comments are") == true)
    }

    @Test("one is said in the singular")
    func strandedSingular() {
        let note = DiffScope.uncommitted.strandedNote([comment("b.swift")], among: [file("a.swift")])
        #expect(note?.contains("1 review comment is") == true)
        #expect(note?.contains("It is kept") == true)
    }

    /// A comment on a file that simply stopped differing from the base is not news, and it is not
    /// something the reader just did. Only narrowing gets to speak.
    @Test("All changes says nothing, even with a comment on a file that is not listed")
    func nothingSaidWhenNotNarrowed() {
        #expect(DiffScope.all.strandedComments([comment("b.swift")], among: [file("a.swift")]).isEmpty)
        #expect(DiffScope.all.strandedNote([comment("b.swift")], among: [file("a.swift")]) == nil)
    }

    @Test("nothing to say when every commented file is on screen")
    func nothingStranded() {
        let note = DiffScope.uncommitted.strandedNote([comment("a.swift")], among: [file("a.swift")])
        #expect(note == nil)
    }

    // MARK: - The commit list

    @Test("a list that had to stop says so")
    func truncation() {
        #expect(BranchCommitList(commits: [commit()], isTruncated: false).truncationNote == nil)
        let short = BranchCommitList(commits: [commit()], isTruncated: true)
        #expect(short.truncationNote?.contains("\(BranchCommitList.limit)") == true)
    }

    @Test("a scope pointing at a commit this branch no longer holds falls back to All changes")
    func rewrittenCommitFallsBack() {
        let list = BranchCommitList(commits: [commit("aaaa111", subject: "Still here")])
        let gone = DiffScope.since(commit("bbbb222", subject: "Squashed away"))

        #expect(list.canOffer(gone) == false)
        #expect(list.resolve(gone) == .all)
        #expect(list.resolve(.uncommitted) == .uncommitted)
        #expect(list.resolve(.since(commit("aaaa111", subject: "Still here"))) != .all)
    }

    // MARK: - Reading git log

    @Test("parses the commit records, NUL separated and unit separated")
    func parsesLog() throws {
        let unit = "\u{1f}"
        let record = { (sha: String, subject: String, author: String, date: String) in
            "\(sha)\(unit)\(subject)\(unit)\(author)\(unit)\(date)"
        }
        let stream = [
            record("1111111111111111111111111111111111111111", "Teach the parser about renames", "Freek", "2026-08-20T09:15:00+02:00"),
            // A subject with a newline in it, which is why none of this is split on lines.
            record("2222222222222222222222222222222222222222", "Fix the thing\nand the other thing", "Ruben", "2026-08-19T18:02:11+02:00"),
            record("3333333333333333333333333333333333333333", "Café: rename the module", "Seb", "2026-08-18T08:00:00+02:00"),
            // Too few fields. Dropped rather than guessed at: a row naming the wrong sha would
            // scope a diff to the wrong place.
            "4444444444444444444444444444444444444444\(unit)No date",
        ].joined(separator: "\0")

        let commits = Git.parseBranchCommits(Data(stream.utf8))

        #expect(commits.count == 3)
        #expect(commits[0].abbreviated == "1111111")
        #expect(commits[1].subject == "Fix the thing\nand the other thing")
        #expect(commits[2].subject == "Café: rename the module")
        #expect(commits[2].author == "Seb")
        #expect(commits[0].date > commits[1].date)
    }

    @Test("an empty log is an empty list rather than a phantom commit")
    func parsesEmptyLog() {
        #expect(Git.parseBranchCommits(Data()).isEmpty)
    }
}

/// The same three scopes driven against a real repository, because what they mean is what git
/// answers and nothing else.
@Suite("Diff scope against git", .tags(.git), .scratchDirectory)
struct DiffScopeGitTests {

    @Test("each scope lists the files it measures from, and no others")
    func scopesListWhatTheyMeasure() async throws {
        let repo = try await TempRepo()
        defer { repo.cleanUp() }

        try await Shell.check("git", ["checkout", "-q", "-b", "work"], cwd: repo.path)
        try repo.write("first.txt", "one\n")
        try await repo.commit("First step")
        try repo.write("second.txt", "two\n")
        try await repo.commit("Second step")
        // Left on disk, in no commit at all.
        try repo.write("third.txt", "three\n")

        let commits = try await Git.branchCommits(worktree: repo.path, base: "main")
        #expect(commits.commits.count == 2)
        #expect(commits.isTruncated == false)
        #expect(commits.commits.first?.subject == "Second step")

        let all = try await Git.changedFiles(worktree: repo.path, base: "main", scope: .all)
        #expect(all.map(\.path) == ["first.txt", "second.txt", "third.txt"])

        let uncommitted = try await Git.changedFiles(
            worktree: repo.path, base: "main", scope: .uncommitted
        )
        #expect(uncommitted.map(\.path) == ["third.txt"])

        // Since the first step: everything written after it, which is the second commit and the
        // file that was never committed. Not the first step's own file.
        let second = try #require(commits.commits.last)
        let since = try await Git.changedFiles(
            worktree: repo.path, base: "main", scope: .since(second)
        )
        #expect(since.map(\.path) == ["second.txt", "third.txt"])
    }

    @Test("a file's patch is measured from the same place as the list")
    func patchFollowsTheScope() async throws {
        let repo = try await TempRepo()
        defer { repo.cleanUp() }

        try await Shell.check("git", ["checkout", "-q", "-b", "work"], cwd: repo.path)
        try repo.write("notes.txt", "one\n")
        try await repo.commit("Write a line")
        try repo.write("notes.txt", "one\ntwo\n")

        let file = ChangedFile(path: "notes.txt", change: .modified)

        let whole = try await Git.patch(worktree: repo.path, base: "main", file: file, scope: .all)
        #expect(whole.contains("+one"))
        #expect(whole.contains("+two"))

        let onlyUncommitted = try await Git.patch(
            worktree: repo.path, base: "main", file: file, scope: .uncommitted
        )
        #expect(onlyUncommitted.contains("+two"))
        #expect(onlyUncommitted.contains("+one") == false)
    }

    /// The list exists to be measured from, and a merge of the base branch is the one thing on a
    /// workspace branch that the reader did not write.
    @Test("merges are left out of the list")
    func mergesAreLeftOut() async throws {
        let repo = try await TempRepo()
        defer { repo.cleanUp() }

        try repo.write("base.txt", "base\n")
        try await repo.commit("On main")

        try await Shell.check("git", ["checkout", "-q", "-b", "work"], cwd: repo.path)
        try repo.write("mine.txt", "mine\n")
        try await repo.commit("My own work")

        try await Shell.check("git", ["checkout", "-q", "main"], cwd: repo.path)
        try repo.write("later.txt", "later\n")
        try await repo.commit("Moved on without me")

        try await Shell.check("git", ["checkout", "-q", "work"], cwd: repo.path)
        try await Shell.check(
            "git", ["merge", "-q", "--no-ff", "-m", "Merge branch 'main' into work", "main"],
            cwd: repo.path
        )

        let commits = try await Git.branchCommits(worktree: repo.path, base: "main")
        #expect(commits.commits.map(\.subject) == ["My own work"])
    }

    @Test("a branch with more commits than the limit says the list is short")
    func truncatesLoudly() async throws {
        let repo = try await TempRepo()
        defer { repo.cleanUp() }

        try await Shell.check("git", ["checkout", "-q", "-b", "work"], cwd: repo.path)
        for step in 1...4 {
            try repo.write("step\(step).txt", "\(step)\n")
            try await repo.commit("Step \(step)")
        }

        let short = try await Git.branchCommits(worktree: repo.path, base: "main", limit: 2)
        #expect(short.commits.count == 2)
        #expect(short.isTruncated)
        #expect(short.commits.map(\.subject) == ["Step 4", "Step 3"])

        let whole = try await Git.branchCommits(worktree: repo.path, base: "main", limit: 4)
        #expect(whole.commits.count == 4)
        #expect(whole.isTruncated == false)
    }
}
