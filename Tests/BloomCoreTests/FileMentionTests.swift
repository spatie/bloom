import Testing
import Foundation
@testable import BloomCore

/// The rule that decides whether a backticked run of a sent turn is drawn as a file pill or left
/// as a code span.
///
/// Both ends are worth pinning down, and the rejections matter more. A path that stays a code span
/// looks exactly as it looked yesterday; a piece of prose that becomes a pill is the app telling
/// the reader that a word in their own sentence is a file. So the identifiers below are as much a
/// part of the contract as the paths are.
@Suite("File mention")
struct FileMentionTests {
    // MARK: - What names a file

    @Test("a path names a file", arguments: [
        ".bloom/scratch/pr-instructions.md",
        ".bloom/pr-instructions.md",
        "Sources/Bloom/Views/Transcript/UserTurnRowView.swift",
        "app/Http/Controllers/BeaconController.php",
        "/Users/freek/dev/code/bloom/Package.swift",
        "./Tools/house-rules.sh",
        // Not in the extension list, and it does not need to be: the slashes say it is a path.
        "config/lights.tpl",
    ])
    func acceptsPaths(span: String) {
        #expect(FileMention.names(span))
    }

    @Test("a bare name with a known extension names a file", arguments: [
        "foo.md",
        "README.md",
        "Package.swift",
        "composer.json",
        "docker-compose.yml",
        "icon@2x.png",
        "Package.resolved",
        "layout_v2.blade.php",
    ])
    func acceptsBareNames(span: String) {
        #expect(FileMention.names(span))
    }

    // MARK: - What does not

    /// The reason this type exists at all. `FilePathGuess` cannot tell these from a filename,
    /// because they are the same shape: a stem, a full stop, and one to eight letters.
    @Test("a dotted identifier is not a file", arguments: [
        "NSApp.activate",
        "store.state",
        "Duration.seconds",
        "self.workspace",
        "console.log",
        "array.map",
        "response.data",
        "process.env",
        "model.app",
    ])
    func rejectsIdentifiers(span: String) {
        #expect(!FileMention.names(span))
    }

    @Test("a command is not a file", arguments: [
        "git status",
        "make build",
        "swift build -c release",
        "gh pr merge",
    ])
    func rejectsCommands(span: String) {
        #expect(!FileMention.names(span))
    }

    @Test("a flag, a branch and a bare word are not files", arguments: [
        "--force",
        "-f",
        "main",
        "origin/main",
        "HEAD",
        "feature/user-bubble",
    ])
    func rejectsWords(span: String) {
        #expect(!FileMention.names(span))
    }

    @Test("an address is not a file", arguments: [
        "https://github.com/spatie/bloom",
        "http://localhost:3000/index.html",
        "github.com/spatie/bloom",
    ])
    func rejectsAddresses(span: String) {
        #expect(!FileMention.names(span))
    }

    @Test("a glob is not a file", arguments: [
        "Sources/**/*.swift",
        "*.md",
        "{a,b}.swift",
    ])
    func rejectsGlobs(span: String) {
        #expect(!FileMention.names(span))
    }

    @Test("a version is not a file", arguments: ["1.2.3", "v0.3.0", "26.0"])
    func rejectsVersions(span: String) {
        #expect(!FileMention.names(span))
    }

    @Test("an unknown extension on a bare name is left as code", arguments: [
        "Makefile.custom",
        "notes.qqq",
    ])
    func rejectsUnknownExtensions(span: String) {
        #expect(!FileMention.names(span))
    }

    // MARK: - Splitting a turn

    @Test("the turn Bloom sends to open a pull request draws its path as a file")
    func splitsThePullRequestTurn() {
        let text = PullRequestInstructions.asking(
            "Create a pull request for this workspace against main.",
            toFollow: PullRequestInstructions.scratchPath
        )

        #expect(FileMention.segments(in: text) == [
            .text("Create a pull request for this workspace against main.\n\nFollow the instructions in "),
            .attachment(".bloom/scratch/pr-instructions.md"),
            .text("."),
        ])
    }

    @Test("words either side of a file stay words")
    func keepsTheSentence() {
        let segments = FileMention.segments(in: "run `git status`, then read `notes.md` twice")

        #expect(segments == [
            .text("run `git status`, then read "),
            .attachment("notes.md"),
            .text(" twice"),
        ])
    }

    @Test("a turn with no files in it is one run of text")
    func leavesProseAlone() {
        let text = "Use `NSApp.activate` only behind a check, and never `--force`."
        #expect(FileMention.segments(in: text) == [.text(text)])
    }

    /// The round trip the drawing rests on: whatever the segments are, putting them back together
    /// is the message the agent was handed, character for character. A bubble that dropped or
    /// added so much as a backtick would be showing the owner something he did not send.
    @Test("the segments put back together are the turn", arguments: [
        "Follow the instructions in `.bloom/scratch/pr-instructions.md`.",
        "`a.md` `b.md``c.md`",
        "an unclosed `backtick and `notes.md` after it",
        "```\nfenced\n```",
        "nothing backticked at all",
        "",
    ])
    func roundTrips(text: String) {
        #expect(FileMention.segments(in: text).map(\.text).joined() == text)
    }
}
