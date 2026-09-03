import Testing
@testable import BloomCore

/// The report behind this is a screenshot of one tab split in two, a chat on the left and a
/// README on the right, with a composer under each and the same half typed sentence in both. See
/// `ReviewComposer`.
@Suite("The review pane's composer")
struct ReviewComposerTests {
    private let chat = SessionID("session-1")
    private let review = PaneContent.tool("review-tab")

    /// The screenshot. The chat's own composer is a hand's width away, so this pane draws none.
    @Test func staysAwayFromAChatInTheSameTab() {
        #expect(!ReviewComposer.isDrawn(
            destination: chat, panes: [.chat(chat), review]
        ))
    }

    /// A review filling its tab on its own. Take the composer away here and there is nowhere in
    /// the window to answer the diff being read.
    @Test func drawnWhenTheReviewIsAloneInItsTab() {
        #expect(ReviewComposer.isDrawn(destination: chat, panes: [review]))
    }

    /// Two files side by side is still no conversation on screen.
    @Test func drawnBesideAnotherReview() {
        #expect(ReviewComposer.isDrawn(
            destination: chat, panes: [review, .tool("review-tab-2")]
        ))
    }

    /// A chat that is a tab away is one the reader cannot see. Only one tab's panes are drawn at a
    /// time, so counting it would leave this pane with no way to send.
    @Test func drawnWhenTheChatIsInAnotherTab() {
        // The conversation exists, and is even the one this pane would send to, but it roots a tab
        // of its own rather than sitting in a pane beside this review. That absence from the list
        // is the whole of the case.
        let panes = [review]
        #expect(!panes.contains(.chat(chat)))
        #expect(ReviewComposer.isDrawn(destination: chat, panes: panes))
    }

    /// The pane beside this one holds a different conversation, so its composer sends somewhere
    /// else and the chips staged on this diff would be stranded by hiding this one.
    @Test func drawnBesideAChatItDoesNotSendTo() {
        #expect(ReviewComposer.isDrawn(
            destination: chat, panes: [.chat(SessionID("session-2")), review]
        ))
    }

    /// A workspace with no session at all: nothing to send to, so nothing to type into.
    @Test func notDrawnWithoutASession() {
        #expect(!ReviewComposer.isDrawn(destination: nil, panes: [review]))
    }
}
