import Foundation
import Testing
@testable import BloomCore

@Suite("Snapshot file summaries", .tags(.git), .scratchDirectory)
struct SnapshotSummaryTests {
    @Test("historical net counts include shell writes, repeated edits, newline renames and binary changes")
    func historicalNetChanges() async throws {
        let repo = try await TempRepo()
        defer { repo.cleanUp() }
        try repo.write("repeated.txt", "before\n")
        try repo.write("old\nname.txt", "unchanged contents\n")
        try Data([0, 1, 2]).write(to: URL(fileURLWithPath: repo.path + "/binary.bin"))
        try await repo.commit("Before turn")
        let session = SessionID.new()
        let before = try await Git.captureSnapshot(in: repo.path, sessionID: session)

        try await Shell.check("/bin/sh", ["-c", """
        printf 'intermediate\nmore intermediate\n' > repeated.txt
        printf 'after\n' > repeated.txt
        printf 'only written by the shell\n' > shell-only.txt
        """], cwd: repo.path)
        try FileManager.default.moveItem(atPath: repo.path + "/old\nname.txt", toPath: repo.path + "/renamed\nname.txt")
        try Data([0, 3, 4]).write(to: URL(fileURLWithPath: repo.path + "/binary.bin"))
        let after = try await Git.captureSnapshot(in: repo.path, sessionID: session)

        try await Shell.check("git", ["config", "diff.external", "/usr/bin/true"], cwd: repo.path)
        let files = try await Git.snapshotFiles(from: before, to: after, in: repo.path)
        let byPath = Dictionary(uniqueKeysWithValues: files.map { ($0.path, $0) })
        #expect(files.count == 4)
        #expect(byPath["repeated.txt"]?.additions == 1)
        #expect(byPath["repeated.txt"]?.deletions == 1)
        #expect(byPath["shell-only.txt"]?.change == .added)
        #expect(byPath["shell-only.txt"]?.additions == 1)
        #expect(byPath["renamed\nname.txt"]?.change == .renamed)
        #expect(byPath["renamed\nname.txt"]?.oldPath == "old\nname.txt")
        #expect(byPath["renamed\nname.txt"]?.additions == 0)
        #expect(byPath["binary.bin"]?.isBinary == true)
        #expect(files.reduce(0) { $0 + $1.additions } == 2)
        #expect(files.reduce(0) { $0 + $1.deletions } == 1)

        try repo.write("repeated.txt", "another turn\nmore work\n")
        try repo.write("later.txt", "not this turn\n")
        let stillHistorical = try await Git.snapshotFiles(from: before, to: after, in: repo.path)
        #expect(stillHistorical == files)
    }

    @Test("equal snapshots have no changes and unsafe identifiers cannot become revisions")
    func emptyAndInvalidSummary() async throws {
        let repo = try await TempRepo()
        defer { repo.cleanUp() }
        let session = SessionID.new()
        let snapshot = try await Git.captureSnapshot(in: repo.path, sessionID: session)
        #expect(try await Git.snapshotFiles(from: snapshot, to: snapshot, in: repo.path).isEmpty)
        let invalid = GitSnapshot(id: GitSnapshotID("../../heads/main"), sessionID: session)
        await #expect(throws: SnapshotFailure.self) {
            try await Git.snapshotFiles(from: invalid, to: snapshot, in: repo.path)
        }
    }
}
