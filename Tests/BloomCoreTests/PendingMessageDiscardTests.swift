import Testing
import Foundation
@testable import BloomCore

/// Deleting a message that has not gone yet, and what becomes of the words in it.
@Suite("Discarding a pending message")
struct PendingMessageDiscardTests {
    private func delivery(_ body: String, delivered: Bool = false) -> Delivery {
        Delivery(
            targetSessionID: SessionID("s"),
            body: body,
            deliveredAt: delivered ? Date() : nil
        )
    }

    @Test("a message still in the queue can be taken back")
    func pendingIsDiscardable() {
        #expect(PendingMessageDiscard.canDiscard(delivery("sdfsd")))
    }

    /// The same rule `Store.cancelDelivery`'s `WHERE` holds, asked before the sheet opens rather
    /// than after it is answered.
    @Test("a message that has gone cannot be taken back")
    func deliveredIsNotDiscardable() {
        #expect(!PendingMessageDiscard.canDiscard(delivery("sdfsd", delivered: true)))
    }

    // MARK: - Where the words go

    @Test("hands the sentence back to an empty composer")
    func plainTextGoesBack() {
        let recovery = PendingMessageDiscard.recovery(
            of: delivery("sdfsd\nsdfsdf"), composerDraft: ""
        )
        #expect(recovery == .toComposer("sdfsd\nsdfsdf"))
    }

    /// A box holding nothing but whitespace is not something anybody is in the middle of writing.
    @Test("a blank composer counts as empty")
    func blankComposerIsEmpty() {
        let recovery = PendingMessageDiscard.recovery(of: delivery("one"), composerDraft: " \n\n ")
        #expect(recovery == .toComposer("one"))
    }

    /// The trade `TranscriptModel` already refused when a failed send used to push its prompt back
    /// into the box: rescuing what was typed earlier by pasting over what is being typed now.
    @Test("will not paste over something being typed")
    func composerInUseKeepsItsOwnText() {
        let recovery = PendingMessageDiscard.recovery(
            of: delivery("one"), composerDraft: "half a thought"
        )
        #expect(recovery == .discarded(.composerInUse))
    }

    @Test("will not put attached files back as text")
    func attachmentsAreNotPlainText() {
        let body = AttachmentTrailer.compose(text: "look at this", paths: ["/tmp/shot.png"])
        #expect(PendingMessageDiscard.recovery(of: delivery(body), composerDraft: "")
            == .discarded(.notPlainText))
    }

    @Test("will not put a rendered review prompt back as text")
    func reviewTurnsAreNotPlainText() {
        let comment = ReviewComment(
            id: ReviewCommentID("Sources/Widget.swift#3#new"),
            workspaceID: WorkspaceID("w"),
            filePath: "Sources/Widget.swift",
            side: .new,
            anchor: ReviewCommentAnchor.make(line: 1, in: ["struct Widget {}"]),
            body: "rename this",
            createdAt: Date(timeIntervalSince1970: 1)
        )
        let body = ReviewTurn.compose(
            message: "Fix this.",
            comments: [comment],
            worktreePath: nil,
            template: PromptRegistry.definition(for: .review).defaultTemplate
        )
        #expect(PendingMessageDiscard.recovery(of: delivery(body), composerDraft: "")
            == .discarded(.notPlainText))
    }

    // MARK: - The question

    /// The sentence has to say which of the two it is, because that is what decides the answer.
    @Test("says where the words end up, and the two answers differ")
    func questionNamesTheOutcome() {
        let kept = PendingMessageDiscard.question(for: .toComposer("one"))
        let lost = PendingMessageDiscard.question(for: .discarded(.composerInUse))

        #expect(kept.title == lost.title)
        #expect(kept.message != lost.message)
        #expect(kept.message.contains("composer"))
        #expect(lost.message.contains("not kept"))
        #expect(kept.confirmLabel == "Delete")
        // Escape lands on this one, so it says what happens rather than "Cancel", which in a
        // dialog about cancelling a message reads as the message.
        #expect(kept.cancelLabel == "Keep")
    }
}
