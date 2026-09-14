import Testing
@testable import BloomCore

@Suite("Submitted drafts")
struct SubmittedDraftTests {
    @Test("Expanded review payloads clear the compact source draft")
    func clearsSource() {
        let draft = "`.bloom/attachments/ABC/area.png` "
        #expect(SubmittedDraft.matching(current: draft, message: "Expanded image comment", source: draft) == draft)
    }

    @Test("Typing while a review is prepared prevents the new draft from being cleared")
    func protectsNewText() {
        #expect(SubmittedDraft.matching(current: "Original plus new words", message: "Expanded review", source: "Original") == nil)
    }

    @Test("Ordinary submissions still clear only a matching draft")
    func normalSubmission() {
        #expect(SubmittedDraft.matching(current: " Hello \n", message: "Hello") == " Hello \n")
        #expect(SubmittedDraft.matching(current: "Other words", message: "Hello") == nil)
    }
}
