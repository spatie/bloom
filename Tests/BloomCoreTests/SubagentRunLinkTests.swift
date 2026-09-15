import Foundation
import Testing
@testable import BloomCore

/// What the Agent call row in the chat opens.
///
/// **The regression this is written against.** The chat stopped drawing a subagent's rows and let
/// its call row stand for them, and nothing in the chat opened the run: the pane was reached from
/// the sidebar alone, whose row goes seconds after a subagent succeeds, and from a roster that
/// forgets it at the next turn and entirely on a relaunch. A finished subagent's work could not be
/// reached from the conversation it happened in.
@Suite("Opening a subagent's run from its call")
struct SubagentRunLinkTests {
    private func none() -> SubagentID? { nil }

    @Test("the roster's subagent is preferred while it still holds one")
    func liveWins() {
        let target = SubagentRunLink.target(
            toolUseID: "toolu_1", hasRecordedRows: true, isSettled: true, liveID: { SubagentID("task") }
        )
        #expect(target == .live(SubagentID("task")))
    }

    /// The case the roster cannot answer: retired from the sidebar, cleared by the next turn, or
    /// gone with a relaunch. The rows stored under the call are the run.
    @Test("a finished subagent the roster has forgotten opens from its stored rows")
    func forgottenOpensRecorded() {
        let target = SubagentRunLink.target(
            toolUseID: "toolu_1", hasRecordedRows: true, isSettled: true, liveID: none
        )
        #expect(target == .recorded(toolUseID: "toolu_1"))
    }

    @Test("a call still running opens even before its first row has landed")
    func runningOpens() {
        let target = SubagentRunLink.target(
            toolUseID: "toolu_1", hasRecordedRows: false, isSettled: false, liveID: none
        )
        #expect(target == .recorded(toolUseID: "toolu_1"))
    }

    @Test("a finished call with nothing kept under it is unavailable rather than an empty pane")
    func nothingKept() {
        let target = SubagentRunLink.target(
            toolUseID: "toolu_1", hasRecordedRows: false, isSettled: true, liveID: none
        )
        #expect(target == .unavailable)
        #expect(SubagentRunLink.target(toolUseID: nil, hasRecordedRows: true, isSettled: false, liveID: none) == .unavailable)
        #expect(SubagentRunLink.target(toolUseID: "", hasRecordedRows: true, isSettled: false, liveID: none) == .unavailable)
    }

    /// The row decides whether to offer the click with the roster asked last, and what the click
    /// opens with it asked first. The two must never disagree about whether there is anything.
    @Test(
        "whether the row offers to open agrees with what opening finds",
        arguments: [true, false], [true, false]
    )
    func canOpenAgreesWithTarget(hasRows: Bool, isSettled: Bool) {
        for live in [true, false] {
            for id in ["toolu_1", "", nil] as [String?] {
                let target = SubagentRunLink.target(
                    toolUseID: id, hasRecordedRows: hasRows, isSettled: isSettled,
                    liveID: { live ? SubagentID("task") : nil }
                )
                let offered = SubagentRunLink.canOpen(
                    toolUseID: id, hasRecordedRows: hasRows, isSettled: isSettled, isLive: { _ in live }
                )
                #expect(offered == (target != .unavailable), "live \(live), id \(String(describing: id))")
            }
        }
    }

    /// Asked last, so a row whose stored rows already answer never reads the roster, which moves
    /// once a second while a subagent runs.
    @Test("the roster is not read when the stored rows already answer")
    func rosterAskedLast() {
        var asked = false
        let offered = SubagentRunLink.canOpen(
            toolUseID: "toolu_1", hasRecordedRows: true, isSettled: true, isLive: { _ in
                asked = true
                return false
            }
        )
        #expect(offered)
        #expect(!asked)
    }

    @Test("the pane's header is read off the call that started the subagent")
    func recordedSubagentReadsTheCall() throws {
        let input = try JSONDecoder().decode(JSONValue.self, from: Data("""
        {"description":"Build shimmer","subagent_type":"general-purpose","prompt":"Do the thing"}
        """.utf8))
        let started = Date(timeIntervalSince1970: 1_000)
        let done = SubagentRunLink.recordedSubagent(
            toolUseID: "toolu_1", input: input, startedAt: started, isSettled: true, failed: false, durationMS: 95_400
        )
        #expect(done.toolUseID == "toolu_1")
        #expect(done.description == "Build shimmer")
        #expect(done.type == "general-purpose")
        #expect(done.prompt == "Do the thing")
        #expect(done.kind == .agent)
        #expect(done.state == .completed)
        #expect(done.secondsElapsed(at: started.addingTimeInterval(10_000)) == 95)

        let running = SubagentRunLink.recordedSubagent(
            toolUseID: "toolu_1", input: nil, startedAt: started, isSettled: false, failed: false, durationMS: nil
        )
        #expect(running.state == .running)
        #expect(SubagentPane.refreshes(running))

        let failed = SubagentRunLink.recordedSubagent(
            toolUseID: "toolu_1", input: nil, startedAt: started, isSettled: true, failed: true, durationMS: nil
        )
        #expect(failed.state == .failed)
    }

    @Test("only a call that starts a subagent is an Agent call")
    func agentCalls() {
        #expect(SubagentRunLink.isAgentCall(toolName: "Task"))
        #expect(SubagentRunLink.isAgentCall(toolName: "Agent"))
        #expect(!SubagentRunLink.isAgentCall(toolName: "Bash"))
    }

    @Test("the roster finds a subagent by the call that started it, until it forgets it")
    func rosterLookup() {
        var roster = SubagentRoster([
            Subagent(id: SubagentID("t1"), toolUseID: "toolu_1", state: .completed),
            Subagent(id: SubagentID("t2"), toolUseID: "toolu_2"),
        ])
        #expect(roster.subagent(forToolUseID: "toolu_1")?.id == SubagentID("t1"))
        #expect(roster.subagent(forToolUseID: "") == nil)
        roster.turnStarted()
        #expect(roster.subagent(forToolUseID: "toolu_1") == nil)
        #expect(roster.subagent(forToolUseID: "toolu_2")?.id == SubagentID("t2"))
    }

    /// Whether anything is stored to open is the fold's knowledge: a subagent that only spoke,
    /// with no action to count, still has a run.
    @Test("a run is known from any stored row, prose included")
    func hasRunFromProse() {
        let facts = [
            TranscriptFold.Fact(seq: 0, kind: .user),
            TranscriptFold.Fact(seq: 1, kind: .toolUse, settled: true, toolUseID: "a"),
            TranscriptFold.Fact(seq: 2, kind: .assistantText, parentToolUseID: "a"),
            TranscriptFold.Fact(seq: 3, kind: .toolUse, toolUseID: "b"),
        ]
        let folds = TranscriptFold.folds(in: facts)
        #expect(folds.hasRun(underCall: "a"))
        #expect(folds.actions(underCall: "a") == nil)
        #expect(!folds.hasRun(underCall: "b"))
        #expect(!folds.hasRun(underCall: nil))
    }
}
