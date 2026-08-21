import Testing
import Foundation
@testable import BloomCore

/// A note is written against a file the agent is still editing, so the interesting behaviour is
/// all about what happens to it afterwards: the line moves, the line is rewritten, the line is
/// gone, or the line was never unique in the first place.
@Suite("Review comment anchoring")
struct ReviewCommentAnchorTests {
    /// A small file with one obviously unique line in the middle and repeated braces, which is the
    /// shape that breaks naive anchoring.
    static let original = [
        "import Foundation",
        "",
        "struct Widget {",
        "    func render() -> String {",
        "        return \"hello\"",
        "    }",
        "",
        "    func reset() {",
        "        count = 0",
        "    }",
        "}",
    ]

    @Test("captures the anchored line and its neighbours")
    func capturesNeighbours() {
        let anchor = ReviewCommentAnchor.make(line: 5, in: Self.original)

        #expect(anchor.line == 5)
        #expect(anchor.text == "        return \"hello\"")
        #expect(anchor.before == ["", "struct Widget {", "    func render() -> String {"])
        #expect(anchor.after == ["    }", "", "    func reset() {"])
    }

    @Test("clips context at the edges of the file")
    func clipsAtEdges() {
        let anchor = ReviewCommentAnchor.make(line: 1, in: Self.original)

        #expect(anchor.before.isEmpty)
        #expect(anchor.after.count == 3)
    }

    @Test("a line number outside the file yields an empty anchor")
    func handlesOutOfRangeLine() {
        let anchor = ReviewCommentAnchor.make(line: 99, in: Self.original)

        #expect(anchor.text.isEmpty)
        #expect(anchor.before.isEmpty)
    }

    @Test("resolves to the same line when nothing changed")
    func resolvesUnchanged() {
        let anchor = ReviewCommentAnchor.make(line: 5, in: Self.original)
        let resolution = anchor.resolve(in: Self.original)

        #expect(resolution.status == .exact)
        #expect(resolution.line == 5)
    }

    @Test("survives lines being inserted above it")
    func survivesInsertionAbove() {
        let anchor = ReviewCommentAnchor.make(line: 5, in: Self.original)
        var edited = Self.original
        edited.insert(contentsOf: ["// added", "// added", "// added"], at: 0)

        let resolution = anchor.resolve(in: edited)

        #expect(resolution.status == .shifted)
        #expect(resolution.line == 8)
        #expect(edited[resolution.line - 1] == anchor.text)
    }

    @Test("survives lines being removed above it")
    func survivesRemovalAbove() {
        let anchor = ReviewCommentAnchor.make(line: 5, in: Self.original)
        var edited = Self.original
        edited.removeSubrange(0..<2)

        let resolution = anchor.resolve(in: edited)

        #expect(resolution.status == .shifted)
        #expect(resolution.line == 3)
    }

    @Test("marks a comment outdated when the anchored line itself was rewritten")
    func detectsRewrittenLine() {
        let anchor = ReviewCommentAnchor.make(line: 5, in: Self.original)
        var edited = Self.original
        edited[4] = "        return \"goodbye\""

        let resolution = anchor.resolve(in: edited)

        #expect(resolution.status == .outdated)
        #expect(resolution.line == 5)
    }

    @Test("treats a reindented line as a different line")
    func indentationIsContent() {
        let anchor = ReviewCommentAnchor.make(line: 5, in: Self.original)
        var edited = Self.original
        edited[4] = "\treturn \"hello\""

        // A note that says "this indentation is wrong" must not quietly re-attach to the line that
        // was reindented and then claim nothing happened.
        #expect(anchor.resolve(in: edited).status == .outdated)
    }

    @Test("a comment on a deleted line reports itself outdated at a line inside the file")
    func handlesDeletedLine() {
        let anchor = ReviewCommentAnchor.make(line: 9, in: Self.original)
        var edited = Self.original
        edited.removeSubrange(7..<10)

        let resolution = anchor.resolve(in: edited)

        #expect(resolution.status == .outdated)
        #expect(resolution.isOutdated)
        // Still a line a view can scroll to, rather than one past the end of the shortened file.
        #expect(resolution.line <= edited.count)
        #expect(resolution.line >= 1)
    }

    @Test("a comment on a file that is now empty stays in range")
    func handlesEmptyFile() {
        let anchor = ReviewCommentAnchor.make(line: 5, in: Self.original)
        let resolution = anchor.resolve(in: [])

        #expect(resolution.status == .outdated)
        #expect(resolution.line == 1)
    }

    @Test("uses context to pick between identical lines")
    func disambiguatesByContext() {
        // Line 6 and line 10 are both "    }". The note was on the first one, and the block that
        // owns it gets pushed down by an edit far above.
        let anchor = ReviewCommentAnchor.make(line: 6, in: Self.original)
        var edited = Self.original
        edited.insert("// header", at: 0)
        edited.insert("// header", at: 0)

        let resolution = anchor.resolve(in: edited)

        #expect(resolution.status == .shifted)
        #expect(resolution.line == 8)
    }

    @Test("refuses to guess between identical lines with no surviving context")
    func refusesToGuess() {
        let anchor = ReviewCommentAnchor(line: 2, text: "}", before: ["    foo()"], after: [""])
        let resolution = anchor.resolve(in: ["}", "x", "}", "y", "}"])

        // Three equally plausible homes and nothing to choose between them. Pinning the note to
        // one of them at random is worse than admitting it lost its place, because the agent has
        // no way to tell a confident answer from a coin flip.
        #expect(resolution.status == .outdated)
    }

    @Test("a unique match with no surviving context is still trusted")
    func trustsUniqueMatch() {
        let anchor = ReviewCommentAnchor(
            line: 2, text: "let answer = 42", before: ["gone"], after: ["gone"]
        )
        let resolution = anchor.resolve(in: ["a", "b", "c", "let answer = 42"])

        #expect(resolution.status == .shifted)
        #expect(resolution.line == 4)
    }

    @Test("stays at home even when a better scoring twin exists elsewhere")
    func prefersHome() {
        let anchor = ReviewCommentAnchor(line: 1, text: "same", before: [], after: ["one"])
        let resolution = anchor.resolve(in: ["same", "two", "same", "one"])

        // Nothing observable says the note moved, so relabelling it as shifted would be reporting
        // an edit that nobody made.
        #expect(resolution.status == .exact)
        #expect(resolution.line == 1)
    }

    @Test("a trailing newline does not add a phantom last line")
    func splitsLikeAnEditor() {
        #expect(ReviewCommentAnchor.split("a\nb\n") == ["a", "b"])
        #expect(ReviewCommentAnchor.split("a\nb") == ["a", "b"])
        #expect(ReviewCommentAnchor.split("a\n\n") == ["a", ""])
        #expect(ReviewCommentAnchor.split("") == [""])
    }

    @Test("resolves against raw file contents")
    func resolvesAgainstContents() {
        let anchor = ReviewCommentAnchor(line: 2, text: "b", before: ["a"], after: ["c"])

        #expect(anchor.resolve(in: "a\nb\nc\n").status == .exact)
    }

    @Test("anchors to a hunk line on the new side, ignoring deletions")
    func anchorsFromHunk() throws {
        let patch = """
        diff --git a/Widget.swift b/Widget.swift
        --- a/Widget.swift
        +++ b/Widget.swift
        @@ -1,4 +1,4 @@
         one
        -two
        +TWO
         three
         four
        """
        let file = try #require(DiffParser.parse(patch).first)
        let hunk = try #require(file.hunks.first)

        let anchor = try #require(ReviewCommentAnchor.make(line: 2, side: .new, in: hunk))

        #expect(anchor.text == "TWO")
        // "two" is a deletion, so it is not part of the new file and must not become context.
        #expect(anchor.before == ["one"])
        #expect(anchor.after == ["three", "four"])
    }

    @Test("anchors to a hunk line on the old side")
    func anchorsFromHunkOldSide() throws {
        let patch = """
        diff --git a/Widget.swift b/Widget.swift
        --- a/Widget.swift
        +++ b/Widget.swift
        @@ -1,4 +1,4 @@
         one
        -two
        +TWO
         three
         four
        """
        let file = try #require(DiffParser.parse(patch).first)
        let hunk = try #require(file.hunks.first)

        let anchor = try #require(ReviewCommentAnchor.make(line: 2, side: .old, in: hunk))

        #expect(anchor.text == "two")
        #expect(anchor.after == ["three", "four"])
    }

    @Test("returns nothing for a line the hunk does not contain")
    func rejectsUnknownHunkLine() throws {
        let patch = """
        diff --git a/Widget.swift b/Widget.swift
        --- a/Widget.swift
        +++ b/Widget.swift
        @@ -1,2 +1,2 @@
         one
        -two
        +TWO
        """
        let file = try #require(DiffParser.parse(patch).first)
        let hunk = try #require(file.hunks.first)

        #expect(ReviewCommentAnchor.make(line: 400, side: .new, in: hunk) == nil)
    }
}

// MARK: - Composer summary

@Suite("Review comment summary")
struct ReviewCommentSummaryTests {
    private func comment(
        _ path: String,
        _ line: Int,
        side: ReviewCommentSide = .new,
        body: String = "note"
    ) -> ReviewComment {
        ReviewComment(
            id: ReviewCommentID("\(path)-\(line)"),
            workspaceID: WorkspaceID("w"),
            filePath: path,
            side: side,
            anchor: ReviewCommentAnchor(line: line, text: "line \(line)"),
            body: body,
            createdAt: Date(timeIntervalSince1970: Double(line))
        )
    }

    @Test("labels a single comment with its file name and line")
    func labelsOne() {
        let one = comment("src/CouldNotSetCustomFieldValue.php", 34)

        #expect(ReviewCommentSummary.label(for: [one]) == "CouldNotSetCustomFieldValue.php +34")
    }

    @Test("marks an old side comment with a minus")
    func labelsOldSide() {
        #expect(ReviewCommentSummary.chip(for: comment("a/Foo.swift", 12, side: .old)) == "Foo.swift -12")
    }

    @Test("lists the lines when a handful sit in one file")
    func labelsSeveralInOneFile() {
        let comments = [comment("a/Foo.swift", 34), comment("a/Foo.swift", 12)]

        #expect(ReviewCommentSummary.label(for: comments) == "Foo.swift +12 +34")
    }

    @Test("counts instead of listing once one file has too many")
    func countsWithinOneFile() {
        let comments = (1...5).map { comment("a/Foo.swift", $0 * 10) }

        #expect(ReviewCommentSummary.label(for: comments) == "Foo.swift +10 and 4 more")
    }

    @Test("names the first file and counts the rest across files")
    func labelsAcrossFiles() {
        let comments = [
            comment("a/Zebra.swift", 5),
            comment("a/Alpha.swift", 9),
            comment("a/Middle.swift", 1),
        ]

        // Sorted by path, so the label is the same however the UI happened to collect them.
        #expect(ReviewCommentSummary.label(for: comments) == "Alpha.swift +9 and 2 more")
    }

    @Test("says nothing when there is nothing attached")
    func labelsNone() {
        #expect(ReviewCommentSummary.label(for: []).isEmpty)
    }
}
