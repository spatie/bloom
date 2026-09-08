import Testing
import Foundation
@testable import BloomCore

/// A tick beside a changed file says "I have read this", and the one thing it must never do is go
/// on saying it about a file the agent has rewritten since.
@Suite("Viewed files")
struct ReviewedFileTests {
    private func file(
        _ path: String,
        change: ChangedFile.Change = .modified,
        additions: Int = 4,
        deletions: Int = 1
    ) -> ChangedFile {
        ChangedFile(path: path, change: change, additions: additions, deletions: deletions)
    }

    @Test("a tick holds while the diff it was given for holds")
    func holds() {
        let widget = file("Sources/Widget.swift")
        let marks = [widget.path: ReviewedFileFingerprint.of(widget)]

        #expect(ReviewedFiles.isViewed(widget, marks: marks))
    }

    @Test("a tick stops holding the moment the diff moves")
    func goesStale() {
        let widget = file("Sources/Widget.swift")
        let marks = [widget.path: ReviewedFileFingerprint.of(widget)]

        // One more added line, which is the ordinary case: the agent kept working while the
        // review was open.
        #expect(!ReviewedFiles.isViewed(file("Sources/Widget.swift", additions: 5), marks: marks))
        // The same counts under a different letter is a different change to read.
        #expect(!ReviewedFiles.isViewed(
            file("Sources/Widget.swift", change: .added), marks: marks
        ))
        // And a file nobody has ticked was never viewed.
        #expect(!ReviewedFiles.isViewed(file("Sources/Other.swift"), marks: marks))
    }

    @Test("a diff put back the way it was is viewed again")
    func survivesARevert() {
        // The mark is kept rather than deleted when it goes stale, so an edit the agent undoes
        // costs the reader nothing. That is the whole reason `isViewed` compares rather than the
        // store pruning rows during a poll.
        let widget = file("Sources/Widget.swift")
        let marks = [widget.path: ReviewedFileFingerprint.of(widget)]
        let edited = file("Sources/Widget.swift", additions: 9)

        #expect(!ReviewedFiles.isViewed(edited, marks: marks))
        #expect(ReviewedFiles.isViewed(widget, marks: marks))
    }

    @Test("the count says nothing until something has been read")
    func countsOnlyWhenThereIsSomethingToSay() {
        let files = [file("a.swift"), file("b.swift"), file("c.swift")]

        #expect(ReviewedFiles.summary(among: files, marks: [:]) == nil)
        #expect(ReviewedFiles.summary(among: [], marks: [:]) == nil)

        let one = [files[0].path: ReviewedFileFingerprint.of(files[0])]
        #expect(ReviewedFiles.summary(among: files, marks: one) == "1 of 3 files viewed")
        #expect(ReviewedFiles.viewedCount(among: files, marks: one) == 1)
    }

    @Test("the last file read reads as an answer rather than as a ratio")
    func saysWhenItIsDone() {
        let files = [file("a.swift"), file("b.swift")]
        let all = Dictionary(
            uniqueKeysWithValues: files.map { ($0.path, ReviewedFileFingerprint.of($0)) }
        )

        #expect(ReviewedFiles.summary(among: files, marks: all) == "All 2 files viewed")
        #expect(ReviewedFiles.unviewed(among: files, marks: all).isEmpty)
    }

    @Test("a stale tick puts its file back among the unread")
    func staleFilesAreUnread() {
        let files = [file("a.swift"), file("b.swift")]
        let marks = [
            files[0].path: ReviewedFileFingerprint.of(files[0]),
            // Given for a diff that no longer exists.
            files[1].path: "M:99:99:0",
        ]

        #expect(ReviewedFiles.unviewed(among: files, marks: marks).map(\.path) == ["b.swift"])
        #expect(ReviewedFiles.summary(among: files, marks: marks) == "1 of 2 files viewed")
    }

    @Test("the item says what pressing it would do, never what is already true")
    func wording() {
        #expect(ReviewedMarkAction(isViewed: false) == .markViewed)
        #expect(ReviewedMarkAction(isViewed: true) == .markNotViewed)
        #expect(ReviewedMarkAction.markViewed.title == "Mark as Viewed")
        #expect(ReviewedMarkAction.markNotViewed.title == "Mark as Not Viewed")
        #expect(ReviewedMarkAction.markViewed.isViewed)
        #expect(!ReviewedMarkAction.markNotViewed.isViewed)
        #expect(ReviewedMarkAction.markViewed.help(for: "Widget.swift").contains("Widget.swift"))
        // The keystroke is named where the pointer already is, because nothing else in the window
        // announces it.
        #expect(ReviewedMarkAction.markViewed.help(for: "a").contains("Option+V"))
    }
}

/// Option+V is a character somebody may be typing, so the rule that decides whether it belongs to
/// the review is worth holding still.
@Suite("Viewed shortcut")
struct ReviewViewedShortcutTests {
    @Test("it never takes a keystroke off something that accepts text")
    func leavesTypingAlone() {
        #expect(!ReviewViewedShortcut.isArmed(hasFile: true, isTakingText: true))
    }

    @Test("it does nothing when the review has no file to mark")
    func needsAFile() {
        #expect(!ReviewViewedShortcut.isArmed(hasFile: false, isTakingText: false))
        #expect(!ReviewViewedShortcut.isArmed(hasFile: false, isTakingText: true))
    }

    @Test("a review on screen with nobody typing owns the key")
    func armed() {
        #expect(ReviewViewedShortcut.isArmed(hasFile: true, isTakingText: false))
    }
}
