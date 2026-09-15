import Foundation
import Testing
@testable import BloomCore

/// A subagent's pane reads like the chat: working folds into "N actions", prose stays standing.
///
/// The fold itself is `TranscriptFold`'s and is tested there. What is held down here is the pane's
/// half: the entries it emits, and the two ways it differs from the chat, which are that every row
/// is top level and that a fold is named by whatever stable identity the caller put in `seq`.
@Suite("Laying out a subagent's conversation")
struct SubagentConversationTests {
    /// The parent Task call every line on the live stream carries.
    private static let parent = "toolu_task"

    private func tool(_ seq: Int, settled: Bool = true) -> TranscriptFold.Fact {
        TranscriptFold.Fact(
            seq: seq, kind: .toolUse, settled: settled, toolUseID: "call\(seq)",
            parentToolUseID: Self.parent
        )
    }

    private func thinking(_ seq: Int) -> TranscriptFold.Fact {
        TranscriptFold.Fact(seq: seq, kind: .thinking, parentToolUseID: Self.parent)
    }

    private func prose(_ seq: Int) -> TranscriptFold.Fact {
        TranscriptFold.Fact(seq: seq, kind: .assistantText, parentToolUseID: Self.parent)
    }

    /// The owner's screenshot: thinking, a run of tool calls, then the answer. It drew as a flat
    /// column of every call; it now draws as one line and the answer.
    @Test func aRunOfWorkFoldsIntoOneLineAboveTheAnswer() {
        let facts = [thinking(-1), tool(-2), tool(-3), tool(-4), tool(-5), prose(-6)]
        let entries = SubagentConversation.entries(facts: facts, unfolded: [], revealed: [])
        #expect(entries == [
            .fold(firstSeq: -1, hiding: 5, showsMore: false, isFolded: true),
            .row(index: 5, seq: -6),
        ])
    }

    /// Prose between runs stays visible and splits the work either side of it, as in the chat.
    @Test func proseDividesTheWorkIntoSeparateFolds() {
        let facts = [tool(1), tool(2), tool(3), prose(4), tool(5), tool(6), tool(7), prose(8)]
        let entries = SubagentConversation.entries(facts: facts, unfolded: [], revealed: [])
        #expect(entries.map(\.id) == [.fold(1), .row(4), .fold(5), .row(8)])
    }

    /// Every line off the live stream carries the Task call's id. Read as the chat reads it, each
    /// fold line would be drawn nested behind a rule with nothing above it; here the subagent is
    /// the conversation, and this is the same run whether the id is there or not.
    @Test func theParentIdOnEveryRowDoesNotNestOrSplitAnything() {
        let nested = [tool(1), tool(2), tool(3)]
        let flat = nested.map { fact in
            var own = fact
            own.parentToolUseID = nil
            return own
        }
        let fromNested = SubagentConversation.entries(facts: nested, unfolded: [], revealed: [])
        let fromFlat = SubagentConversation.entries(facts: flat, unfolded: [], revealed: [])
        #expect(fromNested == fromFlat)
        #expect(fromNested == [.fold(firstSeq: 1, hiding: 3, showsMore: false, isFolded: true)])
    }

    /// Opened, the line stays and says how many rows the run holds, and every row is drawn under
    /// it: the same expanded rows the chat shows.
    @Test func anOpenedRunDrawsEveryRowUnderItsLine() {
        let facts = [tool(1), tool(2), tool(3), prose(4)]
        let entries = SubagentConversation.entries(facts: facts, unfolded: [1], revealed: [])
        #expect(entries == [
            .fold(firstSeq: 1, hiding: 3, showsMore: false, isFolded: false),
            .row(index: 0, seq: 1), .row(index: 1, seq: 2), .row(index: 2, seq: 3),
            .row(index: 3, seq: 4),
        ])
    }

    /// While the subagent works, the call still running stays on screen below the count of what
    /// has finished, so the reader can see what it is doing now.
    @Test func aCallStillRunningStandsBelowItsFold() {
        let facts = [tool(1), tool(2), tool(3), tool(4, settled: false)]
        let entries = SubagentConversation.entries(facts: facts, unfolded: [], revealed: [])
        #expect(entries == [
            .fold(firstSeq: 1, hiding: 3, showsMore: true, isFolded: true),
            .row(index: 3, seq: 4),
        ])
    }

    /// Two calls are not worth a control, which is `TranscriptFold.leastHidden` in the chat too.
    @Test func tooShortARunIsDrawnAsItsRows() {
        let facts = [tool(1), tool(2), prose(3)]
        let entries = SubagentConversation.entries(facts: facts, unfolded: [], revealed: [])
        #expect(entries.map(\.id) == [.row(1), .row(2), .row(3)])
    }

    /// A result somebody opened is not folded away under them when the rest of the run settles.
    @Test func anOpenedRowCapsWhatItsRunHides() {
        let facts = [tool(1), tool(2), tool(3), tool(4), tool(5), tool(6)]
        let entries = SubagentConversation.entries(facts: facts, unfolded: [], revealed: [4])
        #expect(entries.map(\.id) == [.fold(1), .row(4), .row(5), .row(6)])
    }

    /// The pane re-reads once a second and hands over from the live stream to the file, so the
    /// identities are payload derived ids rather than positions. Rows dropped off the front must
    /// not move which run the reader opened.
    @Test func aFoldKeepsItsIdentityWhenEarlierRowsAreDropped() {
        let before = [prose(-9), tool(-1), tool(-2), tool(-3), prose(-4)]
        let after = Array(before.dropFirst())
        let opened = SubagentConversation.entries(facts: before, unfolded: [-1], revealed: [])
        let reread = SubagentConversation.entries(facts: after, unfolded: [-1], revealed: [])
        #expect(opened.first(where: { $0.id == .fold(-1) }) == reread.first)
        #expect(reread.first == .fold(firstSeq: -1, hiding: 3, showsMore: false, isFolded: false))
    }
}
