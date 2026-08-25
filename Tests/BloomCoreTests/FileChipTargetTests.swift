import Testing
import Foundation
@testable import BloomCore

/// Where a file chip's card looks and where its click goes, for the three forms a transcript names
/// a file in.
///
/// The pairing is the whole point: a chip that can be opened is previewed against the worktree,
/// and a chip that cannot is previewed against nothing and previewed absolutely. Splitting those
/// two answers is how a card ends up looking for `/Users/other/repo/notes.md` inside this
/// workspace.
@Suite("File chip target")
struct FileChipTargetTests {
    private static let worktree = "/Users/freek/dev/code/bloom"

    @Test("an absolute path inside the worktree is previewed and opened relative to it")
    func insideTheWorktree() {
        let target = FileChipTarget.resolve(Self.worktree + "/Sources/Bloom/App.swift", in: Self.worktree)
        #expect(target == FileChipTarget(
            path: "Sources/Bloom/App.swift",
            worktree: Self.worktree,
            opens: "Sources/Bloom/App.swift"
        ))
    }

    @Test("a relative path is already what both answers want")
    func alreadyRelative() {
        let target = FileChipTarget.resolve(".bloom/attachments/9JV/shot.png", in: Self.worktree)
        #expect(target == FileChipTarget(
            path: ".bloom/attachments/9JV/shot.png",
            worktree: Self.worktree,
            opens: ".bloom/attachments/9JV/shot.png"
        ))
    }

    @Test("a leading ./ comes off, because the review resolves neither form differently")
    func dotSlash() {
        let target = FileChipTarget.resolve("./Tools/build.sh", in: Self.worktree)
        #expect(target.path == "Tools/build.sh")
        #expect(target.opens == "Tools/build.sh")
    }

    /// The case the whole type exists for. Left to `PromptAttachment.url(in:)` with the workspace's
    /// root still attached, this would be looked for at `<worktree>/Users/freek/Desktop/shot.png`.
    @Test("a file outside the worktree keeps its absolute path and is previewed against nothing", arguments: [
        "/Users/freek/Desktop/shot.png",
        "/Users/freek/dev/code/other/README.md",
        "/tmp/T/CleanShot.jpg",
    ])
    func outsideTheWorktree(path: String) {
        let target = FileChipTarget.resolve(path, in: Self.worktree)
        #expect(target == FileChipTarget(path: path, worktree: "", opens: nil))
    }

    @Test("a path that climbs out of the worktree has nowhere to open")
    func climbsOut() {
        let target = FileChipTarget.resolve("../other/README.md", in: Self.worktree)
        #expect(target.opens == nil)
        #expect(target.worktree.isEmpty)
    }

    /// A workspace whose worktree is not known is every chip's answer at once, and it has to be the
    /// safe one: nothing is resolved against a root that is not there.
    @Test("no worktree means no door")
    func noWorktree() {
        let target = FileChipTarget.resolve("Sources/Bloom/App.swift", in: "")
        #expect(target == FileChipTarget(path: "Sources/Bloom/App.swift", worktree: "", opens: nil))
    }

    /// The file the owner attaches most: a screenshot with spaces and an `@2x` in its name.
    /// `FilePathGuess.relative` asks only `isWellFormed` of it, so the spaces that stop it being
    /// GUESSED as a file never stop it being resolved once something else has said it is one.
    @Test("a screenshot's name survives, spaces and all")
    func screenshot() {
        let path = Self.worktree + "/.bloom/attachments/A1/CleanShot 2026-08-24 at 14.46@2x.jpg"
        let target = FileChipTarget.resolve(path, in: Self.worktree)
        #expect(target.path == ".bloom/attachments/A1/CleanShot 2026-08-24 at 14.46@2x.jpg")
        #expect(target.opens == target.path)
    }
}
