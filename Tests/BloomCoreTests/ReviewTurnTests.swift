import Testing
import Foundation
@testable import BloomCore

/// A sent review turn has two readers with opposite needs: the agent wants everything, the
/// transcript wants the typed words and a chip per comment. `compose` and `split` are the pair
/// that keeps those two views of one message agreeing, so the suite is mostly round trips.
@Suite("Review turn")
struct ReviewTurnTests {
    static let widget = [
        "import Foundation",
        "",
        "struct Widget {",
        "    func render() -> String {",
        "        return \"hello\"",
        "    }",
        "}",
    ]

    private var template: String {
        PromptRegistry.definition(for: .review).defaultTemplate
    }

    private func comment(
        _ path: String,
        line: Int,
        in lines: [String] = widget,
        body: String,
        side: ReviewCommentSide = .new
    ) -> ReviewComment {
        ReviewComment(
            id: ReviewCommentID("\(path)#\(line)#\(side.rawValue)"),
            workspaceID: WorkspaceID("w"),
            filePath: path,
            side: side,
            anchor: ReviewCommentAnchor.make(line: line, in: lines),
            body: body,
            createdAt: Date(timeIntervalSince1970: Double(line))
        )
    }

    @Test("round-trips the message and one chip per comment")
    func roundTrips() throws {
        let comments = [
            comment("Sources/Widget.swift", line: 5, body: "is this the right constant?"),
            comment("Sources/Other.swift", line: 3, body: "rename this"),
        ]
        let sent = ReviewTurn.compose(
            message: "Fix these two things.",
            comments: comments,
            worktreePath: nil,
            template: template
        )

        let record = try #require(ReviewTurn.split(sent))
        #expect(record.message == "Fix these two things.")
        #expect(record.chips.count == 2)
        // Payload order is path order, so Other.swift leads.
        #expect(record.chips[0].filePath == "Sources/Other.swift")
        #expect(record.chips[0].line == 3)
        #expect(record.chips[0].body == "rename this")
        #expect(record.chips[1].filePath == "Sources/Widget.swift")
        #expect(record.chips[1].body == "is this the right constant?")
    }

    @Test("a turn of nothing but comments comes back with an empty message")
    func emptyMessage() throws {
        let sent = ReviewTurn.compose(
            message: "",
            comments: [comment("A.swift", line: 5, body: "tighten this")],
            worktreePath: nil,
            template: template
        )

        // The agent is told the comments are the whole request rather than being handed a
        // heading with nothing under it.
        #expect(sent.hasPrefix(ReviewPromptContext.noMessage))

        let record = try #require(ReviewTurn.split(sent))
        #expect(record.message.isEmpty)
        #expect(record.chips.count == 1)
    }

    @Test("an old-side comment keeps its side through the round trip")
    func oldSideSurvives() throws {
        let sent = ReviewTurn.compose(
            message: "m",
            comments: [comment("A.swift", line: 4, body: "why was this removed?", side: .old)],
            worktreePath: nil,
            template: template
        )

        let record = try #require(ReviewTurn.split(sent))
        #expect(record.chips.first?.side == .old)
        #expect(record.chips.first?.line == 4)
    }

    @Test("a multi-line body and a body containing a code fence survive")
    func multiLineBody() throws {
        let body = "First thought.\n\nSecond thought with `backticks` in it."
        let sent = ReviewTurn.compose(
            message: "m",
            comments: [comment("A.swift", line: 5, body: body)],
            worktreePath: nil,
            template: template
        )

        let record = try #require(ReviewTurn.split(sent))
        #expect(record.chips.first?.body == body)
    }

    @Test("a multi-line message survives")
    func multiLineMessage() throws {
        let message = "Two things.\n\nBoth small."
        let sent = ReviewTurn.compose(
            message: message,
            comments: [comment("A.swift", line: 5, body: "b")],
            worktreePath: nil,
            template: template
        )

        #expect(ReviewTurn.split(sent)?.message == message)
    }

    @Test("the chip label names the file and the start of the comment")
    func chipLabel() {
        let chip = ReviewTurnRecord.Chip(
            filePath: "Sources/Widget.swift",
            side: .new,
            line: 5,
            body: "is this  the\nright constant?"
        )
        #expect(chip.label == "Widget.swift is this the right constant?")
    }

    @Test("an ordinary message is not mistaken for a review turn")
    func ordinaryMessage() {
        #expect(ReviewTurn.split("Please review the diff and fix the bug.") == nil)
        #expect(ReviewTurn.split("") == nil)
        // Even one that talks in headings.
        #expect(ReviewTurn.split("## A.swift\n\n### Line 4\n\nnot a payload") == nil)
    }

    @Test("a customised template renders full text rather than a wrong split")
    func customTemplate() {
        let sent = ReviewTurn.compose(
            message: "m",
            comments: [comment("A.swift", line: 5, body: "b")],
            worktreePath: nil,
            template: "Do what the notes say.\n\n{{comments}}"
        )
        #expect(ReviewTurn.split(sent) == nil)
    }

    @Test("a moved line's provenance is not folded into the chip body")
    func provenanceStaysOut() throws {
        let moved = ["// new first line"] + Self.widget
        let note = comment("A.swift", line: 5, body: "still about the return")
        let sent = ReviewTurn.compose(
            message: "m",
            comments: [note],
            worktreePath: nil,
            template: template
        )
        _ = moved

        // Resolve against a shifted file through the payload's own reader.
        let payload = ReviewPayload.text(for: [note], currentLines: { _ in moved })
        let shifted = PromptTemplate.render(template, values: [
            PromptRegistry.Review.message: "m",
            PromptRegistry.Review.comments: payload,
            PromptRegistry.Review.count: "1",
        ]).text

        let record = try #require(ReviewTurn.split(shifted))
        #expect(record.chips.first?.line == 6)
        #expect(record.chips.first?.body == "still about the return")
        _ = sent
    }

    @Test("the truncation tail past the comment limit is not read as a chip")
    func truncationTail() throws {
        let comments = (1...(ReviewPayload.commentLimit + 3)).map {
            comment("A.swift", line: 5, body: "note \($0)")
        }
        let sent = ReviewTurn.compose(
            message: "m", comments: comments, worktreePath: nil, template: template
        )

        let record = try #require(ReviewTurn.split(sent))
        #expect(record.chips.count == ReviewPayload.commentLimit)
    }

    @Test("a quoted scaffold in the message does not produce a wrong split")
    func quotedScaffold() {
        let real = ReviewTurn.compose(
            message: "m",
            comments: [comment("A.swift", line: 5, body: "b")],
            worktreePath: nil,
            template: template
        )
        // Somebody pastes a whole previous review turn as their message and sends it without
        // comments attached: it is not composed at all, so it must come back as itself. The
        // only risk would be a *partial* quote that ends at the scaffold, which fails the
        // payload parse and falls back to full text.
        guard let scaffoldStart = real.range(of: "I reviewed the diff") else {
            Issue.record("the default template changed shape; update this test")
            return
        }
        let partial = String(real[..<scaffoldStart.lowerBound]) + "I reviewed the diff myself."
        #expect(ReviewTurn.split(partial) == nil)
    }
}
