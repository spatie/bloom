import Testing
import Foundation
@testable import BloomCore

/// The marker that keeps Spotlight out of the worktrees.
///
/// Whether `mds` honours the file is Apple's half and is not assertable from here, so this suite
/// asserts Bloom's half, which is the half that can go wrong quietly: the file is written where it
/// is meant to be, an existing one of that name survives untouched, and a directory that refuses
/// the write is reported rather than thrown. Nothing here goes near the real workspaces root: every
/// test builds its own directory under the temporary directory and removes it.
@Suite("Marking a directory so Spotlight leaves it alone")
struct SpotlightExclusionTests {
    private func temporaryDirectory() -> String {
        let base = NSTemporaryDirectory() + "bloom-spotlight-test-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        return base
    }

    @Test("the marker sits inside the directory, under the name Spotlight reads")
    func markerPathIsInsideTheDirectory() {
        #expect(SpotlightExclusion.markerPath(in: "/a/b") == "/a/b/.metadata_never_index")
        #expect(SpotlightExclusion.markerName == ".metadata_never_index")
    }

    @Test("marking an unmarked directory writes an empty file")
    func markingWritesIt() {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(atPath: directory) }

        let outcome = SpotlightExclusion.mark(directory)

        #expect(outcome == .written)
        let marker = SpotlightExclusion.markerPath(in: directory)
        #expect(FileManager.default.fileExists(atPath: marker))
        #expect(try! Data(contentsOf: URL(filePath: marker)).isEmpty)
    }

    @Test("marking twice writes once")
    func markingIsIdempotent() {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(atPath: directory) }

        #expect(SpotlightExclusion.mark(directory) == .written)
        #expect(SpotlightExclusion.mark(directory) == .alreadyMarked)

        let entries = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
        #expect(entries == [SpotlightExclusion.markerName])
    }

    /// The rule this was written for. The owner made one of these by hand before asking Bloom to
    /// do it, and a person who puts a file somewhere gets to keep it.
    @Test("a marker somebody else wrote is left exactly as it was")
    func anExistingMarkerIsNotOverwritten() {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let marker = SpotlightExclusion.markerPath(in: directory)
        try! "put here by hand\n".write(toFile: marker, atomically: true, encoding: .utf8)

        let outcome = SpotlightExclusion.mark(directory)

        #expect(outcome == .alreadyMarked)
        #expect(try! String(contentsOfFile: marker, encoding: .utf8) == "put here by hand\n")
    }

    /// The launch call. An installation with no workspaces root yet has nothing to mark and is not
    /// given one, because a Bloom that has never cut a worktree should not be making directories in
    /// somebody's home for a folder they may never use.
    @Test("a directory that is not there is left absent rather than created")
    func anAbsentDirectoryIsNotCreated() {
        let directory = temporaryDirectory() + "/never-made"

        let outcome = SpotlightExclusion.mark(directory)

        #expect(outcome == .noSuchDirectory)
        #expect(!FileManager.default.fileExists(atPath: directory))
    }

    /// The creation call, and the ordering it exists for: the marker has to be in place before the
    /// first worktree lands, so this makes the directory rather than waiting for git to.
    @Test("asked to, it makes the directory and marks it in one go")
    func creatingItMakesTheDirectory() {
        let base = temporaryDirectory()
        defer { try? FileManager.default.removeItem(atPath: base) }
        let directory = base + "/bloom/workspaces"

        let outcome = SpotlightExclusion.mark(directory, creatingIt: true)

        #expect(outcome == .written)
        #expect(FileManager.default.fileExists(atPath: SpotlightExclusion.markerPath(in: directory)))
    }

    /// It is an optimisation, so nothing it cannot do is allowed to become anybody's problem. A
    /// path under `/dev/null` cannot be a directory on any Mac, and asking for one there has to
    /// come back as a value rather than as a throw or a crash.
    @Test("somewhere it cannot write comes back as an outcome, not as a failure")
    func aRefusedWriteIsSwallowed() {
        #expect(SpotlightExclusion.mark("/dev/null/nowhere") == .noSuchDirectory)
        #expect(SpotlightExclusion.mark("/dev/null/nowhere", creatingIt: true) == .noSuchDirectory)
    }

    /// A file where the directory should be is the same answer, and it is worth its own case
    /// because `fileExists` alone says yes to it.
    @Test("a file wearing the directory's name is not marked")
    func aFileIsNotADirectory() {
        let base = temporaryDirectory()
        defer { try? FileManager.default.removeItem(atPath: base) }
        let path = base + "/workspaces"
        try! "not a directory".write(toFile: path, atomically: true, encoding: .utf8)

        #expect(SpotlightExclusion.mark(path) == .noSuchDirectory)
        #expect(try! String(contentsOfFile: path, encoding: .utf8) == "not a directory")
    }

    /// The live call names the root new worktrees are cut in, and nothing else. Asserted on the
    /// path rather than by running it, because running it would write into the owner's own
    /// `~/bloom/workspaces` from a test.
    @Test("the directory this Mac marks is the workspaces root")
    func theLiveDirectoryIsTheWorkspacesRoot() {
        let expected = WorkspaceManager.workspacesRoot.path + "/.metadata_never_index"

        #expect(SpotlightExclusion.markerPath(in: WorkspaceManager.workspacesRoot.path) == expected)
    }
}
