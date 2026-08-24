import Testing
@testable import BloomCore

/// A diff turned into something worth sending someone, which lived in a view.
///
/// The clipboard carries the patch exactly as git wrote it, because that form is for `git apply`.
/// This one is for a person, and it is 120 lines of budget, a 200 column limit, a
/// whole-hunks-or-none rule and an "N more lines not shown" count maintained by hand across three
/// branches. All of it is `String` and `Int` work, none of it touched AppKit, and none of it could
/// be asked whether the number it prints matches the lines it actually dropped.
@Suite("A diff worth sending someone")
struct DiffShareTextTests {
    private func file(
        path: String = "Sources/Bloom/App.swift",
        oldPath: String? = nil,
        change: ChangedFile.Change = .modified,
        additions: Int = 0,
        deletions: Int = 0,
        isBinary: Bool = false
    ) -> ChangedFile {
        ChangedFile(
            path: path, oldPath: oldPath, change: change,
            additions: additions, deletions: deletions, isBinary: isBinary
        )
    }

    private func hunk(newStart: Int, adding count: Int, prefix: String = "line") -> DiffHunk {
        DiffHunk(
            oldStart: newStart, oldCount: 0, newStart: newStart, newCount: count,
            header: "",
            lines: (1...count).map {
                DiffLine(kind: .addition, text: "\(prefix)-\($0)", oldNumber: nil, newNumber: newStart + $0)
            }
        )
    }

    private func diff(_ hunks: [DiffHunk]) -> FileDiff {
        FileDiff(
            oldPath: "a", newPath: "b", hunks: hunks, isBinary: false, isRename: false,
            oldMode: nil, newMode: nil, additions: 0, deletions: 0
        )
    }

    // MARK: - The heading

    @Test("the heading names the file, what happened to it and by how much")
    func theHeadingIsTheRowsWords() {
        let text = DiffShareText.make(
            for: file(change: .added, additions: 12), diff: diff([hunk(newStart: 1, adding: 2)])
        )
        #expect(text.hasPrefix("Sources/Bloom/App.swift  new file  +12"))
    }

    @Test("a rename names both ends, and a file renamed to itself names one")
    func renamesNameBothEnds() {
        let renamed = DiffShareText.make(
            for: file(path: "New.swift", oldPath: "Old.swift", change: .renamed),
            diff: diff([hunk(newStart: 1, adding: 1)])
        )
        #expect(renamed.hasPrefix("Old.swift -> New.swift"))

        let same = DiffShareText.make(
            for: file(path: "Same.swift", oldPath: "Same.swift"),
            diff: diff([hunk(newStart: 1, adding: 1)])
        )
        #expect(same.hasPrefix("Same.swift\n"))
        #expect(!same.contains("->"))
    }

    /// Nothing to fence is said in words rather than as an empty code block.
    @Test("a binary file and an empty diff each say so instead of fencing nothing")
    func nothingToShowSaysSo() {
        #expect(DiffShareText.make(for: file(isBinary: true), diff: nil)
            .hasSuffix("Binary file, no text diff."))
        #expect(DiffShareText.make(for: file(), diff: nil).hasSuffix("No textual changes."))
        #expect(DiffShareText.make(for: file(), diff: diff([])).hasSuffix("No textual changes."))
    }

    // MARK: - The body

    /// Fenced as `diff` so Slack, GitHub and Linear all colour the plus and minus lines.
    @Test("the body is a diff fence, with git's scaffolding gone")
    func theBodyIsAFence() {
        let text = DiffShareText.make(for: file(), diff: diff([hunk(newStart: 40, adding: 2)]))
        #expect(text.contains("```diff\n"))
        #expect(text.hasSuffix("```"))
        // The line number a reader would scroll to, not git's four number range.
        #expect(text.contains("@@ line 40"))
        #expect(!text.contains("@@ -"))
        #expect(!text.contains("diff --git"))
        #expect(!text.contains("index "))
    }

    /// A hunk cut off in the middle reads as a bug in whatever produced it, so the budget stops
    /// before a hunk rather than inside one.
    @Test("hunks are kept whole or dropped whole")
    func hunksAreWholeOrAbsent() {
        let text = DiffShareText.make(
            for: file(),
            diff: diff([hunk(newStart: 1, adding: 100), hunk(newStart: 500, adding: 100, prefix: "later")])
        )
        #expect(text.contains("line-100"))
        // The second hunk does not fit in what is left of the budget, so none of it is there.
        #expect(!text.contains("later-1"))
        #expect(!text.contains("@@ line 500"))
    }

    /// The exception, because dropping it would leave a message with nothing in it.
    @Test("a first hunk longer than the whole budget is cut rather than dropped")
    func theFirstHunkIsNeverDroppedEntirely() {
        let text = DiffShareText.make(for: file(), diff: diff([hunk(newStart: 1, adding: 400)]))
        #expect(text.contains("line-1"))
        #expect(text.contains("more lines not shown."))
    }

    /// The count is maintained by hand across three branches, which is exactly why it is worth
    /// pinning: what it claims was left out has to be what was left out.
    @Test("the count of lines not shown matches the lines not shown")
    func theOmittedCountIsHonest() {
        let text = DiffShareText.make(
            for: file(),
            diff: diff([hunk(newStart: 1, adding: 60), hunk(newStart: 500, adding: 90, prefix: "later")])
        )
        // The `@@` line is scaffolding rather than a line of the file, so the second hunk costs 90.
        #expect(text.contains("90 more lines not shown."))
    }

    /// 120 added lines plus the `@@` line is 121 rendered, and the budget keeps 120 of them.
    @Test("one line left out is said in the singular")
    func oneLineIsSingular() {
        let text = DiffShareText.make(for: file(), diff: diff([hunk(newStart: 1, adding: 120)]))
        #expect(text.contains("1 more line not shown."))
        #expect(!text.contains("1 more lines"))
    }

    /// A minified bundle is one line of a hundred thousand characters, and the line budget alone
    /// would not catch it.
    @Test("a very long line is clipped at the column limit")
    func longLinesAreClipped() {
        let long = String(repeating: "x", count: 5_000)
        let text = DiffShareText.make(
            for: file(),
            diff: diff([
                DiffHunk(
                    oldStart: 1, oldCount: 0, newStart: 1, newCount: 1, header: "",
                    lines: [DiffLine(kind: .addition, text: long, oldNumber: nil, newNumber: 1)]
                )
            ])
        )
        #expect(text.contains("…"))
        #expect(text.count < 1_000)
    }

    /// `\ No newline at end of file` is git's marker, not a line of the file.
    @Test("the no-newline marker is not carried into a message")
    func theNoNewlineMarkerIsDropped() {
        let text = DiffShareText.make(
            for: file(),
            diff: diff([
                DiffHunk(
                    oldStart: 1, oldCount: 1, newStart: 1, newCount: 1, header: "",
                    lines: [
                        DiffLine(kind: .addition, text: "one", oldNumber: nil, newNumber: 1),
                        DiffLine(kind: .noNewline, text: "\\ No newline at end of file", oldNumber: nil, newNumber: nil),
                    ]
                )
            ])
        )
        #expect(text.contains("+one"))
        #expect(!text.contains("No newline"))
    }
}
