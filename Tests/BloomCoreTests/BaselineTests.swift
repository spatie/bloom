import Foundation
import Testing
@testable import BloomCore

/// What a workspace's diff is measured against.
///
/// The suite exists because of a bug that survived restarts. A pull request was squash merged,
/// Continue cut a new branch from a freshly fetched `origin/main`, and the inspector still said
/// "Changes (5)" and listed every file that had just been merged. The new branch was right; the
/// ruler it was measured with was the local `main`, which Bloom never moves and which was still
/// where it had been before the merge.
///
/// Advancing the local branch was the wrong fix. It is the user's own checkout: they may have
/// commits on it, it may be dirty, and it may not be `main` at all. So the base is resolved by
/// asking both the local branch and its remote-tracking copy and taking whichever divergence
/// point is further along.
@Suite("Base of a workspace diff", .tags(.git), .scratchDirectory)
struct BaselineTests {
    /// A clone with a real `origin`, so `refs/remotes/origin/main` exists the way it does in
    /// every repository Bloom is ever pointed at.
    private func clone(of server: TempRepo, named name: String) async throws -> TempRepo {
        let path = TestScratch.unique(name)
        try await Shell.check("git", ["clone", "-q", server.path, path])
        try await Shell.check("git", ["config", "user.email", "test@bloom.local"], cwd: path)
        try await Shell.check("git", ["config", "user.name", "Bloom Test"], cwd: path)
        try await Shell.check("git", ["config", "commit.gpgsign", "false"], cwd: path)
        return TempRepo(existing: path)
    }

    private func commitAll(_ repo: TempRepo, _ message: String) async throws {
        try await Shell.check("git", ["add", "-A"], cwd: repo.path)
        try await Shell.check("git", ["commit", "-q", "-m", message], cwd: repo.path)
    }

    /// The reported bug, end to end.
    @Test("after a squash merge and Continue, the merged files are not this workspace's changes")
    func continuedAfterASquashMerge() async throws {
        let server = try await TempRepo()
        defer { server.cleanUp() }
        let work = try await clone(of: server, named: "worktree")
        defer { work.cleanUp() }

        let cutFrom = try await Git.headSHA(of: work.path)

        // Five files on a branch, exactly as the end to end test had them.
        try await Shell.check("git", ["checkout", "-q", "-b", "tasklist"], cwd: work.path)
        for name in ["src/a.swift", "src/b.swift", "tests/a.swift", "tests/b.swift", "README.md"] {
            try work.write(name, "the work\n")
        }
        try await commitAll(work, "add the tasklist")

        // The same change lands on the server as one squashed commit, which is what makes the
        // branch's own commit unreachable from the base and the bug worth having a test for.
        for name in ["src/a.swift", "src/b.swift", "tests/a.swift", "tests/b.swift", "README.md"] {
            try server.write(name, "the work\n")
        }
        try await commitAll(server, "add the tasklist (#2)")

        // Continue: fetch, then cut the next branch at the base as the remote now has it.
        let resolved = try await Git.baseRevision(branch: "main", in: work.path)
        #expect(resolved.base == .fetched)
        try await Git.checkoutNewBranch("tasklist-2", at: resolved.revision, in: work.path)

        // The local branch is left exactly where it was. This is the half that must never change.
        #expect(await Git.revision(of: "refs/heads/main", in: work.path) == cutFrom)

        let files = try await Git.changedFiles(worktree: work.path, base: "main")
        #expect(files.isEmpty, "still reported \(files.map(\.path))")

        // And the next piece of work is the only thing reported.
        try work.write("src/c.swift", "the next thing\n")
        let after = try await Git.changedFiles(worktree: work.path, base: "main")
        #expect(after.map(\.path) == ["src/c.swift"])
    }

    /// The other direction, and the reason the fix is not simply "diff against `origin/<base>`".
    /// A branch cut from unpushed local commits must not report those commits as its own.
    @Test("unpushed commits on the local base are not counted as the workspace's work")
    func unpushedCommitsOnTheLocalBase() async throws {
        let server = try await TempRepo()
        defer { server.cleanUp() }
        let work = try await clone(of: server, named: "worktree")
        defer { work.cleanUp() }

        try work.write("notes-from-the-user.md", "written on main and never pushed\n")
        try await commitAll(work, "a commit of my own")

        try await Shell.check("git", ["checkout", "-q", "-b", "feature"], cwd: work.path)
        try work.write("src/feature.swift", "the agent's work\n")
        try await commitAll(work, "the agent's work")

        let files = try await Git.changedFiles(worktree: work.path, base: "main")
        #expect(files.map(\.path) == ["src/feature.swift"])
    }

    /// A repository with no remote at all, which Bloom supports everywhere else.
    @Test("a base branch with no remote-tracking copy still answers")
    func noRemoteAtAll() async throws {
        let repo = try await TempRepo()
        defer { repo.cleanUp() }

        let head = try await Git.headSHA(of: repo.path)
        try await Shell.check("git", ["checkout", "-q", "-b", "feature"], cwd: repo.path)
        try repo.write("src/feature.swift", "work\n")
        try await commitAll(repo, "work")

        #expect(try await Git.baseline("main", in: repo.path) == head)
        let files = try await Git.changedFiles(worktree: repo.path, base: "main")
        #expect(files.map(\.path) == ["src/feature.swift"])
    }

    /// A clone with an `origin`, but a base branch that only exists on this machine. Nothing here
    /// may fail loudly over a missing upstream.
    @Test("a base branch that was never pushed is not an error")
    func baseBranchWithNoUpstream() async throws {
        let server = try await TempRepo()
        defer { server.cleanUp() }
        let work = try await clone(of: server, named: "worktree")
        defer { work.cleanUp() }

        try await Shell.check("git", ["checkout", "-q", "-b", "release"], cwd: work.path)
        try work.write("release-notes.md", "2.0\n")
        try await commitAll(work, "start the release branch")
        let releaseTip = try await Git.headSHA(of: work.path)

        try await Shell.check("git", ["checkout", "-q", "-b", "hotfix"], cwd: work.path)
        try work.write("src/fix.swift", "the fix\n")
        try await commitAll(work, "the fix")

        #expect(try await Git.baseline("release", in: work.path) == releaseTip)
        let files = try await Git.changedFiles(worktree: work.path, base: "release")
        #expect(files.map(\.path) == ["src/fix.swift"])
    }

    /// An empty diff has to mean "nothing changed" and never "we could not find out", so a base
    /// that resolves nowhere still throws.
    @Test("a base that exists nowhere throws rather than answering an empty diff")
    func missingBaseThrows() async throws {
        let repo = try await TempRepo()
        defer { repo.cleanUp() }

        await #expect(throws: (any Error).self) {
            try await Git.baseline("no-such-branch", in: repo.path)
        }
    }

    @Test("a commit is its own ancestor, and an unrelated one is not")
    func ancestry() async throws {
        let repo = try await TempRepo()
        defer { repo.cleanUp() }

        let first = try await Git.headSHA(of: repo.path)
        try repo.write("second.txt", "second\n")
        try await commitAll(repo, "second")
        let second = try await Git.headSHA(of: repo.path)

        #expect(await Git.isAncestor(first, of: second, in: repo.path))
        #expect(await Git.isAncestor(second, of: second, in: repo.path))
        #expect(await Git.isAncestor(second, of: first, in: repo.path) == false)
        #expect(await Git.isAncestor("no-such-ref", of: second, in: repo.path) == false)
    }
}
