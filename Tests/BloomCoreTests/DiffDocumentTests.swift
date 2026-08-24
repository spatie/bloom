import Foundation
import Testing
@testable import BloomCore

/// The one sequential pass over a diff, which lived in `Sources/Bloom/Views/Inspector` and so could
/// not be tested at all: the test target depends on BloomCore alone. `SyntaxHighlighter` and
/// `DiffParser` were both tested; the pass that composes them, the part whose head comment
/// documents a subtle bug class, was not.
@Suite("Diff document")
struct DiffDocumentTests {
    private func file(_ lines: [DiffLine]) -> FileDiff {
        FileDiff(
            newPath: "Sources/Thing.swift",
            hunks: [DiffHunk(oldStart: 1, oldCount: 1, newStart: 1, newCount: 1, lines: lines)]
        )
    }

    private func line(_ kind: DiffLine.Kind, _ text: String, index: Int) -> DiffLine {
        DiffLine(kind: kind, text: text, index: index)
    }

    // MARK: The carry, which is the reason the pass is sequential

    /// The head comment's own claim: "a block comment opened by a deletion must not leak into the
    /// additions rendered next to it". Old and new lines are two versions of one file, so they are
    /// lexed with two carries.
    @Test("a comment opened by a deletion does not leak into the additions beside it")
    func carriesAreSeparatePerSide() {
        let document = DiffDocument.prepare(
            file: file([
                line(.context, "let a = 1", index: 0),
                line(.deletion, "/* opened and never closed", index: 1),
                line(.addition, "let b = 2", index: 2),
                line(.addition, "let c = 3", index: 3),
            ]),
            path: "Sources/Thing.swift"
        )

        // The addition after the deletion begins in the state the NEW side was left in, which is
        // the clean one: nothing on the new side opened a comment. `LexState` keeps its fields
        // private, so "clean" is spelled as "equal to a fresh one", which is what it means.
        #expect(document.carries[2] == LexState())
        #expect(document.carries[3] == LexState())
    }

    @Test("a comment opened on the new side does carry into the next new line")
    func carryFollowsItsOwnSide() {
        let document = DiffDocument.prepare(
            file: file([
                line(.addition, "/* opened here", index: 0),
                line(.addition, "still inside", index: 1),
            ]),
            path: "Sources/Thing.swift"
        )

        #expect(document.carries[0] == LexState())
        #expect(document.carries[1] != LexState())
    }

    @Test("context lines advance both sides, because they are in both versions")
    func contextAdvancesBothSides() {
        let document = DiffDocument.prepare(
            file: file([
                line(.context, "/* opened in context", index: 0),
                line(.deletion, "old inside", index: 1),
                line(.addition, "new inside", index: 2),
            ]),
            path: "Sources/Thing.swift"
        )

        #expect(document.carries[1] != LexState())
        #expect(document.carries[2] != LexState())
    }

    // MARK: Language

    @Test("a file with no lexer skips the whole pass rather than running it for nothing")
    func plainTextIsFree() {
        let document = DiffDocument.prepare(
            file: file([line(.addition, "/* not code", index: 0)]),
            path: "notes.txt"
        )

        #expect(document.language == .plainText)
        #expect(document.carries.isEmpty)
    }

    // MARK: Emphasis

    @Test("a changed word is emphasised on both the old line and the new one")
    func pairedLinesGetWordRanges() throws {
        let document = DiffDocument.prepare(
            file: file([
                line(.deletion, "let total = oldValue", index: 0),
                line(.addition, "let total = newValue", index: 1),
            ]),
            path: "Sources/Thing.swift"
        )

        let deletion = try #require(document.emphasis[0])
        let addition = try #require(document.emphasis[1])

        #expect(!deletion.isEmpty)
        #expect(!addition.isEmpty)
    }

    /// A one-sided change has nothing to compare against, so emphasising all of it would mark the
    /// whole line and say nothing.
    @Test("a line with no partner is not emphasised")
    func unpairedLinesAreLeftAlone() {
        let document = DiffDocument.prepare(
            file: file([
                line(.context, "let a = 1", index: 0),
                line(.addition, "let b = 2", index: 1),
            ]),
            path: "Sources/Thing.swift"
        )

        #expect(document.emphasis[1] == nil)
    }

    @Test("two identical lines paired across a hunk are not emphasised")
    func identicalPairsAreLeftAlone() {
        let document = DiffDocument.prepare(
            file: file([
                line(.deletion, "let total = value", index: 0),
                line(.addition, "let total = value", index: 1),
            ]),
            path: "Sources/Thing.swift"
        )

        #expect(document.emphasis[0]?.isEmpty ?? true)
        #expect(document.emphasis[1]?.isEmpty ?? true)
    }

    /// The LCS per pair is the one superlinear cost in the pass, and a file with thousands of
    /// paired edits is being skimmed rather than read.
    @Test("word emphasis stops past the limit rather than costing more than the file is worth")
    func emphasisStopsAtTheLimit() {
        var lines: [DiffLine] = []
        var index = 0

        // Past the limit, which counts pairs rather than lines.
        for pair in 0..<4_100 {
            lines.append(line(.deletion, "let value\(pair) = old", index: index))
            index += 1
            lines.append(line(.addition, "let value\(pair) = new", index: index))
            index += 1
        }

        let document = DiffDocument.prepare(file: file(lines), path: "Sources/Thing.swift")

        #expect(document.emphasis[0] != nil)
        #expect(document.emphasis[index - 1] == nil)
    }

    // MARK: Width

    @Test("the widest line decides the scroll, and a tab is four columns of it")
    func widthCountsTabsAsFour() {
        let document = DiffDocument.prepare(
            file: file([
                line(.context, "short", index: 0),
                line(.addition, "\t\tindented", index: 1),
            ]),
            path: "Sources/Thing.swift"
        )

        #expect(document.maxColumns == 16)
    }

    @Test("a line wider than any scroller could help with is capped")
    func widthIsCapped() {
        let document = DiffDocument.prepare(
            file: file([line(.addition, String(repeating: "x", count: 5_000), index: 0)]),
            path: "Sources/Thing.swift"
        )

        #expect(document.maxColumns == 800)
    }

    // MARK: Priming

    @Test("the lines offered for priming are the first printed ones, with their carry")
    func primesFromTheTop() {
        let document = DiffDocument.prepare(
            file: file([
                line(.context, "/* opened", index: 0),
                line(.deletion, "gone", index: 1),
                line(.addition, "here", index: 2),
                line(.noNewline, "\\ No newline at end of file", index: 3),
            ]),
            path: "Sources/Thing.swift"
        )

        let primed = document.linesToPrime(limit: 3)
        #expect(primed.map(\.text) == ["/* opened", "gone", "here"])
        // The carry is the state the line BEGINS in, so the first line of an open block comment
        // still carries the clean state and the two after it do not.
        #expect(primed[0].carry == LexState())
        #expect(primed[1].carry != LexState())
        #expect(primed[2].carry != LexState())
    }

    @Test("priming stops at the limit and skips the no-newline marker")
    func primingIsBounded() {
        let document = DiffDocument.prepare(
            file: file([
                line(.addition, "one", index: 0),
                line(.addition, "two", index: 1),
                line(.noNewline, "\\ No newline at end of file", index: 2),
            ]),
            path: "Sources/Thing.swift"
        )

        #expect(document.linesToPrime(limit: 1).map(\.text) == ["one"])
        #expect(document.linesToPrime(limit: 99).map(\.text) == ["one", "two"])
        #expect(document.linesToPrime(limit: 0).isEmpty)
    }
}

/// One number, asked by both of the bars that draw a file's name, which is why it is in the core
/// rather than written out as a private constant in each of them.
@Suite("File bar layout")
struct FileBarLayoutTests {
    @Test("the folder is kept above the threshold and dropped below it")
    func folderFollowsTheWidth() {
        #expect(FileBarLayout.showsDirectory(width: FileBarLayout.folderThreshold))
        #expect(FileBarLayout.showsDirectory(width: FileBarLayout.folderThreshold + 1))
        #expect(!FileBarLayout.showsDirectory(width: FileBarLayout.folderThreshold - 1))
        // A bar that has not been measured yet has room for nothing.
        #expect(!FileBarLayout.showsDirectory(width: 0))
    }
}

@Suite("Code columns")
struct CodeColumnsTests {
    @Test("a tab is four columns, so indented code is not measured short")
    func tabsAreFour() {
        #expect(CodeColumns.count(of: "\tx") == 5)
        #expect(CodeColumns.count(of: "    x") == 5)
        #expect(CodeColumns.count(of: "") == 0)
    }
}
