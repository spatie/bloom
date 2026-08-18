import Testing
import Foundation
@testable import BatonCore

/// Every test here reproduces something that used to destroy work, lie about work, or hand a
/// hostile branch name to git as an option. They all drive real git, because the bugs were in
/// how git was invoked and how its output was read.
@Suite("Git safety")
struct GitSafetyTests {
    private func makeStore() throws -> Store {
        try Store(path: NSTemporaryDirectory() + "baton-safety-\(UUID().uuidString).sqlite")
    }

    /// A repo plus a registered workspace, the shape every archiving test needs.
    private func makeWorkspace(
        settings: String? = nil,
        prompt: String = "Do the thing"
    ) async throws -> (repo: TempRepo, registered: Repo, manager: WorkspaceManager, workspace: Workspace) {
        let repo = try await TempRepo()
        if let settings { try repo.write(".conductor/settings.toml", settings) }
        let manager = WorkspaceManager(store: try makeStore())
        let registered = try await manager.addRepository(at: repo.path)
        let workspace = try await manager.createWorkspace(repo: registered, prompt: prompt)
        return (repo, registered, manager, workspace)
    }

    // MARK: - Bug 1: archiving destroyed uncommitted and unpublished work

    @Test("archiving a dirty worktree refuses and loses nothing")
    func refusesToArchiveDirtyWorktree() async throws {
        let (repo, registered, manager, workspace) = try await makeWorkspace()
        defer { repo.cleanUp() }

        let worktree = TempRepo(existing: workspace.path)
        try worktree.write("README.md", "hello\nedited by the agent\n")
        try worktree.write("notes.txt", "an untracked file nobody committed\n")

        let report = try await manager.safetyReport(workspace: workspace, repo: registered)
        #expect(report.hasUncommittedChanges)
        #expect(report.untrackedFiles == ["notes.txt"])
        #expect(!report.isSafeToDiscard)

        await #expect(throws: WorkspaceError.self) {
            try await manager.archive(workspace: workspace, repo: registered)
        }

        // Nothing was touched: the files, the worktree and the store row all survive.
        #expect(worktree.read("README.md") == "hello\nedited by the agent\n")
        #expect(worktree.exists("notes.txt"))
        #expect(try await manager.store.workspace(id: workspace.id)?.state != .archived)
        #expect(try await Git.worktrees(of: repo.path).contains { $0.branch == workspace.branch })

        // Forcing is still possible, which is the whole point of asking first.
        try await manager.archive(workspace: workspace, repo: registered, force: true)
        #expect(!FileManager.default.fileExists(atPath: workspace.path))
    }

    @Test("archiving with commits no other ref holds refuses")
    func refusesToArchiveUnpushedCommits() async throws {
        let (repo, registered, manager, workspace) = try await makeWorkspace()
        defer { repo.cleanUp() }

        let worktree = TempRepo(existing: workspace.path)
        try worktree.write("feature.txt", "work that exists nowhere else\n")
        try await commit(in: workspace.path, message: "unpublished work")
        let sha = try await Git.headSHA(of: workspace.path)

        let report = try await manager.safetyReport(workspace: workspace, repo: registered)
        #expect(report.unpushedCommits == 1)
        #expect(!report.isBranchMerged)
        #expect(!report.isSafeToDiscard)
        #expect(report.losses.contains { $0.contains("no other branch") })

        await #expect(throws: WorkspaceError.self) {
            try await manager.archive(workspace: workspace, repo: registered, deleteBranch: true)
        }

        // The commit is still reachable, which is what "lost" would have meant.
        #expect(await Git.branchExists(workspace.branch, in: repo.path))
        let contains = try await Shell.run("git", ["cat-file", "-e", "\(sha)^{commit}"], cwd: repo.path)
        #expect(contains.ok)
    }

    @Test("a merged branch is safe to archive even though its commits are not on a remote")
    func mergedBranchIsSafe() async throws {
        let (repo, registered, manager, workspace) = try await makeWorkspace()
        defer { repo.cleanUp() }

        let worktree = TempRepo(existing: workspace.path)
        try worktree.write("feature.txt", "merged work\n")
        try await commit(in: workspace.path, message: "work")
        try await Shell.check("git", ["merge", "--no-edit", "-q", workspace.branch], cwd: repo.path)

        let report = try await manager.safetyReport(workspace: workspace, repo: registered)
        #expect(report.unpushedCommits == 0)
        #expect(report.isBranchMerged)
        #expect(report.isSafeToDiscard)

        try await manager.archive(workspace: workspace, repo: registered, deleteBranch: true)
        #expect(await !Git.branchExists(workspace.branch, in: repo.path))
    }

    @Test("a branch whose commits are on a remote is safe to archive")
    func pushedBranchIsSafe() async throws {
        let (repo, registered, manager, workspace) = try await makeWorkspace()
        defer { repo.cleanUp() }

        let remote = NSTemporaryDirectory() + "baton-remote-\(UUID().uuidString).git"
        try await Shell.check("git", ["init", "-q", "--bare", remote])
        defer { try? FileManager.default.removeItem(atPath: remote) }
        try await Shell.check("git", ["remote", "add", "origin", remote], cwd: repo.path)

        let worktree = TempRepo(existing: workspace.path)
        try worktree.write("feature.txt", "published work\n")
        try await commit(in: workspace.path, message: "work")
        try await GitHub.push(worktree: workspace.path, branch: workspace.branch, setUpstream: true)

        let report = try await manager.safetyReport(workspace: workspace, repo: registered)
        #expect(report.unpushedCommits == 0)
        #expect(report.isSafeToDiscard)

        // The branch is not merged into main, so plain `git branch -d` would refuse. Archiving
        // still has to succeed, because the commits are safely on origin.
        try await manager.archive(workspace: workspace, repo: registered, deleteBranch: true)
        #expect(await !Git.branchExists(workspace.branch, in: repo.path))
    }

    @Test("a failing archive script aborts the archive")
    func failingArchiveScriptAborts() async throws {
        let (repo, registered, manager, workspace) = try await makeWorkspace(settings: """
        [scripts]
        archive = '''
        echo "could not stop the container"
        exit 3
        '''
        """)
        defer { repo.cleanUp() }

        await #expect(throws: WorkspaceError.self) {
            try await manager.archive(workspace: workspace, repo: registered)
        }

        // The worktree, the branch and the store row all have to survive a failed wind-down.
        #expect(FileManager.default.fileExists(atPath: workspace.path))
        #expect(await Git.branchExists(workspace.branch, in: repo.path))
        #expect(try await manager.store.workspace(id: workspace.id)?.state != .archived)
    }

    @Test("git branch -d failing is reported rather than swallowed")
    func deleteBranchReportsFailure() async throws {
        let repo = try await TempRepo()
        defer { repo.cleanUp() }

        await #expect(throws: ShellError.self) {
            try await Git.deleteBranch("no-such-branch", in: repo.path)
        }

        // The safe form refuses to drop commits that live nowhere else.
        try await Shell.check("git", ["branch", "unmerged"], cwd: repo.path)
        try await Shell.check("git", ["checkout", "-q", "unmerged"], cwd: repo.path)
        try repo.write("only-here.txt", "x\n")
        try await repo.commit("only here")
        try await Shell.check("git", ["checkout", "-q", "main"], cwd: repo.path)

        await #expect(throws: ShellError.self) {
            try await Git.deleteBranch("unmerged", in: repo.path)
        }
        #expect(await Git.branchExists("unmerged", in: repo.path))

        try await Git.deleteBranch("unmerged", in: repo.path, force: true)
        #expect(await !Git.branchExists("unmerged", in: repo.path))
    }

    @Test("removing a dirty worktree needs force")
    func removingDirtyWorktreeNeedsForce() async throws {
        let repo = try await TempRepo()
        defer { repo.cleanUp() }

        let path = NSTemporaryDirectory() + "baton-wt-\(UUID().uuidString)"
        try await Git.addWorktree(repo: repo.path, path: path, branch: "dirty", base: "main")
        defer { try? FileManager.default.removeItem(atPath: path) }
        try TempRepo(existing: path).write("README.md", "changed\n")

        await #expect(throws: ShellError.self) {
            try await Git.removeWorktree(repo: repo.path, path: path)
        }
        #expect(FileManager.default.fileExists(atPath: path))

        try await Git.removeWorktree(repo: repo.path, path: path, force: true)
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    // MARK: - Bug 2: a hostile branch name became a git option

    @Test("rejects branch names git would read as options")
    func validatesBranchNames() async throws {
        let valid = ["main", "feature/x", "freek/use-settings-file", "café", "a-b_c.d"]
        let invalid = [
            "--mirror", "-x", "", "a..b", "a b", "a~1", "a^", "a:b", "a?", "a*", "a[",
            "a\\b", "a.lock", ".hidden", "a/.hidden", "a/", "/a", "a//b", "a.", "a@{1}",
            "HEAD", "a\nb", "a\tb", "x.lock/y",
        ]

        for name in valid {
            #expect(Git.isValidBranchName(name), "should accept \(name)")
        }
        for name in invalid {
            #expect(!Git.isValidBranchName(name), "should reject \(name)")
        }

        // Agree with git itself, which is the definition being copied.
        for name in valid + invalid where !name.isEmpty {
            let git = try await Shell.run("git", ["check-ref-format", "--branch", name])
            #expect(git.ok == Git.isValidBranchName(name), "disagreed with git about \(name)")
        }
    }

    @Test("a branch named --mirror cannot mirror on push")
    func hostileBranchNameCannotMirror() async throws {
        let repo = try await TempRepo()
        defer { repo.cleanUp() }

        let remote = NSTemporaryDirectory() + "baton-remote-\(UUID().uuidString).git"
        try await Shell.check("git", ["init", "-q", "--bare", remote])
        defer { try? FileManager.default.removeItem(atPath: remote) }
        try await Shell.check("git", ["remote", "add", "origin", remote], cwd: repo.path)

        // A branch that exists only on the remote is exactly what --mirror deletes.
        try await Shell.check("git", ["push", "-q", "origin", "HEAD:refs/heads/keep-me"], cwd: repo.path)
        // `git branch` refuses the name, but the ref itself is perfectly legal, and writing it
        // directly is all anyone needs to do to plant it.
        try await Shell.check("git", ["update-ref", "--", "refs/heads/--mirror", "HEAD"], cwd: repo.path)
        try await Shell.check("git", ["symbolic-ref", "HEAD", "refs/heads/--mirror"], cwd: repo.path)

        await #expect(throws: GitHubError.self) {
            try await GitHub.push(worktree: repo.path, branch: "--mirror", setUpstream: true)
        }

        let refs = try await Shell.check("git", ["ls-remote", "--heads", remote])
        #expect(refs.stdout.contains("refs/heads/keep-me"))
    }

    @Test("pushing sends an explicit refspec, so the branch is only ever a ref")
    func pushUsesRefspec() async throws {
        let repo = try await TempRepo()
        defer { repo.cleanUp() }

        let remote = NSTemporaryDirectory() + "baton-remote-\(UUID().uuidString).git"
        try await Shell.check("git", ["init", "-q", "--bare", remote])
        defer { try? FileManager.default.removeItem(atPath: remote) }
        try await Shell.check("git", ["remote", "add", "origin", remote], cwd: repo.path)
        try await Shell.check("git", ["checkout", "-q", "-b", "feature/push-me"], cwd: repo.path)

        try await GitHub.push(worktree: repo.path, branch: "feature/push-me", setUpstream: true)

        let refs = try await Shell.check("git", ["ls-remote", "--heads", remote])
        #expect(refs.stdout.contains("refs/heads/feature/push-me"))
        #expect(await GitHub.hasRemoteBranch("feature/push-me", worktree: repo.path))
        #expect(await !GitHub.hasRemoteBranch("--mirror", worktree: repo.path))
    }

    @Test("git helpers refuse a ref that looks like an option")
    func refusesOptionLikeRefs() async throws {
        let repo = try await TempRepo()
        defer { repo.cleanUp() }

        await #expect(throws: ShellError.self) {
            try await Git.deleteBranch("--mirror", in: repo.path)
        }
        await #expect(throws: ShellError.self) {
            _ = try await Git.changedFiles(worktree: repo.path, base: "--all")
        }
        await #expect(throws: ShellError.self) {
            try await Git.addWorktree(
                repo: repo.path,
                path: NSTemporaryDirectory() + "baton-never-\(UUID().uuidString)",
                branch: "--mirror",
                base: "main"
            )
        }
    }

    // MARK: - Bug 3: changedFiles misparsed ordinary Unicode paths

    @Test("parses unicode, tab and newline paths, and a rename that also changed")
    func parsesAwkwardPaths() async throws {
        let repo = try await TempRepo()
        defer { repo.cleanUp() }

        let tabbed = "with\ttab.txt"
        let newlined = "with\nnewline.txt"

        try repo.write("café.txt", "one\n")
        try repo.write(tabbed, "one\n")
        try repo.write("before.txt", "a\nb\nc\n")
        try await repo.commit("awkward paths")

        let worktree = NSTemporaryDirectory() + "baton-wt-\(UUID().uuidString)"
        try await Git.addWorktree(repo: repo.path, path: worktree, branch: "awkward", base: "main")
        defer { try? FileManager.default.removeItem(atPath: worktree) }

        let workspace = TempRepo(existing: worktree)
        try workspace.write("café.txt", "one\ntwo\n")
        try workspace.write(tabbed, "one\ntwo\n")
        try workspace.write(newlined, "brand new\n")
        // A rename and a modification of the same file, which used to arrive as one bogus path
        // spelled "before.txt => after.txt".
        try await Shell.check("git", ["mv", "before.txt", "after.txt"], cwd: worktree)
        try workspace.write("after.txt", "a\nb\nc\nd\n")

        let files = try await Git.changedFiles(worktree: worktree, base: "main")
        let byPath = Dictionary(uniqueKeysWithValues: files.map { ($0.path, $0) })

        let accented = try #require(byPath["café.txt"], "expected the decoded name, got \(Array(byPath.keys))")
        #expect(accented.additions == 1)

        let tab = try #require(byPath[tabbed])
        #expect(tab.additions == 1)

        let newline = try #require(byPath[newlined])
        #expect(newline.change == .untracked)

        let renamed = try #require(byPath["after.txt"])
        #expect(renamed.change == .renamed)
        #expect(renamed.oldPath == "before.txt")
        #expect(renamed.additions == 1)
        #expect(!byPath.keys.contains { $0.contains("=>") })
        #expect(!byPath.keys.contains { $0.contains("\\303") })
    }

    @Test("a pure rename keeps both sides of the move")
    func parsesPureRename() async throws {
        let repo = try await TempRepo()
        defer { repo.cleanUp() }
        try repo.write("old-name.txt", "unchanged content\n")
        try await repo.commit("add")

        let worktree = NSTemporaryDirectory() + "baton-wt-\(UUID().uuidString)"
        try await Git.addWorktree(repo: repo.path, path: worktree, branch: "moved", base: "main")
        defer { try? FileManager.default.removeItem(atPath: worktree) }
        try await Shell.check("git", ["mv", "old-name.txt", "new-name.txt"], cwd: worktree)

        let files = try await Git.changedFiles(worktree: worktree, base: "main")
        let renamed = try #require(files.first { $0.path == "new-name.txt" })
        #expect(renamed.change == .renamed)
        #expect(renamed.oldPath == "old-name.txt")
        #expect(files.count == 1)
    }

    @Test("parses a deletion and a binary file")
    func parsesDeletionsAndBinaries() async throws {
        let repo = try await TempRepo()
        defer { repo.cleanUp() }
        try repo.write("doomed.txt", "goodbye\n")
        try await repo.commit("add")

        let worktree = NSTemporaryDirectory() + "baton-wt-\(UUID().uuidString)"
        try await Git.addWorktree(repo: repo.path, path: worktree, branch: "deleting", base: "main")
        defer { try? FileManager.default.removeItem(atPath: worktree) }

        try await Shell.check("git", ["rm", "-q", "doomed.txt"], cwd: worktree)
        let binary = (worktree as NSString).appendingPathComponent("blob.bin")
        try Data([0x00, 0x01, 0x02, 0xFF, 0x00]).write(to: URL(fileURLWithPath: binary))
        try await Shell.check("git", ["add", "blob.bin"], cwd: worktree)

        let files = try await Git.changedFiles(worktree: worktree, base: "main")
        #expect(files.first { $0.path == "doomed.txt" }?.change == .deleted)
        #expect(files.first { $0.path == "blob.bin" }?.isBinary == true)
    }

    /// The parsers are pure functions over git's bytes, so the awkward shapes can be pinned down
    /// without waiting for a repository.
    @Test("parses the -z record layouts directly")
    func parsesRecordLayoutsFromBytes() {
        let nameStatus = Data("R100\u{0}before.txt\u{0}after.txt\u{0}M\u{0}café.txt\u{0}D\u{0}gone.txt\u{0}".utf8)
        let changes = Git.parseNameStatus(nameStatus)
        #expect(changes["after.txt"]?.0 == .renamed)
        #expect(changes["after.txt"]?.1 == "before.txt")
        #expect(changes["café.txt"]?.0 == .modified)
        #expect(changes["gone.txt"]?.0 == .deleted)

        let numstat = Data("1\t0\t\u{0}before.txt\u{0}after.txt\u{0}2\t3\tcafé.txt\u{0}-\t-\tblob.bin\u{0}0\t9\ta\tb.txt\u{0}".utf8)
        let files = Git.parseNumstat(numstat, changes: changes)
        #expect(files["after.txt"]?.additions == 1)
        #expect(files["after.txt"]?.oldPath == "before.txt")
        #expect(files["café.txt"]?.deletions == 3)
        #expect(files["blob.bin"]?.isBinary == true)
        // A tab inside a path is not a field separator once the first two are consumed.
        #expect(files["a\tb.txt"]?.deletions == 9)

        let status = Data("R  new.txt\u{0}old.txt\u{0}?? fresh.txt\u{0} M edited.txt\u{0}".utf8)
        let parsed = Git.parseStatus(status)
        #expect(parsed.dirty)
        #expect(parsed.untracked == ["fresh.txt"])
    }

    // MARK: - Bug 4: git failures were reported as "no changes"

    @Test("a missing base branch surfaces an error rather than an empty diff")
    func missingBaseThrows() async throws {
        let repo = try await TempRepo()
        defer { repo.cleanUp() }

        await #expect(throws: (any Error).self) {
            _ = try await Git.changedFiles(worktree: repo.path, base: "no-such-base")
        }
        await #expect(throws: (any Error).self) {
            _ = try await Git.diffStat(worktree: repo.path, base: "no-such-base")
        }
        await #expect(throws: (any Error).self) {
            _ = try await Git.commitsAhead(worktree: repo.path, base: "no-such-base")
        }
    }

    @Test("a directory that is not a repository surfaces an error")
    func brokenRepositoryThrows() async throws {
        let plain = NSTemporaryDirectory() + "baton-plain-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: plain, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: plain) }

        await #expect(throws: (any Error).self) {
            _ = try await Git.changedFiles(worktree: plain, base: "main")
        }
    }

    // MARK: - Bug 5: PortAllocator

    @Test("allocates a whole free block and fails loudly when there is none")
    func allocatesWholeBlocks() throws {
        // Its own range. Availability is probed by actually binding a socket, so two tests
        // sharing the default range invalidate each other when the suite runs in parallel.
        let base = 41_000
        let first = try PortAllocator.allocate(taken: [], start: base)
        #expect(first >= base)
        // Deliberately not re-probing the block with `isBlockAvailable` here. `allocate` only
        // returns a port whose whole block passed that check, so asking again asserts that no
        // other process on the machine grabbed a port in the meantime, which is not what this
        // test is about and made it flake. The logic below uses explicit `taken` sets instead,
        // which is deterministic.

        // A single port inside the block being taken disqualifies the whole block.
        let second = try PortAllocator.allocate(taken: [first + 3], start: base)
        #expect(second == first + PortAllocator.blockSize)

        #expect(throws: PortAllocatorError.self) {
            _ = try PortAllocator.allocate(taken: [], start: 3_100, limit: 3_105)
        }
        // The old code answered `start` here even though `start` was explicitly taken.
        #expect(throws: PortAllocatorError.self) {
            _ = try PortAllocator.allocate(taken: Set(3_100...3_200), start: 3_100, limit: 3_150)
        }
    }

    // MARK: - Helpers

    private func commit(in worktree: String, message: String) async throws {
        try await Shell.check("git", ["add", "-A"], cwd: worktree)
        try await Shell.check("git", [
            "-c", "user.email=test@baton.local", "-c", "user.name=Baton Test",
            "-c", "commit.gpgsign=false",
            "commit", "-q", "-m", message,
        ], cwd: worktree)
    }
}
