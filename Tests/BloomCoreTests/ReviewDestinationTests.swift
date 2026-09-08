import Testing
import Foundation
@testable import BloomCore

/// A review's comments belong to the workspace rather than to a chat, so which conversation they
/// are handed to is a choice. What matters here is that the choice can never leave the composer
/// pointing at a chat that is not there: one can be closed or archived while the review pane is
/// still open on it.
@Suite("Review destination")
struct ReviewDestinationTests {
    private let first = SessionID("s1")
    private let second = SessionID("s2")
    private let gone = SessionID("s3")

    @Test("the chosen chat wins while it exists")
    func prefersTheChoice() {
        #expect(ReviewDestination.resolved(
            chosen: second, active: first, sessions: [first, second]
        ) == second)
    }

    @Test("a chat closed under the review falls back to the active one")
    func fallsBackToActive() {
        #expect(ReviewDestination.resolved(
            chosen: gone, active: first, sessions: [first, second]
        ) == first)
    }

    @Test("with nothing chosen it goes where the workspace is pointed")
    func followsTheWorkspace() {
        #expect(ReviewDestination.resolved(
            chosen: nil, active: second, sessions: [first, second]
        ) == second)
    }

    @Test("an active chat that has gone too falls back to the first")
    func fallsBackToTheFirst() {
        #expect(ReviewDestination.resolved(
            chosen: gone, active: gone, sessions: [first, second]
        ) == first)
        #expect(ReviewDestination.resolved(chosen: nil, active: nil, sessions: [second]) == second)
    }

    @Test("a workspace with no chat has nowhere to send")
    func nowhereToSend() {
        #expect(ReviewDestination.resolved(chosen: gone, active: gone, sessions: []) == nil)
    }

    @Test("one chat is not a choice")
    func offersNoMenuForOne() {
        #expect(!ReviewDestination.isChoosable(sessions: []))
        #expect(!ReviewDestination.isChoosable(sessions: [first]))
        #expect(ReviewDestination.isChoosable(sessions: [first, second]))
    }

    @Test("the strip names the chat, and says Chat when it has no name yet")
    func label() {
        #expect(ReviewDestination.label(for: "Fix the parser")
            == "Messages are sent to Fix the parser")
        #expect(ReviewDestination.label(for: "") == "Messages are sent to Chat")
        #expect(ReviewDestination.label(for: "   ") == "Messages are sent to Chat")
    }
}
