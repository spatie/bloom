import Foundation
import Testing
@testable import BloomCore

@Suite("Turn checkpoints", .tags(.git), .scratchDirectory)
struct TurnCheckpointTests {
    @Test("capture preserves the real index and records net shell edits")
    func netChanges() async throws {
        let repo = try await TempRepo()
        defer { repo.cleanUp() }
        try repo.write("file.txt", "one\n")
        try await repo.commit("Initial")
        try repo.write("file.txt", "staged\n")
        try await Shell.check("git", ["add", "file.txt"], cwd: repo.path)
        try repo.write("file.txt", "before\n")
        let indexPath = repo.path + "/.git/index"
        let index = try Data(contentsOf: URL(fileURLWithPath: indexPath))
        let session = SessionID.new()
        let before = try await Git.captureSnapshot(in: repo.path, sessionID: session)
        #expect(try Data(contentsOf: URL(fileURLWithPath: indexPath)) == index)
        try await Shell.check("/bin/sh", ["-c", "printf 'after\\n' > file.txt; printf 'new\\n' > new.txt"], cwd: repo.path)
        let after = try await Git.captureSnapshot(in: repo.path, sessionID: session)
        let patch = try await Git.snapshotDiff(from: before, to: after, in: repo.path)
        #expect(patch.contains("-before"))
        #expect(patch.contains("+after"))
        #expect(patch.contains("+new"))
        #expect(try Data(contentsOf: URL(fileURLWithPath: indexPath)) == index)
        try repo.write("file.txt", "later\n")
        #expect(try await Git.snapshotDiff(from: before, to: after, in: repo.path) == patch)
    }

    @Test("restore recovers partial staging, untracked files and preserves ignored files")
    func restoresStaging() async throws {
        let repo = try await TempRepo()
        defer { repo.cleanUp() }
        try repo.write("file.txt", "committed\n")
        try repo.write(".gitignore", "ignored.txt\n")
        try await repo.commit("Initial")
        try repo.write("file.txt", "staged\n")
        try await Shell.check("git", ["add", "file.txt"], cwd: repo.path)
        try repo.write("file.txt", "unstaged\n")
        try repo.write("[id].txt", "untracked\n")
        try repo.write("ignored.txt", "ignored\n")
        let session = SessionID.new()
        let before = try await Git.captureSnapshot(in: repo.path, sessionID: session)
        try repo.write("file.txt", "later\n")
        try repo.write("[id].txt", "later\n")
        try repo.write("new.txt", "later untracked\n")
        let recovery = try await Git.captureSnapshot(in: repo.path, sessionID: session)
        try await Git.restoreSnapshot(before, in: repo.path)
        #expect(repo.read("file.txt") == "unstaged\n")
        #expect(repo.read("[id].txt") == "untracked\n")
        #expect(!repo.exists("new.txt"))
        #expect(repo.read("ignored.txt") == "ignored\n")
        let staged = try await Shell.check("git", ["show", ":file.txt"], cwd: repo.path)
        #expect(staged.stdout == "staged\n")
        let untracked = try await Shell.check("git", ["ls-files", "--others", "--exclude-standard"], cwd: repo.path)
        #expect(untracked.stdout.contains("[id].txt"))
        try await Git.restoreSnapshot(recovery, in: repo.path)
        #expect(repo.read("new.txt") == "later untracked\n")
    }

    @Test("snapshot diffs select a literal path and bypass external diff configuration")
    func literalDiff() async throws {
        let repo = try await TempRepo()
        defer { repo.cleanUp() }
        for file in ["[id].txt", "i.txt"] { try repo.write(file, "before\n") }
        try await repo.commit("Before")
        let session = SessionID.new()
        let before = try await Git.captureSnapshot(in: repo.path, sessionID: session)
        for file in ["[id].txt", "i.txt"] { try repo.write(file, "after\n") }
        let after = try await Git.captureSnapshot(in: repo.path, sessionID: session)
        try await Shell.check("git", ["config", "diff.external", "/usr/bin/true"], cwd: repo.path)
        let patch = try await Git.snapshotDiff(from: before, to: after, in: repo.path, path: "[id].txt")
        #expect(patch.contains("+after"))
        #expect(DiffParser.parse(patch).count == 1)
    }

    @Test("an ignored file cannot be overwritten by restore")
    func ignoredCollision() async throws {
        let repo = try await TempRepo()
        defer { repo.cleanUp() }
        try repo.write("valuable.txt", "snapshot\n")
        let session = SessionID.new()
        let target = try await Git.captureSnapshot(in: repo.path, sessionID: session)
        try repo.write(".gitignore", "valuable.txt\n")
        try repo.write("valuable.txt", "outside snapshot\n")
        await #expect(throws: SnapshotFailure.self) { try await Git.restoreSnapshot(target, in: repo.path) }
        #expect(repo.read("valuable.txt") == "outside snapshot\n")
    }

    @Test("checkpoint metadata and an interrupted rewind survive a Store reopen")
    func persistence() async throws {
        let path = TestScratch.path("checkpoints.sqlite")
        let store = try Store(path: path)
        let session = SessionID.new()
        var checkpoint = TurnCheckpoint(sessionID: session, startSeq: 5, before: GitSnapshot(sessionID: session))
        checkpoint.endSeq = 12
        checkpoint.providerTurnID = "provider-turn"
        try await store.saveTurnCheckpoint(checkpoint)
        var journal = CheckpointRewind(checkpoint: checkpoint, recovery: GitSnapshot(sessionID: session), restoringFiles: true)
        journal.stage = .filesRestored
        try await store.saveCheckpointRewind(journal)
        let reopened = try Store(path: path)
        #expect(try await reopened.turnCheckpoints(sessionID: session) == [checkpoint])
        #expect(try await reopened.checkpointRewind(sessionID: session) == journal)
        let removed = try await reopened.removeTurnCheckpoints(sessionID: session, fromSeq: 5)
        #expect(removed == [checkpoint])
        #expect(try await reopened.checkpointRewind(sessionID: session) == journal)
    }
}

extension TurnCheckpointTests {
    @Test("intent-to-add and index flags survive restore, while snapshots read actual files")
    func preservesIndexMetadata() async throws {
        let repo = try await TempRepo()
        defer { repo.cleanUp() }
        try repo.write("assumed.txt", "committed\n")
        try repo.write("skipped.txt", "committed\n")
        try await repo.commit("Initial")
        try repo.write("intent\n[id].txt", "new intent\n")
        try await Shell.check("git", ["add", "-N", "--", "intent\n[id].txt"], cwd: repo.path)
        try await Shell.check("git", ["update-index", "--assume-unchanged", "--", "assumed.txt"], cwd: repo.path)
        try await Shell.check("git", ["update-index", "--skip-worktree", "--", "skipped.txt"], cwd: repo.path)
        try repo.write("assumed.txt", "actual assumed\n")
        try repo.write("skipped.txt", "actual skipped\n")
        let flags = try await Shell.check("git", ["ls-files", "-v", "-z"], cwd: repo.path)
        let staged = try await Shell.check("git", ["diff", "--cached", "--raw", "-z"], cwd: repo.path)
        let snapshot = try await Git.captureSnapshot(in: repo.path, sessionID: .new())
        try repo.write("assumed.txt", "later\n")
        try repo.write("skipped.txt", "later\n")
        try await Shell.check("git", ["add", "--", "intent\n[id].txt"], cwd: repo.path)
        try await Git.restoreSnapshot(snapshot, in: repo.path)
        #expect(repo.read("assumed.txt") == "actual assumed\n")
        #expect(repo.read("skipped.txt") == "actual skipped\n")
        #expect(try await Shell.check("git", ["ls-files", "-v", "-z"], cwd: repo.path).stdout == flags.stdout)
        #expect(try await Shell.check("git", ["diff", "--cached", "--raw", "-z"], cwd: repo.path).stdout == staged.stdout)
        let intent = try await Shell.check("git", ["diff", "--raw", "-z", "--", "intent\n[id].txt"], cwd: repo.path)
        #expect(intent.stdout.contains(" A\0"))
    }

    @Test("missing snapshot index fails before changing files")
    func missingIndexFailsBeforeMutation() async throws {
        let repo = try await TempRepo()
        defer { repo.cleanUp() }
        try repo.write("file", "before")
        let snapshot = try await Git.captureSnapshot(in: repo.path, sessionID: .new())
        try repo.write("file", "keep this")
        try await Shell.check("git", ["update-ref", "-d", snapshot.rawIndexRef], cwd: repo.path)
        await #expect(throws: SnapshotFailure.self) { try await Git.restoreSnapshot(snapshot, in: repo.path) }
        #expect(repo.read("file") == "keep this")
    }

    @Test("a missing index remains missing after restore")
    func restoresMissingIndex() async throws {
        let repo = try await TempRepo()
        defer { repo.cleanUp() }
        try repo.write("file", "untracked")
        try FileManager.default.removeItem(atPath: repo.path + "/.git/index")
        #expect(!repo.exists(".git/index"))
        let snapshot = try await Git.captureSnapshot(in: repo.path, sessionID: .new())
        try await Shell.check("git", ["add", "file"], cwd: repo.path)
        try repo.write("file", "changed")
        try await Git.restoreSnapshot(snapshot, in: repo.path)
        #expect(repo.read("file") == "untracked")
        #expect(!repo.exists(".git/index"))
    }
}

extension TurnCheckpointTests {
    @Test("stale journal updates cannot replace a later rewind")
    func journalOwnership() async throws {
        let store = try makeTestStore("rewind-journal-ownership")
        let session = SessionID.new()
        let checkpoint = TurnCheckpoint(sessionID: session, startSeq: 1, before: GitSnapshot(sessionID: session))
        var first = CheckpointRewind(checkpoint: checkpoint, recovery: nil, restoringFiles: false)
        try await store.saveCheckpointRewind(first)
        first.stage = .complete
        try await store.saveCheckpointRewind(first)
        let second = CheckpointRewind(checkpoint: checkpoint, recovery: nil, restoringFiles: false)
        try await store.saveCheckpointRewind(second)
        await #expect(throws: SnapshotFailure.self) { try await store.saveCheckpointRewind(first) }
        #expect(try await store.checkpointRewind(sessionID: session)?.token == second.token)
    }

    @Test("replacing a completed rewind retires its unretained recovery refs")
    func supersededRecoveryCleanup() async throws {
        let repo = try await TempRepo()
        defer { repo.cleanUp() }
        let store = try makeTestStore("rewind-recovery-cleanup")
        let service = TurnCheckpointStore(store: store)
        let session = SessionID.new()
        let checkpoint = try await service.begin(sessionID: session, cwd: repo.path, startSeq: 1)
        var first = try await service.prepareRewind(checkpoint: checkpoint, cwd: repo.path, restoringFiles: true)
        let oldRecovery = try #require(first.recovery)
        first.stage = .complete
        try await service.markRewind(first)
        _ = try await service.prepareRewind(checkpoint: checkpoint, cwd: repo.path, restoringFiles: true)
        let old = try await Shell.run("git", ["rev-parse", "--verify", oldRecovery.rawIndexRef], cwd: repo.path)
        #expect(!old.ok)
        let retained = try await Shell.run("git", ["rev-parse", "--verify", checkpoint.before.rawIndexRef], cwd: repo.path)
        #expect(retained.ok)
    }
}

extension TurnCheckpointTests {
    @Test("steering and workspace-free messages have no checkpoint association")
    func absentCheckpointLink() async throws {
        let store = try makeTestStore("checkpoint-no-association")
        let session = SessionID.new()
        let linked = try await store.linkTurnCheckpoint(sessionID: session, startSeq: 4, providerTurnID: "steered")
        #expect(!linked)
        #expect(try await store.turnCheckpoints(sessionID: session).isEmpty)
    }

    @Test("a reused message sequence after rewind belongs to the new snapshot")
    func sequenceReuseAfterRewind() async throws {
        let store = try makeTestStore("checkpoint-reused-sequence")
        let session = SessionID.new()
        let old = TurnCheckpoint(sessionID: session, startSeq: 4, before: GitSnapshot(sessionID: session))
        try await store.saveTurnCheckpoint(old)
        try await store.linkTurnCheckpoint(sessionID: session, startSeq: 4, providerTurnID: "old-turn")
        try await store.removeTurnCheckpoints(sessionID: session, fromSeq: 4)
        var replacement = TurnCheckpoint(sessionID: session, startSeq: 4, before: GitSnapshot(sessionID: session))
        replacement.endSeq = 8
        replacement.after = GitSnapshot(sessionID: session)
        try await store.saveTurnCheckpoint(replacement)
        try await store.linkTurnCheckpoint(sessionID: session, startSeq: 4, providerTurnID: "new-turn")
        let saved = try #require(try await store.turnCheckpoints(sessionID: session).first)
        #expect(saved.id == replacement.id)
        #expect(saved.providerTurnID == "new-turn")
        #expect(saved.after == replacement.after)
    }

    @Test("provider linkage survives completion and stale checkpoint writes in either order")
    func lateProviderLinkPreservesCompletedCheckpoint() async throws {
        for linkFirst in [false, true] {
            let store = try makeTestStore("checkpoint-link-race")
            let session = SessionID.new()
            let original = TurnCheckpoint(sessionID: session, startSeq: 3, before: GitSnapshot(sessionID: session))
            try await store.saveTurnCheckpoint(original)
            var completed = original
            completed.after = GitSnapshot(sessionID: session)
            completed.endSeq = 9
            if linkFirst { try await store.linkTurnCheckpoint(sessionID: session, startSeq: 3, providerTurnID: "turn") }
            try await store.saveTurnCheckpoint(completed)
            if !linkFirst { try await store.linkTurnCheckpoint(sessionID: session, startSeq: 3, providerTurnID: "turn") }
            try await store.saveTurnCheckpoint(original)
            let saved = try #require(await store.turnCheckpoints(sessionID: session).first)
            #expect(saved.after == completed.after)
            #expect(saved.endSeq == 9)
            #expect(saved.providerTurnID == "turn")
        }
    }
}

extension TurnCheckpointTests {
    @Test("unsupported file restores never create a blocking rewind journal", arguments: ["sparse", "submodule", "ignored"])
    func rejectedRestoreDoesNotPrepareARewind(_ obstruction: String) async throws {
        let repo = try await TempRepo()
        let nested = try await TempRepo()
        defer { repo.cleanUp(); nested.cleanUp() }
        let store = try makeTestStore("rewind-preflight")
        let session = try await store.upsert(Session(workspaceID: nil, agentKind: .codex))
        let service = TurnCheckpointStore(store: store)
        try repo.write("valuable.txt", "snapshot content")
        if obstruction == "submodule" {
            try FileManager.default.copyItem(atPath: nested.path, toPath: repo.path + "/nested")
        }
        let checkpoint = try await service.begin(sessionID: session.id, cwd: repo.path, startSeq: 1)
        if obstruction == "sparse" {
            try await Shell.check("git", ["config", "core.sparseCheckout", "true"], cwd: repo.path)
        } else if obstruction == "ignored" {
            try repo.write(".gitignore", "valuable.txt\n")
        }
        try repo.write("valuable.txt", "keep this content")
        let index = try Data(contentsOf: URL(fileURLWithPath: repo.path + "/.git/index"))
        let refs = try await Shell.check("git", ["for-each-ref", "--format=%(refname)", "refs/bloom/checkpoints"], cwd: repo.path)
        await #expect(throws: SnapshotFailure.self) {
            try await service.prepareRewind(checkpoint: checkpoint, cwd: repo.path, restoringFiles: true)
        }
        #expect(try await service.pendingRewind(sessionID: session.id) == nil)
        #expect(try await store.checkpointRewind(sessionID: session.id) == nil)
        #expect(repo.read("valuable.txt") == "keep this content")
        #expect(try Data(contentsOf: URL(fileURLWithPath: repo.path + "/.git/index")) == index)
        #expect(try await Shell.check("git", ["for-each-ref", "--format=%(refname)", "refs/bloom/checkpoints"], cwd: repo.path).stdout == refs.stdout)
        _ = try await store.enqueueDelivery(Delivery(targetSessionID: session.id, body: "A later message"))
        let waiting = try await store.pendingDeliveries(sessionID: session.id)
        #expect(Delivery.deliverable(from: waiting, hold: .none, on: .codex).count == 1)
        // Conversation-only rewind has no filesystem dependency and deliberately skips preflight.
        let keepFiles = try await service.prepareRewind(checkpoint: checkpoint, cwd: repo.path, restoringFiles: false)
        #expect(keepFiles.recovery == nil)
        #expect(!keepFiles.restoringFiles)
    }
}
