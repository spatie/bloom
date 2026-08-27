import Foundation
import Testing
@testable import BloomCore

/// The workspaces root is dozens of checkouts of one repository, every one with a `vendor/` or a
/// `.build/` in it, all of it rewritten by whatever is building right now. Spotlight reindexing
/// that on every write costs CPU for a copy of a tree it has already indexed once.
@Suite("Spotlight exclusion")
struct SpotlightExclusionTests {
    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("spotlight-\(UUID().uuidString)", isDirectory: true)
    }

    /// The point of writing it rather than asking the owner to keep a list in System Settings: a
    /// file travels with the directory, so a fresh machine gets it on the first worktree.
    @Test("a directory that does not exist yet is made and marked")
    func aMissingDirectoryIsMadeAndMarked() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        #expect(SpotlightExclusion.mark(directory))

        let marker = directory.appendingPathComponent(SpotlightExclusion.markerName)
        #expect(FileManager.default.fileExists(atPath: marker.path))
        // Empty on purpose: mds looks at the name and never reads the contents.
        #expect(try Data(contentsOf: marker).isEmpty)
    }

    /// Called on every workspace creation, so it has to be free and silent the second time.
    @Test("marking twice leaves the first marker alone")
    func markingTwiceIsIdempotent() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        #expect(SpotlightExclusion.mark(directory))
        let marker = directory.appendingPathComponent(SpotlightExclusion.markerName)
        try Data("not empty".utf8).write(to: marker)

        #expect(SpotlightExclusion.mark(directory))
        // Untouched rather than rewritten: a marker somebody edited is still a marker, and
        // truncating a file this had no reason to open is how a helper starts losing things.
        #expect(try Data(contentsOf: marker) == Data("not empty".utf8))
    }

    /// Best effort. A root that cannot be written is a directory that gets indexed, which is
    /// where every machine starts, and it must not fail the workspace creation that asked.
    @Test("an unwritable place is reported rather than thrown")
    func anUnwritablePlaceIsReported() {
        #expect(SpotlightExclusion.mark(URL(fileURLWithPath: "/dev/null/nope")) == false)
    }

    /// The name is the whole mechanism, so it is asserted rather than assumed.
    @Test("the marker is the name mds looks for")
    func theMarkerIsTheNameSpotlightLooksFor() {
        #expect(SpotlightExclusion.markerName == ".metadata_never_index")
    }
}
