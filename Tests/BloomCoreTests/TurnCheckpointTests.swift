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
        let files = try await Git.snapshotFiles(from: before, to: after, in: repo.path)
        #expect(files.map(\.path) == ["file.txt", "new.txt"])
        #expect(try Data(contentsOf: URL(fileURLWithPath: indexPath)) == index)
    }

    @Test("snapshots read actual files the index says to skip, and leave its flags alone")
    func readsSkippedFiles() async throws {
        let repo = try await TempRepo()
        defer { repo.cleanUp() }
        try repo.write("assumed.txt", "committed\n")
        try repo.write("skipped.txt", "committed\n")
        try await repo.commit("Initial")
        try await Shell.check("git", ["update-index", "--assume-unchanged", "--", "assumed.txt"], cwd: repo.path)
        try await Shell.check("git", ["update-index", "--skip-worktree", "--", "skipped.txt"], cwd: repo.path)
        let flags = try await Shell.check("git", ["ls-files", "-v", "-z"], cwd: repo.path)
        let session = SessionID.new()
        let before = try await Git.captureSnapshot(in: repo.path, sessionID: session)
        try repo.write("assumed.txt", "later\n")
        try repo.write("skipped.txt", "later\n")
        let after = try await Git.captureSnapshot(in: repo.path, sessionID: session)
        let files = try await Git.snapshotFiles(from: before, to: after, in: repo.path)
        #expect(files.map(\.path) == ["assumed.txt", "skipped.txt"])
        #expect(try await Shell.check("git", ["ls-files", "-v", "-z"], cwd: repo.path).stdout == flags.stdout)
    }

    @Test("a worktree in the middle of a conflicted merge can still be captured")
    func conflictedMerge() async throws {
        let repo = try await TempRepo()
        defer { repo.cleanUp() }
        try repo.write("conflict.txt", "base\n")
        try repo.write("clean.txt", "base\n")
        try await repo.commit("Initial")
        try await Shell.check("git", ["checkout", "-q", "-b", "other"], cwd: repo.path)
        try repo.write("conflict.txt", "theirs\n")
        try await repo.commit("Theirs")
        try await Shell.check("git", ["checkout", "-q", "-"], cwd: repo.path)
        try repo.write("conflict.txt", "ours\n")
        try await repo.commit("Ours")
        let merge = try await Shell.run("git", ["merge", "other"], cwd: repo.path)
        #expect(!merge.ok)
        let indexPath = repo.path + "/.git/index"
        let index = try Data(contentsOf: URL(fileURLWithPath: indexPath))
        let session = SessionID.new()
        let before = try await Git.captureSnapshot(in: repo.path, sessionID: session)
        try repo.write("conflict.txt", "resolved\n")
        let after = try await Git.captureSnapshot(in: repo.path, sessionID: session)
        let files = try await Git.snapshotFiles(from: before, to: after, in: repo.path)
        #expect(files.map(\.path) == ["conflict.txt"])
        #expect(try Data(contentsOf: URL(fileURLWithPath: indexPath)) == index)
    }

    @Test("snapshots taken in a worktree are still read from the repository once it is removed")
    func readableAfterWorktreeRemoval() async throws {
        let repo = try await TempRepo()
        defer { repo.cleanUp() }
        let worktree = TestScratch.unique("bloom-snapshot-worktree")
        try await Shell.check("git", ["worktree", "add", "-q", "-b", "archived", worktree], cwd: repo.path)
        let session = SessionID.new()
        let before = try await Git.captureSnapshot(in: worktree, sessionID: session)
        try TempRepo(existing: worktree).write("changed.txt", "after\n")
        let after = try await Git.captureSnapshot(in: worktree, sessionID: session)
        try await Shell.check("git", ["worktree", "remove", "--force", worktree], cwd: repo.path)
        let files = try await Git.snapshotFiles(from: before, to: after, in: repo.path)
        #expect(files.map(\.path) == ["changed.txt"])
    }

    @Test("checkpoint metadata survives a Store reopen")
    func persistence() async throws {
        let path = TestScratch.path("checkpoints.sqlite")
        let store = try Store(path: path)
        let session = SessionID.new()
        var checkpoint = TurnCheckpoint(sessionID: session, startSeq: 5, before: GitSnapshot(sessionID: session))
        checkpoint.endSeq = 12
        checkpoint.after = GitSnapshot(sessionID: session)
        try await store.saveTurnCheckpoint(checkpoint)
        let reopened = try Store(path: path)
        #expect(try await reopened.turnCheckpoints(sessionID: session) == [checkpoint])
    }

    @Test("a stale checkpoint write cannot undo a completed turn")
    func staleWritePreservesCompletedCheckpoint() async throws {
        let store = try makeTestStore("checkpoint-stale-write")
        let session = SessionID.new()
        let original = TurnCheckpoint(sessionID: session, startSeq: 3, before: GitSnapshot(sessionID: session))
        try await store.saveTurnCheckpoint(original)
        var completed = original
        completed.after = GitSnapshot(sessionID: session)
        completed.endSeq = 9
        try await store.saveTurnCheckpoint(completed)
        try await store.saveTurnCheckpoint(original)
        let saved = try #require(await store.turnCheckpoints(sessionID: session).first)
        #expect(saved.after == completed.after)
        #expect(saved.endSeq == 9)
    }

    @Test("a completed turn's file summary survives a reopen and is replaced only for its own snapshot")
    func fileSummary() async throws {
        let path = TestScratch.path("checkpoint-files.sqlite")
        let store = try Store(path: path)
        let session = SessionID.new()
        let original = TurnCheckpoint(sessionID: session, startSeq: 3, before: GitSnapshot(sessionID: session))
        try await store.saveTurnCheckpoint(original)
        var completed = original
        completed.after = GitSnapshot(sessionID: session)
        completed.endSeq = 9
        try await store.saveTurnCheckpoint(completed)
        var summarised = completed
        summarised.files = [TurnFile(path: "Sources/App.swift", additions: 3, deletions: 1)]
        try await store.saveTurnCheckpoint(summarised)

        try await store.saveTurnCheckpoint(completed)
        try await store.saveTurnCheckpoint(original)
        var foreign = original
        foreign.after = GitSnapshot(sessionID: session)
        foreign.endSeq = 9
        foreign.files = [TurnFile(path: "Other.swift", additions: 1, deletions: 0)]
        try await store.saveTurnCheckpoint(foreign)

        let reopened = try Store(path: path)
        #expect(try await reopened.turnCheckpoints(sessionID: session) == [summarised])
    }
}
