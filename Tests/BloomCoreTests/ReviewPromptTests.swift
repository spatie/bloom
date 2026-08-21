import Testing
import Foundation
@testable import BloomCore

/// The payload is the only thing the agent ever sees of a review, so its job is to be unambiguous
/// about which file and which line each note is about, and to admit it when the file moved on.
@Suite("Review payload", .scratchDirectory)
struct ReviewPayloadTests {
    static let widget = [
        "import Foundation",
        "",
        "struct Widget {",
        "    func render() -> String {",
        "        return \"hello\"",
        "    }",
        "}",
    ]

    private func comment(
        _ path: String,
        line: Int,
        in lines: [String],
        body: String,
        side: ReviewCommentSide = .new,
        id: String? = nil
    ) -> ReviewComment {
        ReviewComment(
            id: id ?? "\(path)#\(line)",
            workspaceID: WorkspaceID("w"),
            filePath: path,
            side: side,
            anchor: ReviewCommentAnchor.make(line: line, in: lines),
            body: body,
            createdAt: Date(timeIntervalSince1970: Double(line))
        )
    }

    private func reader(_ files: [String: [String]]) -> (String) -> [String]? {
        { files[$0] }
    }

    @Test("names the file, the line and the code around it")
    func namesFileAndLine() {
        let note = comment("Sources/Widget.swift", line: 5, in: Self.widget, body: "Return a constant.")
        let text = ReviewPayload.text(
            for: [note],
            currentLines: reader(["Sources/Widget.swift": Self.widget])
        )

        #expect(text == """
        ## Sources/Widget.swift

        ### Line 5

        ```
          2 |
          3 | struct Widget {
          4 |     func render() -> String {
        > 5 |         return "hello"
          6 |     }
          7 | }
        ```

        Return a constant.
        """)
    }

    @Test("reports the new line number and the old one when the line has moved")
    func reportsShift() {
        let note = comment("Sources/Widget.swift", line: 5, in: Self.widget, body: "Still wrong.")
        var edited = Self.widget
        edited.insert(contentsOf: ["// one", "// two"], at: 0)

        let text = ReviewPayload.text(
            for: [note],
            currentLines: reader(["Sources/Widget.swift": edited])
        )

        #expect(text.contains("### Line 7"))
        #expect(text.contains("it was line 5"))
        #expect(text.contains("> 7 |         return \"hello\""))
    }

    @Test("falls back to the code as it looked when the line is gone")
    func fallsBackToSnapshot() {
        let note = comment("Sources/Widget.swift", line: 5, in: Self.widget, body: "Gone.")
        var edited = Self.widget
        edited[4] = "        return \"goodbye\""

        let text = ReviewPayload.text(
            for: [note],
            currentLines: reader(["Sources/Widget.swift": edited])
        )

        #expect(text.contains("this exact line is gone"))
        #expect(text.contains("it was line 5"))
        // The snapshot, not the rewritten line, because the note is about what the reviewer read.
        #expect(text.contains("> 5 |         return \"hello\""))
        #expect(!text.contains("goodbye"))
    }

    @Test("uses the stored snapshot when the file cannot be read at all")
    func worksWithoutTheFile() {
        let note = comment("Sources/Widget.swift", line: 5, in: Self.widget, body: "Unreadable.")
        let text = ReviewPayload.text(for: [note])

        #expect(text.contains("could not be read"))
        #expect(text.contains("> 5 |         return \"hello\""))
        #expect(text.contains("  4 |     func render() -> String {"))
    }

    @Test("says which side of the diff an old-side comment is on")
    func marksOldSide() {
        let note = comment(
            "Sources/Widget.swift", line: 5, in: Self.widget, body: "Why remove this?", side: .old
        )

        #expect(ReviewPayload.text(for: [note]).contains("removed side of the diff"))
    }

    @Test("groups by file, orders by line and renders the same text every time")
    func isStableAcrossFiles() {
        let files = ["a/Alpha.swift": Self.widget, "b/Beta.swift": Self.widget]
        let comments = [
            comment("b/Beta.swift", line: 3, in: Self.widget, body: "beta three"),
            comment("a/Alpha.swift", line: 5, in: Self.widget, body: "alpha five"),
            comment("a/Alpha.swift", line: 3, in: Self.widget, body: "alpha three"),
        ]

        let text = ReviewPayload.text(for: comments, currentLines: reader(files))
        let shuffled = ReviewPayload.text(for: comments.reversed(), currentLines: reader(files))

        #expect(text == shuffled)

        let order = ["## a/Alpha.swift", "alpha three", "alpha five", "## b/Beta.swift", "beta three"]
        var cursor = text.startIndex
        for needle in order {
            let found = text.range(of: needle, range: cursor..<text.endIndex)
            #expect(found != nil, "\(needle) is out of order")
            cursor = found?.upperBound ?? cursor
        }
        // One heading per file, however many notes it carries.
        #expect(text.components(separatedBy: "## a/Alpha.swift").count == 2)
    }

    @Test("two notes on the same line keep the order they were written in")
    func ordersByAge() {
        var first = comment("a.swift", line: 3, in: Self.widget, body: "first", id: "b")
        first.createdAt = Date(timeIntervalSince1970: 1)
        var second = comment("a.swift", line: 3, in: Self.widget, body: "second", id: "a")
        second.createdAt = Date(timeIntervalSince1970: 2)

        let text = ReviewPayload.text(for: [second, first])
        let firstRange = text.range(of: "first")
        let secondRange = text.range(of: "second")

        #expect(firstRange != nil)
        #expect(secondRange != nil)
        if let firstRange, let secondRange { #expect(firstRange.lowerBound < secondRange.lowerBound) }
    }

    @Test("keeps a multi-line body and unicode intact")
    func keepsBodyIntact() {
        let body = "First line 🎉\nSecond line: naïve, with punctuation\n\n- a bullet"
        let note = comment("a.swift", line: 3, in: Self.widget, body: body)

        #expect(ReviewPayload.text(for: [note]).contains(body))
    }

    @Test("lengthens the fence when the code itself contains one")
    func escapesFences() {
        let lines = ["# Title", "```swift", "let x = 1", "```", "text"]
        let note = comment("README.md", line: 3, in: lines, body: "Explain this.")

        let text = ReviewPayload.text(for: [note], currentLines: reader(["README.md": lines]))

        // A three backtick fence would be closed by the file's own fence and the agent would read
        // the rest of the note as prose.
        #expect(text.contains("````\n"))
    }

    @Test("counts the notes it left out once there are too many")
    func obeysTheLimit() {
        let comments = (1...5).map { comment("a.swift", line: $0, in: Self.widget, body: "n\($0)") }

        let text = ReviewPayload.text(for: comments, limit: 2)

        #expect(text.contains("...and 3 more comments not shown."))
        #expect(!text.contains("n5"))
    }

    @Test("renders nothing for no comments")
    func rendersNothing() {
        #expect(ReviewPayload.text(for: []).isEmpty)
    }

    @Test("reads the file out of a worktree")
    func readsFromWorktree() throws {
        let root = TestScratch.unique("worktree")
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        try Self.widget.joined(separator: "\n").write(
            toFile: (root as NSString).appendingPathComponent("Widget.swift"),
            atomically: true,
            encoding: .utf8
        )

        let lines = try #require(ReviewPayload.worktreeReader(root: root)("Widget.swift"))

        #expect(lines == Self.widget)
        #expect(ReviewPayload.worktreeReader(root: root)("nope.swift") == nil)
    }

    @Test("resolves each file only once however many notes it carries")
    func readsEachFileOnce() {
        let comments = (1...4).map { comment("a.swift", line: $0, in: Self.widget, body: "n\($0)") }
        var reads = 0

        _ = ReviewPayload.renders(for: comments) { _ in
            reads += 1
            return Self.widget
        }

        #expect(reads == 1)
    }
}

// MARK: - The prompt itself

@Suite("Review prompt", .scratchDirectory)
struct ReviewPromptTests {
    private var comments: [ReviewComment] {
        [
            ReviewComment(
                workspaceID: WorkspaceID("w"),
                filePath: "Sources/Widget.swift",
                anchor: ReviewCommentAnchor(line: 5, text: "        return \"hello\""),
                body: "Return a constant."
            ),
        ]
    }

    @Test("the default review prompt renders with nothing left over")
    func rendersFully() {
        let definition = PromptRegistry.definition(for: .review)
        let context = ReviewPromptContext(
            message: "Have a look at these.",
            comments: ReviewPayload.text(for: comments),
            count: 1
        )

        let render = context.render(template: definition.defaultTemplate)

        #expect(render.unknown.isEmpty)
        #expect(render.missing.isEmpty)
        #expect(render.text.contains("Have a look at these."))
        #expect(render.text.contains("Sources/Widget.swift"))
        #expect(render.text.contains("Return a constant."))
        #expect(!render.text.contains(PromptTemplate.open))
    }

    @Test("an empty message is replaced rather than left blank")
    func fillsInAnEmptyMessage() {
        let context = ReviewPromptContext(message: "", comments: comments, worktreePath: nil)
        let render = context.render(template: PromptRegistry.definition(for: .review).defaultTemplate)

        #expect(render.text.contains(ReviewPromptContext.noMessage))
        // A blank first line would otherwise read to the agent as a request that got truncated.
        #expect(render.missing.isEmpty)
    }

    @Test("counts the comments it was given")
    func countsComments() {
        let context = ReviewPromptContext(message: "x", comments: comments, worktreePath: nil)

        #expect(context.values[PromptRegistry.Review.count] == "1")
    }

    @Test("resolves against the worktree it is given")
    func resolvesAgainstWorktree() throws {
        let root = TestScratch.unique("worktree")
        try FileManager.default.createDirectory(
            atPath: (root as NSString).appendingPathComponent("Sources"),
            withIntermediateDirectories: true
        )
        // The same line, two lines further down than when the note was written.
        try "a\nb\nc\nd\n        return \"hello\"\nz\n".write(
            toFile: (root as NSString).appendingPathComponent("Sources/Widget.swift"),
            atomically: true,
            encoding: .utf8
        )

        let context = ReviewPromptContext(message: "x", comments: comments, worktreePath: root)

        #expect(context.comments.contains("### Line 5"))
        #expect(!context.comments.contains("could not be read"))
    }
}
