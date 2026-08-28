import Foundation
import Testing
@testable import BloomCore

@Suite("User turn prompt")
struct UserTurnPromptTests {
    private func payload(_ text: String) -> Data {
        let json = JSONValue.object([
            "type": .string("user"),
            "message": .object([
                "role": .string("user"),
                "content": .array([.object([
                    "type": .string("text"),
                    "text": .string(text),
                ])]),
            ]),
        ])
        return Data(json.compactJSON.utf8)
    }

    @Test("a long multi-line question becomes one bounded line")
    func boundedSummary() {
        let result = UserTurnPrompt.summary(in: payload("  Why is this\n\nso slow today?  "), limit: 16)

        #expect(result == "Why is this so s…")
    }

    @Test("an attachment trailer stays out of the pinned question")
    func attachmentsStayOut() {
        let turn = AttachmentTrailer.compose(
            text: "Please inspect this", paths: [".bloom/attachments/screenshot.png"]
        )

        #expect(UserTurnPrompt.summary(in: payload(turn)) == "Please inspect this")
    }

    @Test("an attachment-only turn still has a useful name")
    func attachmentOnly() {
        let turn = AttachmentTrailer.compose(
            text: "", paths: [".bloom/attachments/screenshot.png"]
        )

        #expect(UserTurnPrompt.summary(in: payload(turn)) == "Attached screenshot.png")
    }

    @Test("merge rules stay out of the pinned question")
    func mergeRulesStayOut() {
        let turn = ProjectInstructions.turn(
            "Merge pull request #42.", for: .merge, adding: .nothing
        )

        #expect(UserTurnPrompt.summary(in: payload(turn)) == "Merge pull request #42.")
    }
}
