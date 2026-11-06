import Foundation
import Testing
@testable import BloomCore

@Suite("The text Select All copies for a whole conversation")
struct ConversationTextTests {
    @Test func labelsBothSidesInOrderAndSkipsEverythingElse() {
        let rows = [
            user(1, "Fix the bug"), prose(2, "Looking."), row(3, .toolUse),
            prose(4, "Fixed."), row(5, .result),
        ]
        #expect(ConversationText.text(of: rows) == "You:\nFix the bug\n\nAgent:\nLooking.\n\nAgent:\nFixed.")
    }

    @Test func leavesOutSubagentConversations() {
        let rows = [user(1, "Go"), prose(2, "A subagent", isNested: true), prose(3, "Done")]
        #expect(ConversationText.text(of: rows) == "You:\nGo\n\nAgent:\nDone")
    }

    @Test func dropsTheAttachmentPathsTheBubbleHides() {
        let sent = AttachmentTrailer.compose(text: "Look at this", paths: [".bloom/attachments/A1/shot.png"])
        let rows = [user(1, sent)]
        #expect(ConversationText.text(of: rows) == "You:\nLook at this")
    }

    @Test func skipsEmptyTurnsAndAnEmptyConversation() {
        #expect(ConversationText.text(of: [user(1, " \n"), prose(2, ""), row(3, .assistantText)]).isEmpty)
        #expect(ConversationText.text(of: [TurnAnswer.Row]()).isEmpty)
    }

    @Test func aDragTakesWholeRowsBetweenAndOnlyTheSelectedWordsAtBothEnds() {
        let rows = [
            user(1, "Before"), prose(2, "An answer that was only partly dragged over"),
            user(3, "Whole"), prose(4, "Whole too"), user(5, "A question cut short"), prose(6, "After"),
        ]
        let slice = ConversationText.Slice(
            first: 2, last: 5, firstText: "dragged over", lastText: "A question"
        )
        #expect(
            ConversationText.text(of: rows, in: slice)
                == "Agent:\ndragged over\n\nYou:\nWhole\n\nAgent:\nWhole too\n\nYou:\nA question"
        )
    }

    @Test func aDragThroughNothingThatIsTextCopiesNothing() {
        let rows = [row(1, .toolUse), row(2, .toolUse)]
        let slice = ConversationText.Slice(first: 1, last: 2, firstText: "x", lastText: "y")
        #expect(ConversationText.text(of: rows, in: slice).isEmpty)
    }

    @Test func aQuestionCardIsCopiedWithItsOptions() {
        let ask = #"{"type":"control_request","request_id":"ask-1","request":{"subtype":"can_use_tool","tool_name":"AskUserQuestion","input":{"questions":[{"header":"Db","question":"Which database?","options":[{"label":"SQLite","description":"One file"},{"label":"Postgres"}]}]}}}"#
        let rows = [user(1, "Go"), TurnAnswer.Row(seq: 2, kind: .permissionAsk, payload: Data(ask.utf8))]
        #expect(
            ConversationText.text(of: rows)
                == "You:\nGo\n\nAgent:\nDB\nWhich database?\n- SQLite\n  One file\n- Postgres"
        )
    }

    @Test func aPermissionRequestIsNotCopied() {
        let ask = #"{"type":"control_request","request_id":"bash-1","request":{"subtype":"can_use_tool","tool_name":"Bash","input":{"command":"ls"}}}"#
        let rows = [TurnAnswer.Row(seq: 1, kind: .permissionAsk, payload: Data(ask.utf8))]
        #expect(ConversationText.text(of: rows).isEmpty)
    }

    private func row(_ seq: Int, _ kind: MessageKind) -> TurnAnswer.Row {
        TurnAnswer.Row(seq: seq, kind: kind, payload: Data())
    }

    private func user(_ seq: Int, _ text: String) -> TurnAnswer.Row {
        let payload = JSONValue.object([
            "type": .string("user"),
            "message": .object(["role": .string("user"), "content": .string(text)]),
        ])
        return TurnAnswer.Row(seq: seq, kind: .user, payload: Data(payload.compactJSON.utf8))
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
