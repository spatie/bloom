import Foundation
import Testing
@testable import BloomCore

/// The order the user dragged the strip into, laid over the two runs `TabSet` would otherwise give.
@Suite("StripOrder")
struct StripOrderTests {
    private let one = SessionID("s1")
    private let two = SessionID("s2")

    // MARK: - Reading

    /// The whole safety of this: a workspace nobody has dragged reads exactly as it did before any
    /// of it existed, so no key means no change and there is nothing to migrate.
    @Test("a workspace with no stored order reads as the two runs")
    func noStoredOrder() {
        let entries = StripOrder.entries(sessions: [one, two], tools: ["t1"])

        #expect(entries == [.chat(one), .chat(two), .tool("t1")])
        #expect(entries == TabSet.entries(sessions: [one, two], tools: ["t1"]))
    }

    /// The feature, in one line: a terminal can sit before a conversation.
    @Test("a stored order puts a tool tab before a conversation")
    func interleaved() {
        let entries = StripOrder.entries(
            sessions: [one, two], tools: ["t1"],
            stored: [.tool("t1"), .chat(one), .chat(two)]
        )

        #expect(entries == [.tool("t1"), .chat(one), .chat(two)])
    }

    /// Somebody who has arranged their tabs by hand expects a new one at the end of the STRIP, not
    /// at the end of its own kind, which is where the two run rule would have put it.
    @Test("something the stored order has never heard of goes at the end")
    func newArrivalsGoLast() {
        let entries = StripOrder.entries(
            sessions: [one, two], tools: ["t1"],
            stored: [.tool("t1"), .chat(one)]
        )

        #expect(entries == [.tool("t1"), .chat(one), .chat(two)])
    }

    @Test("several new arrivals keep the order the two runs would have given them")
    func newArrivalsKeepTheFallbackOrder() {
        let entries = StripOrder.entries(
            sessions: [one, two], tools: ["t1", "t2"],
            stored: [.tool("t2")]
        )

        #expect(entries == [.tool("t2"), .chat(one), .chat(two), .tool("t1")])
    }

    @Test("a stored order naming something that has gone simply does not draw it")
    func storedOrderNamingTheDeparted() {
        let entries = StripOrder.entries(
            sessions: [one], tools: [],
            stored: [.tool("closed"), .chat(one), .chat(SessionID("archived"))]
        )

        #expect(entries == [.chat(one)])
    }

    /// A thing absorbed into a pane of another tab is reachable through that tab and must not also
    /// be a tab of its own, whatever the stored order says. See `TabSet`.
    @Test("a stored order cannot bring an absorbed tab back into the strip")
    func claimedStaysOut() {
        let entries = StripOrder.entries(
            sessions: [one, two], tools: ["t1"],
            claimed: [.chat(two)],
            stored: [.tool("t1"), .chat(two), .chat(one)]
        )

        #expect(entries == [.tool("t1"), .chat(one)])
    }

    /// A half written or hand edited list could name the same thing twice, which would draw one tab
    /// in two places and give the strip two views with one identity.
    @Test("a stored order naming something twice draws it once")
    func duplicatesInTheStoredOrder() {
        let entries = StripOrder.entries(
            sessions: [one], tools: ["t1"],
            stored: [.chat(one), .tool("t1"), .chat(one)]
        )

        #expect(entries == [.chat(one), .tool("t1")])
    }

    @Test("an empty workspace has an empty strip whatever is stored")
    func emptyWorkspace() {
        #expect(StripOrder.entries(sessions: [], tools: [], stored: [.chat(one)]).isEmpty)
    }

    // MARK: - Writing

    @Test("dragging a tool tab in front of a conversation is written down")
    func writesTheDrag() {
        let order = StripOrder.rewritten(
            [.tool("t1"), .chat(one)],
            sessions: [one], tools: ["t1"], stored: []
        )

        #expect(order == [.tool("t1"), .chat(one)])
    }

    @Test("a drag that changes nothing writes nothing")
    func writesNothingWhenNothingMoved() {
        #expect(
            StripOrder.rewritten(
                [.chat(one), .tool("t1")],
                sessions: [one], tools: ["t1"], stored: [.chat(one), .tool("t1")]
            ) == nil
        )
    }

    /// An absorbed thing is not drawn and cannot have been dragged, and it keeps the slot it
    /// already held, so closing the tab that holds it hands it back where the user left it rather
    /// than at the far end.
    @Test("what the strip cannot see keeps its place in what is written")
    func absorbedEntriesKeepTheirSlots() {
        let order = StripOrder.rewritten(
            [.tool("t2"), .chat(one)],
            sessions: [one], tools: ["t1", "t2"],
            stored: [.chat(one), .tool("t1"), .tool("t2")]
        )

        // `t1` is absorbed, so it was not drawn. It holds slot 1 throughout.
        #expect(order == [.tool("t2"), .tool("t1"), .chat(one)])
        #expect(order?[1] == .tool("t1"))
    }

    /// Without this the list would grow for the life of the workspace, naming every conversation
    /// ever closed.
    @Test("writing prunes what no longer exists")
    func writingPrunes() {
        let order = StripOrder.rewritten(
            [.tool("t1"), .chat(one)],
            sessions: [one], tools: ["t1"],
            stored: [.chat(SessionID("gone")), .chat(one), .tool("t1")]
        )

        #expect(order == [.tool("t1"), .chat(one)])
    }

    /// A workspace that has never been dragged but has gained tabs since gets a list seeded from
    /// the two runs, so the first drag is written against something rather than against nothing.
    @Test("a first drag is written against everything the workspace has")
    func seedsFromBothRuns() {
        let order = StripOrder.rewritten(
            [.chat(two), .chat(one)],
            sessions: [one, two], tools: ["t1"], stored: []
        )

        #expect(order == [.chat(two), .chat(one), .tool("t1")])
    }

    @Test("what is written always holds each thing exactly once")
    func alwaysWholeAndUnique() throws {
        let order = StripOrder.rewritten(
            [.tool("t1"), .chat(two), .chat(one)],
            sessions: [one, two], tools: ["t1", "t2"],
            stored: [.tool("t2"), .chat(one)]
        )

        // `try #require` in a throwing test, not `try? #require`. That pair unwrapped the
        // optional and then wrapped it straight back up, which is what the compiler was calling
        // redundant and what left the test target with its only warning. A nil here now fails
        // this test where it happens rather than three optional-chained expectations later.
        let written = try #require(order)
        #expect(written.count == 4)
        #expect(Set(written).count == 4)
        #expect(Set(written) == Set(TabSet.all(sessions: [one, two], tools: ["t1", "t2"])))
    }

    /// The round trip that matters: whatever is written must read back as the strip the user was
    /// looking at when they let go.
    @Test("what is written reads back as the strip that was dragged")
    func roundTrip() {
        let drawn: [PaneContent] = [.tool("t1"), .chat(two), .chat(one)]
        let order = StripOrder.rewritten(
            drawn, sessions: [one, two], tools: ["t1"], stored: []
        )

        #expect(
            StripOrder.entries(sessions: [one, two], tools: ["t1"], stored: order ?? [])
                == drawn
        )
    }
}
