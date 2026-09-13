import Foundation
import Testing
@testable import BloomCore

@Suite("Git operation reliability", .tags(.git), .scratchDirectory)
struct GitReliabilityTests {
    @Test("reverting a dynamic route preserves neighbouring worktree and index edits")
    func literalRevert() async throws {
        let repo = try await TempRepo()
        defer { repo.cleanUp() }
        for name in ["[id].tsx", "i.tsx", "d.tsx"] { try repo.write(name, "before\n") }
        try await repo.commit("Routes")
        for name in ["[id].tsx", "i.tsx", "d.tsx"] { try repo.write(name, "after\n") }
        try await Shell.check("git", ["add", "--", "i.tsx"], cwd: repo.path)
        let file = ChangedFile(path: "[id].tsx", change: .modified)
        let patch = try await Git.patch(worktree: repo.path, base: "main", file: file)
        #expect(DiffParser.parse(patch).count == 1)
        try await Git.revertTrackedFile(file, worktree: repo.path, base: "main")
        #expect(repo.read("[id].tsx") == "before\n")
        #expect(repo.read("i.tsx") == "after\n")
        #expect(repo.read("d.tsx") == "after\n")
        let staged = try await Shell.check("git", ["show", ":i.tsx"], cwd: repo.path)
        #expect(staged.stdout == "after\n")
    }

    @Test("removing an added glob path does not remove matching files")
    func literalRemoval() async throws {
        let repo = try await TempRepo()
        defer { repo.cleanUp() }
        try repo.write("keep.txt", "keep\n")
        try await repo.commit("Keep")
        let base = try await Git.headSHA(of: repo.path)
        try repo.write("*.txt", "new\n")
        try await repo.commit("Added")
        try await Git.revertTrackedFile(ChangedFile(path: "*.txt", change: .added), worktree: repo.path, base: base)
        #expect(!repo.exists("*.txt"))
        #expect(repo.read("keep.txt") == "keep\n")
    }

    @Test("rendered patches bypass external diff tools and normalise prefixes")
    func controlledPatch() async throws {
        let repo = try await TempRepo()
        defer { repo.cleanUp() }
        try repo.write("space name.txt", "before\n")
        try await repo.commit("Before")
        try repo.write("space name.txt", "after\n")
        let executable = try #require(Shell.which("true"))
        try await Shell.check("git", ["config", "diff.external", executable], cwd: repo.path)
        try await Shell.check("git", ["config", "diff.mnemonicPrefix", "true"], cwd: repo.path)
        try await Shell.check("git", ["config", "diff.noprefix", "true"], cwd: repo.path)
        let patch = try await Git.patch(
            worktree: repo.path, base: "main", file: ChangedFile(path: "space name.txt", change: .modified)
        )
        #expect(patch.contains("+after"))
        #expect(patch.contains("+++ b/space name.txt"))
        #expect(DiffParser.parse(patch).first?.newPath == "space name.txt")
    }

    @Test("untracked previews accept diff exit one but report an unreadable path")
    func untrackedErrors() async throws {
        let repo = try await TempRepo()
        defer { repo.cleanUp() }
        let file = ChangedFile(path: "new.txt", change: .untracked)
        try repo.write(file.path, "new\n")
        let patch = try await Git.patch(worktree: repo.path, base: "main", file: file)
        #expect(patch.contains("+new"))
        try FileManager.default.removeItem(atPath: repo.path + "/" + file.path)
        await #expect(throws: ShellError.self) {
            try await Git.patch(worktree: repo.path, base: "main", file: file)
        }
    }

    @Test("worktree listings preserve newline paths and lock reasons")
    func nulWorktreeListing() async throws {
        let repo = try await TempRepo()
        let path = TestScratch.unique("worktree-with\nnewline")
        defer {
            try? FileManager.default.removeItem(atPath: path)
            repo.cleanUp()
        }
        try await Git.addWorktree(repo: repo.path, path: path, branch: "newline", base: "main")
        try await Shell.check("git", ["worktree", "lock", "--reason", "reason\ncontinued", "--", path], cwd: repo.path)
        let listed = try await Git.worktrees(of: repo.path)
        let entry = try #require(listed.first { $0.branch == "newline" })
        #expect(WorktreeWatcher.resolve(entry.path) == WorktreeWatcher.resolve(path))
        #expect(entry.lockReason == "reason\ncontinued")
    }

    @Test("linked metadata invalidates its owner and common refs invalidate siblings")
    func metadataWatchRoots() async throws {
        let repo = try await TempRepo()
        defer { repo.cleanUp() }
        let one = TestScratch.unique("first-worktree")
        let two = TestScratch.unique("second-worktree")
        try await Git.addWorktree(repo: repo.path, path: one, branch: "one", base: "main")
        try await Git.addWorktree(repo: repo.path, path: two, branch: "two", base: "main")
        let first = try #require(Git.repositoryPaths(in: one))
        let second = try #require(Git.repositoryPaths(in: two))
        #expect(first.commonDirectory == second.commonDirectory)
        #expect(first.gitDirectory != second.gitDirectory)
        let metadata = WorktreeWatcher.metadataRoots(for: [one, two])
        let local = WorktreeWatcher.metadataWorktrees(
            changed: [WorktreeWatcher.resolve(first.gitDirectory) + "/index"], metadata: metadata
        )
        #expect(local == [one])
        let shared = WorktreeWatcher.metadataWorktrees(
            changed: [WorktreeWatcher.resolve(first.commonDirectory) + "/refs/heads/main"], metadata: metadata
        )
        #expect(shared == [one, two])
        let ignored = WorktreeWatcher.metadataWorktrees(changed: [
            WorktreeWatcher.resolve(first.commonDirectory) + "/objects/ab/object",
            WorktreeWatcher.resolve(first.commonDirectory) + "/refs/bloom/checkpoints/turn/worktree",
            WorktreeWatcher.resolve(first.commonDirectory) + "/logs/refs/bloom/checkpoints/turn/worktree",
            WorktreeWatcher.resolve(first.gitDirectory) + "/bloom-snapshot-turn-index",
            WorktreeWatcher.resolve(first.gitDirectory) + "/bloom-restore-temporary",
        ], metadata: metadata)
        #expect(ignored.isEmpty)
        let coalesced = WorktreeWatcher.metadataWorktrees(
            changed: [WorktreeWatcher.resolve(first.commonDirectory) + "/refs"], metadata: metadata
        )
        #expect(coalesced == [one, two])
    }

    @Test("a write during a read survives that read's completion and failures stay due")
    func invalidationDuringRefresh() {
        let id = WorkspaceID("worktree")
        var invalidations = DiffRefreshInvalidations()
        invalidations.record([id])
        let oldRead = invalidations.generation(for: id)
        invalidations.record([id])
        invalidations.finish(id, generation: oldRead, succeeded: true)
        #expect(invalidations.pending == [id])
        let currentRead = invalidations.generation(for: id)
        invalidations.finish(id, generation: currentRead, succeeded: false)
        #expect(invalidations.pending == [id])
        invalidations.finish(id, generation: currentRead, succeeded: true)
        #expect(invalidations.pending.isEmpty)
    }

    @Test("fork publication settings remain separate from the base and survive upstream changes")
    func remoteContext() async throws {
        let repo = try await TempRepo()
        defer { repo.cleanUp() }
        for (key, value) in [
            ("remote.upstream.url", "https://example.invalid/organisation/project.git"),
            ("remote.fork.url", "https://example.invalid/person/project.git"),
            ("branch.main.remote", "upstream"),
            ("branch.main.merge", "refs/heads/main"),
            ("remote.pushDefault", "upstream"),
            ("branch.feature.pushRemote", "fork"),
            ("branch.feature.remote", "upstream"),
            ("branch.feature.merge", "refs/heads/main"),
        ] { try await Shell.check("git", ["config", key, value], cwd: repo.path) }
        let context = try await Git.repositoryContext(in: repo.path, baseBranch: "main", branch: "feature")
        #expect(context.baseRemote == "upstream")
        #expect(context.publishRemote == "fork")
        #expect(context.publishBranch == "feature")
        try await Git.recordBase(context, for: "feature", in: repo.path)
        try await Shell.check("git", ["config", "branch.feature.remote", "fork"], cwd: repo.path)
        try await Shell.check("git", ["config", "branch.feature.merge", "refs/heads/feature"], cwd: repo.path)
        let afterPush = try await Git.repositoryContext(in: repo.path, branch: "feature")
        #expect(afterPush.baseTrackingRef == "refs/remotes/upstream/main")
        #expect(afterPush.publishTrackingRef == "refs/remotes/fork/feature")
    }

    @Test("fetch and baseline use a configured non-origin base")
    func nonOriginBaseline() async throws {
        let remote = try await TempRepo()
        let repo = try await TempRepo()
        defer { remote.cleanUp(); repo.cleanUp() }
        try remote.write("remote.txt", "new base\n")
        try await remote.commit("New base")
        try await Shell.check("git", ["remote", "add", "upstream", remote.path], cwd: repo.path)
        try await Shell.check("git", ["config", "branch.main.remote", "upstream"], cwd: repo.path)
        let fetched = await Git.fetch("main", in: repo.path)
        #expect(fetched)
        let worktree = TestScratch.unique("upstream-feature")
        try await Git.addWorktree(repo: repo.path, path: worktree, branch: "feature", base: "upstream/main")
        let baseline = try await Git.baseline("main", in: worktree)
        #expect(baseline == (try await Git.headSHA(of: remote.path)))
        let branches = WorkspaceCheckoutPlan.offeredBranches(
            local: [], remote: ["upstream/topic"], defaultBranch: "main", remoteNames: ["upstream"]
        )
        #expect(branches.first?.remoteName == "upstream")
    }

    @Test("repository context preserves a custom default instead of inventing main")
    func customDefaultBranch() async throws {
        let repo = try await TempRepo(defaultBranch: "release")
        defer { repo.cleanUp() }
        let context = try await Git.repositoryContext(in: repo.path)
        #expect(context.baseBranch == "release")
        #expect(try await Git.defaultBranch(of: repo.path) == "release")
    }

    @Test("a synthetic PR ref needs an explicit publication remote")
    func reviewRefPublication() {
        var config = [
            "remote.origin.url": "https://github.com/organisation/project.git",
            "remote.fork.url": "https://github.com/person/project.git",
            "branch.feature.remote": "origin",
            "branch.feature.merge": "refs/pull/123/head",
        ]
        let review = GitRepositoryContext.resolve(config: config, base: "main", branch: "feature")
        #expect(review.baseRemote == "origin")
        #expect(review.publishRemote == nil)
        config["branch.feature.pushremote"] = "fork"
        let publishable = GitRepositoryContext.resolve(config: config, base: "main", branch: "feature")
        #expect(publishable.publishRemote == "fork")
        #expect(publishable.publishTrackingRef == "refs/remotes/fork/feature")
    }

    @Test("submodule-only setup records failure, retains the workspace, and supports retry")
    func submoduleReadinessAndRetry() async throws {
        let submodule = try await TempRepo()
        let repo = try await TempRepo()
        defer { submodule.cleanUp(); repo.cleanUp() }
        try await Shell.check("git", ["-c", "protocol.file.allow=always", "submodule", "add", submodule.path, "shared"], cwd: repo.path)
        try await repo.commit("Submodule")
        let store = try makeTestStore("submodule-readiness")
        let manager = WorkspaceManager(store: store)
        let registered = try await manager.addRepository(at: repo.path)
        let started = try await manager.start(WorkspaceStartRequest(
            repo: registered, prompt: "Prepare submodules", origin: .user, opensSession: false
        ))
        #expect(started.workspace.setupState == .pending)
        let first = await manager.runSetup(workspace: started.workspace, repo: registered, port: 0) { _ in }
        #expect(!first)
        let failed = try #require(try await store.workspace(id: started.workspace.id))
        #expect(failed.setupState == .failed)
        #expect(failed.setupLog.contains("Submodule setup failed"))
        #expect(FileManager.default.fileExists(atPath: failed.path))
        // A local fixture needs explicit file transport permission for its initial clone.
        // This command changes no global policy; production setup must respect Git's refusal.
        try await Shell.check("git", ["-c", "protocol.file.allow=always", "submodule", "update", "--init", "--recursive"], cwd: failed.path)
        let retried = await manager.runSetup(workspace: failed, repo: registered, port: 0) { _ in }
        #expect(retried)
        let ready = try #require(try await store.workspace(id: failed.id))
        #expect(ready.setupState == .succeeded)
        let status = try await Shell.check("git", ["submodule", "status"], cwd: ready.path)
        #expect(status.stdout.hasPrefix(" "))
        let restored = WorkspaceSetupPolicy.deferred.initialState(script: nil, hasSubmodules: true)
        #expect(restored == .pending)
    }

    @Test("an unresolved rewind blocks forced archive and parent deletion before side effects")
    func rewindBlocksRemoval() async throws {
        let repo = try await TempRepo()
        defer { repo.cleanUp() }
        try repo.write(".conductor/settings.toml", """
        [scripts]
        archive = 'touch archive-ran'
        setup = 'touch setup-ran'
        """)
        let store = try makeTestStore("rewind-archive")
        let manager = WorkspaceManager(store: store)
        let registered = try await manager.addRepository(at: repo.path)
        let workspace = try await manager.createWorkspace(repo: registered, prompt: "Recovery")
        var session = Session(workspaceID: workspace.id)
        session.archivedAt = Date()
        session = try await store.upsert(session)
        let snapshot = try await Git.captureSnapshot(in: workspace.path, sessionID: session.id)
        let checkpoint = TurnCheckpoint(sessionID: session.id, startSeq: 0, before: snapshot)
        let journal = CheckpointRewind(checkpoint: checkpoint, recovery: snapshot, restoringFiles: true)
        try await store.saveCheckpointRewind(journal)

        let output = LineCollector()
        for _ in 0..<2 {
            let ran = await manager.runSetup(
                workspace: workspace, repo: registered, port: 0,
                onExit: { output.append("exit: \($0)") }, onOutput: { output.append($0) }
            )
            #expect(!ran)
        }
        let refused = try #require(try await store.workspace(id: workspace.id))
        #expect(refused.setupState == workspace.setupState)
        #expect(refused.setupLog == workspace.setupLog)
        #expect(output.joined.contains("interrupted rewind"))
        #expect(!output.joined.contains("exit:"))
        #expect(!FileManager.default.fileExists(atPath: workspace.path + "/setup-ran"))

        await #expect(throws: WorkspaceError.self) {
            try await manager.archive(workspace: workspace, repo: registered, force: true)
        }
        await #expect(throws: WorkspaceError.self) { try await store.deleteWorkspace(id: workspace.id) }
        await #expect(throws: WorkspaceError.self) { try await store.deleteRepo(id: registered.id) }
        let objection = await WorkspaceArchiveSafety.objection(to: workspace, excusing: nil, store: store)
        #expect(objection?.contains("rewind") == true)
        #expect(FileManager.default.fileExists(atPath: workspace.path))
        #expect(!FileManager.default.fileExists(atPath: workspace.path + "/archive-ran"))
        #expect(await Git.revision(of: snapshot.worktreeRef, in: workspace.path) != nil)
        #expect(try await store.workspace(id: workspace.id)?.state == .active)
    }

    @Test("setup and rewind reservations exclude each other before any awaited state check")
    func setupAndRewindReservation() async throws {
        let repo = try await TempRepo()
        defer { repo.cleanUp() }
        try repo.write(".conductor/settings.toml", """
        [scripts]
        setup = 'touch setup-ran'
        """)
        let store = try makeTestStore("setup-reservation")
        let manager = WorkspaceManager(store: store)
        let registered = try await manager.addRepository(at: repo.path)
        let workspace = try await manager.createWorkspace(repo: registered, prompt: "Reserve setup")
        let session = try await store.upsert(Session(workspaceID: workspace.id))
        let checkpoint = TurnCheckpoint(sessionID: session.id, startSeq: 0, before: GitSnapshot(sessionID: session.id))
        let setup = try #require(WorkspaceOperationLease.acquire(in: workspace.path, operation: .setup))
        defer { setup.release() }
        #expect(WorkspaceOperationLease.acquire(in: workspace.path + "/.", operation: .rewind) == nil)
        await #expect(throws: SnapshotFailure.self) {
            try await TurnCheckpointStore(store: store).prepareRewind(
                checkpoint: checkpoint, cwd: workspace.path, restoringFiles: false
            )
        }
        await #expect(throws: SnapshotFailure.self) {
            try await store.saveCheckpointRewind(CheckpointRewind(checkpoint: checkpoint, recovery: nil, restoringFiles: false))
        }
        setup.release()

        let rewind = try #require(WorkspaceOperationLease.acquire(in: workspace.path, operation: .rewind))
        defer { rewind.release() }
        let ran = await manager.runSetup(workspace: workspace, repo: registered, port: 0) { _ in }
        #expect(!ran)
        #expect(!FileManager.default.fileExists(atPath: workspace.path + "/setup-ran"))
        #expect(try await store.workspace(id: workspace.id)?.setupState == workspace.setupState)
    }
}
