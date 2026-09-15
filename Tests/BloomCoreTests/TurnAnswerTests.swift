import Foundation
import Testing
@testable import BloomCore

@Suite("The answer copied by a turn footer")
struct TurnAnswerTests {
    @Test func preservesTheResultSummary() {
        let summary = "## Done\n\nThe complete answer.\n"
        #expect(TurnAnswer.text(summary: summary, rows: [prose(1, "An update")], endingAt: 2) == summary)
    }

    @Test(arguments: ["", " \n\t"])
    func fallsBackToTheLastAssistantMessage(summary: String) {
        let answer = "## Fixed\n\n- Preserves **Markdown**.\n- And line breaks.\n"
        let rows = [
            row(10, .user), prose(20, "I'll inspect this."), row(30, .toolUse),
            prose(40, answer), row(50, .system), row(60, .result),
            row(70, .user), prose(80, "An answer to a later question"), row(90, .result),
        ]
        #expect(TurnAnswer.text(summary: summary, rows: rows.lazy.map { $0 }, endingAt: 60) == answer)
    }

    @Test func copiesARecordedCodexAnswerAfterTranslationAndPersistence() throws {
        var translation = CodexTranslation(context: .init(model: "gpt-5.6-sol", cwd: "/tmp/w"))
        var rows: [TurnAnswer.Row] = []
        var result: AgentResult?
        for line in try bloomFixtureLines("codex-turn.ndjson") {
            guard case .notification(let notification)? = CodexFrame.decode(line: line) else { continue }
            let event = CodexEvent.decode(notification)
            for translated in translation.translate(event) where translated.isTranscriptRow {
                rows.append(TurnAnswer.Row(seq: rows.count, kind: translated.kind, payload: translated.raw))
                if case .result(let value) = translated { result = value }
            }
        }
        let completed = try #require(result)
        let footer = try #require(rows.last(where: { $0.kind == .result }))
        #expect(completed.summary.isEmpty)
        #expect(TurnAnswer.text(summary: completed.summary, rows: rows, endingAt: footer.seq) == "bloom")
    }

    @Test(arguments: [MessageKind.user, .crew, .result])
    func neverCopiesFromAnEarlierTurn(boundary: MessageKind) {
        let rows = [prose(1, "An earlier answer"), row(2, boundary), row(3, .toolUse), row(4, .result)]
        #expect(TurnAnswer.text(summary: "", rows: rows, endingAt: 4).isEmpty)
    }

    @Test func ignoresSubagentRowsIncludingTheirTurnBoundaries() {
        let rows = [
            row(1, .user), prose(2, "The parent's answer"),
            row(3, .user, isNested: true), prose(4, "A subagent's answer", isNested: true),
            row(5, .result, isNested: true), row(6, .result),
        ]
        #expect(TurnAnswer.text(summary: "", rows: rows, endingAt: 6) == "The parent's answer")
    }

    @Test func skipsEmptyAndMalformedProse() {
        let rows = [prose(1, "The answer"), prose(2, " \n"), row(3, .assistantText), row(4, .result)]
        #expect(TurnAnswer.text(summary: "", rows: rows, endingAt: 4) == "The answer")
    }

    @Test func handlesEmptyAndPartiallyLoadedHistory() {
        #expect(TurnAnswer.text(summary: "", rows: [TurnAnswer.Row](), endingAt: 4).isEmpty)
        let rows = [row(0, .user), prose(1, "The answer"), row(2, .system), row(3, .result)]
        #expect(TurnAnswer.text(summary: "", rows: rows[1...], endingAt: 3) == "The answer")
        #expect(TurnAnswer.text(summary: "", rows: rows[3...], endingAt: 3).isEmpty)
    }

    private func row(_ seq: Int, _ kind: MessageKind, isNested: Bool = false) -> TurnAnswer.Row {
        TurnAnswer.Row(seq: seq, kind: kind, payload: Data(), isNested: isNested)
    }

    private func prose(_ seq: Int, _ text: String, isNested: Bool = false) -> TurnAnswer.Row {
        let payload = JSONValue.object([
            "type": .string("assistant"),
            "message": .object([
                "content": .array([.object(["type": .string("text"), "text": .string(text)])]),
            ]),
        ])
        return TurnAnswer.Row(
            seq: seq, kind: .assistantText, payload: Data(payload.compactJSON.utf8), isNested: isNested
        )
    }
}
