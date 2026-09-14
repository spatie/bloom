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
}
