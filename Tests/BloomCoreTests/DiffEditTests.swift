import Foundation
import Testing
@testable import BloomCore

/// Editing the new side of a diff in place, which is a feature about two writers rather than
/// about a text box: the reader is typing into a file an agent is rewriting underneath them.
///
/// Three questions are worth a test and all three are here. Which lines an edit may cover, so a
/// click cannot open a box over something it does not stand for. How the box maps back to the
/// file, so a save lands on the lines the reader was looking at and nothing else. And what
/// happens when the file has moved since the diff was drawn, which is the case that decides
/// whether this feature destroys work or refuses to.
@Suite("Editing a diff in place")
struct DiffEditTests {

    /// One hunk with a replaced line and a line added after it. New-side numbering:
    /// 1 one, 2 two, 3 THREE, 4 three and a half, 5 four, 6 five, 7 six.
    private let patch = """
        diff --git a/notes.swift b/notes.swift
        --- a/notes.swift
        +++ b/notes.swift
        @@ -1,6 +1,7 @@
         one
         two
        -three
        +THREE
        +three and a half
         four
         five
         six
        """

    /// The worktree copy the patch above describes, with two more lines below the hunk that git
    /// never printed.
    private let file = "one\ntwo\nTHREE\nthree and a half\nfour\nfive\nsix\nseven\neight\n"

    private var hunks: [DiffHunk] {
        DiffParser.parse(patch).first?.hunks ?? []
    }

    // MARK: - Which lines an edit covers

    @Test("an added line opens the whole block of added lines it belongs to")
    func additionBlock() throws {
        let region = try DiffEdit.region(at: 3, in: hunks, fileText: file)

        #expect(region.firstLine == 3)
        #expect(region.lastLine == 4)
        #expect(region.lines == ["THREE", "three and a half"])
        #expect(region.text == "THREE\nthree and a half")
    }

    @Test("the block is the same block from either end of it")
    func additionBlockFromBelow() throws {
        let first = try DiffEdit.region(at: 3, in: hunks, fileText: file)
        let second = try DiffEdit.region(at: 4, in: hunks, fileText: file)

        #expect(first == second)
    }

    @Test("a context line opens as itself, not as the unchanged run around it")
    func contextIsAlone() throws {
        let region = try DiffEdit.region(at: 2, in: hunks, fileText: file)

        #expect(region.firstLine == 2)
        #expect(region.lineCount == 1)
        #expect(region.lines == ["two"])
    }

    /// The lines a reader reveals between two hunks come off the worktree rather than out of the
    /// patch, so nothing in `hunks` knows about them. They are file lines all the same.
    @Test("a line no hunk printed is still editable, and stands alone")
    func revealedLine() throws {
        let region = try DiffEdit.region(at: 9, in: hunks, fileText: file)

        #expect(region.firstLine == 9)
        #expect(region.lines == ["eight"])
    }

    /// Not reachable from the diff view, which only ever offers a new-side number, and answered
    /// anyway: a hunk built by hand or a patch this parser has not met must refuse rather than
    /// trap.
    @Test("a removed line is refused, because it is not in the file to be typed into")
    func oldSideIsRefused() {
        let hunk = DiffHunk(
            oldStart: 1, oldCount: 1, newStart: 1, newCount: 1,
            lines: [DiffLine(kind: .deletion, text: "gone", oldNumber: 1, newNumber: 1, index: 0)]
        )

        #expect(throws: DiffEditRefusal.oldSide) {
            try DiffEdit.region(at: 1, in: [hunk], fileText: "gone\n")
        }
    }

    @Test("a block longer than the limit belongs in the file's own editor")
    func oversizeBlockIsRefused() {
        let count = DiffEdit.lineLimit + 1
        var lines: [DiffLine] = []
        for number in 1...count {
            lines.append(
                DiffLine(kind: .addition, text: "line \(number)", newNumber: number, index: number)
            )
        }
        let hunk = DiffHunk(
            oldStart: 0, oldCount: 0, newStart: 1, newCount: count, lines: lines
        )
        let text = (1...count).map { "line \($0)" }.joined(separator: "\n") + "\n"

        #expect(throws: DiffEditRefusal.tooManyLines(count)) {
            try DiffEdit.region(at: 5, in: [hunk], fileText: text)
        }
    }

    @Test("a line past the end of the file is gone rather than empty")
    func pastTheEnd() {
        #expect(throws: DiffEditRefusal.gone(line: 40)) {
            try DiffEdit.region(at: 40, in: hunks, fileText: file)
        }
        #expect(throws: DiffEditRefusal.gone(line: 0)) {
            try DiffEdit.region(at: 0, in: hunks, fileText: file)
        }
    }

    // MARK: - The file moving under the diff

    /// The case the whole feature turns on. The reader is looking at a diff drawn a few seconds
    /// ago; the agent has since inserted a line at the top of the file, so every number below it
    /// means a different line. Opening an editor on the diff's numbers would put the reader's
    /// typing into code they have never seen.
    @Test("a file the agent has shifted refuses to open an editor at all")
    func shiftedFileIsRefused() {
        let shifted = "zero\n" + file

        #expect(throws: DiffEditRefusal.moved(line: 3)) {
            try DiffEdit.region(at: 3, in: hunks, fileText: shifted)
        }
    }

    @Test("a line rewritten in place is caught too, though no number moved")
    func rewrittenLineIsRefused() {
        let rewritten = file.replacingOccurrences(of: "three and a half", with: "3.5")

        #expect(throws: DiffEditRefusal.moved(line: 4)) {
            try DiffEdit.region(at: 3, in: hunks, fileText: rewritten)
        }
    }

    @Test("the warning names the file and stays quiet while nothing has moved")
    func staleWarning() {
        #expect(DiffEdit.staleWarning(filename: "notes.swift", baseline: file, contents: file) == nil)

        let changed = DiffEdit.staleWarning(
            filename: "notes.swift", baseline: file, contents: file + "nine\n"
        )
        #expect(changed?.contains("notes.swift changed on disk") == true)

        let deleted = DiffEdit.staleWarning(
            filename: "notes.swift", baseline: file, contents: nil
        )
        #expect(deleted?.contains("no longer on disk") == true)
    }

    // MARK: - Putting the edit back

    @Test("an untouched box puts the file back byte for byte")
    func roundTrip() throws {
        let region = try DiffEdit.region(at: 3, in: hunks, fileText: file)

        #expect(try DiffEdit.apply(region.text, of: region, to: file) == file)
    }

    @Test("a file with no trailing newline does not gain one by being saved")
    func roundTripWithoutTrailingNewline() throws {
        let unterminated = "one\ntwo\nTHREE\nthree and a half\nfour\nfive\nsix"
        let region = try DiffEdit.region(at: 6, in: hunks, fileText: unterminated)

        #expect(region.lines == ["five"])
        #expect(try DiffEdit.apply(region.text, of: region, to: unterminated) == unterminated)
    }

    @Test("an edit replaces its own lines and leaves the rest of the file alone")
    func replacesTheRegion() throws {
        let region = try DiffEdit.region(at: 3, in: hunks, fileText: file)

        let saved = try DiffEdit.apply("THREE\nthree and a HALF", of: region, to: file)

        #expect(saved == "one\ntwo\nTHREE\nthree and a HALF\nfour\nfive\nsix\nseven\neight\n")
    }

    @Test("the box may hold more lines than it opened with, or fewer")
    func growsAndShrinks() throws {
        let region = try DiffEdit.region(at: 3, in: hunks, fileText: file)

        let grown = try DiffEdit.apply("a\nb\nc", of: region, to: file)
        #expect(grown == "one\ntwo\na\nb\nc\nfour\nfive\nsix\nseven\neight\n")

        let shrunk = try DiffEdit.apply("just the one", of: region, to: file)
        #expect(shrunk == "one\ntwo\njust the one\nfour\nfive\nsix\nseven\neight\n")
    }

    /// A newline apart, and only one of the two is recoverable by typing.
    @Test("an emptied box is one blank line, not a deletion of the lines")
    func emptiedBox() throws {
        let region = try DiffEdit.region(at: 2, in: hunks, fileText: file)

        #expect(try DiffEdit.apply("", of: region, to: file)
            == "one\n\nTHREE\nthree and a half\nfour\nfive\nsix\nseven\neight\n")
    }

    @Test("a splice into a file the region did not come from is refused")
    func spliceIntoAnotherFile() throws {
        let region = try DiffEdit.region(at: 3, in: hunks, fileText: file)
        let elsewhere = "one\ntwo\nsomething else entirely\nand more\nfour\n"

        #expect(throws: DiffEditRefusal.moved(line: 3)) {
            try DiffEdit.apply("THREE\nthree and a half", of: region, to: elsewhere)
        }
    }

    @Test("a splice into a file that has since been truncated is refused")
    func spliceIntoATruncatedFile() throws {
        let region = try DiffEdit.region(at: 6, in: hunks, fileText: file)

        #expect(throws: DiffEditRefusal.gone(line: 6)) {
            try DiffEdit.apply("five", of: region, to: "one\ntwo\n")
        }
    }

    // MARK: - Closing the box

    @Test("closing a box nobody typed in asks nothing")
    func discardIsQuietWhenNothingWasTyped() throws {
        let region = try DiffEdit.region(at: 3, in: hunks, fileText: file)

        #expect(!DiffEdit.Discard.needed(closing: region.text, of: region))
        #expect(DiffEdit.Discard.needed(closing: region.text + " ", of: region))
        #expect(!region.isEdited(region.text))
        #expect(region.isEdited("something"))
    }

    // MARK: - Lines

    /// The same split the review bands number a file's lines by, so a comment and an edit on one
    /// line cannot come to two different opinions about which line it is.
    @Test("splitting a file agrees with the review anchors, and remembers the last newline")
    func splitting() {
        for text in ["", "a", "a\n", "a\nb", "a\nb\n", "a\n\n", "\n"] {
            let contents = DiffEdit.Contents(of: text)
            #expect(contents.text == text, "\(text.debugDescription) did not round trip")
            #expect(contents.lines == ReviewCommentAnchor.split(text))
        }
    }
}
