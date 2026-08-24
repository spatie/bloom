import Testing
import Foundation
@testable import BloomCore

// MARK: - Replaying the capture

/// `Tests/fixtures/subagents-529.ndjson` is a real 66 line stream-json capture from `claude`
/// 2.1.241 in which three subagents genuinely spawned, on a night the API was returning 529s.
/// Every assertion about what the CLI sends is made against it rather than against a shape
/// somebody remembered, which is the whole reason it was captured.
@Suite struct SubagentCaptureTests {
    private func events() throws -> [AgentEvent] {
        try bloomFixtureLines("subagents-529.ndjson").compactMap(AgentEvent.decode(line:))
    }

    private func roster() throws -> SubagentRoster {
        var roster = SubagentRoster()
        for event in try events() {
            switch event {
            case .subagent(let signal): roster.apply(signal)
            case .result: roster.turnEnded()
            default: break
            }
        }
        return roster
    }

    @Test func theCaptureSpawnsThreeSubagents() throws {
        let roster = try roster()
        #expect(roster.subagents.count == 3)
        // The result line's own `subagent_stats` says spawned 3, failed 3, and the roster built
        // from the lifecycle lines has to agree with it or one of the two is being misread.
        #expect(roster.subagents.allSatisfy { $0.state == .failed })
    }

    @Test func noLineIsRefused() throws {
        // A refusal here means the state machine and the CLI disagree about what can follow what.
        #expect(try roster().refusals == 0)
    }

    @Test func aStartCarriesEverythingNeededToDrawARow() throws {
        let roster = try roster()
        let first = try #require(roster.subagents.first)
        #expect(first.id == SubagentID("ae8b434e1a270eeac"))
        #expect(first.toolUseID == "toolu_01Y1GvQ1JsWzGJAeaR8HKdHZ")
        #expect(first.description == "Count lines in a.txt")
        #expect(first.type == "general-purpose")
        #expect(first.spawnDepth == 1)
        #expect(first.isBackgrounded == false)
        #expect(first.prompt.hasPrefix("Read the file a.txt"))
    }

    @Test func aNotificationCarriesTheOutputFile() throws {
        let roster = try roster()
        let first = try #require(roster.subagents.first)
        #expect(first.hasOutput)
        // Written even for a subagent that failed, which was the open question. See
        // `SubagentTranscript` for what the file turned out to hold.
        #expect(first.outputFile?.hasSuffix("/tasks/ae8b434e1a270eeac.output") == true)
        #expect(first.summary.contains("529 Overloaded"))
    }

    @Test func progressIsMatchedByTheParentToolUseID() throws {
        // `tool_progress` never carries `task_id`, so this is the one join in the feature that
        // could silently land the elapsed seconds on nothing at all.
        let progress = try events().compactMap { event -> SubagentProgress? in
            guard case .subagent(.progressed(let progress)) = event else { return nil }
            return progress
        }
        #expect(progress.count == 33)
        #expect(progress.allSatisfy { $0.type == "general-purpose" })
        let retries = progress.compactMap(\.retry)
        #expect(retries.count == 30)
        #expect(retries.allSatisfy { $0.status == 529 && $0.category == "overloaded" })
        #expect(retries.first?.maxRetries == 10)
    }

    @Test func nothingInTheCaptureBecomesATranscriptRow() throws {
        // Subagent lifecycle lines are live signals about the turn in flight, like `.status`.
        // If any of them started being stored, every turn would gain rows nobody asked for.
        let subagentEvents = try events().filter {
            if case .subagent = $0 { return true }
            return false
        }
        #expect(subagentEvents.count == 42)
        #expect(subagentEvents.allSatisfy { !$0.isTranscriptRow })
        #expect(subagentEvents.allSatisfy { $0.kind == .system })
    }

    @Test func theRowsSayWhatHappened() throws {
        let rows = SubagentRow.rows(try roster())
        #expect(rows.map(\.title) == [
            "Count lines in a.txt", "Count lines in a.txt", "Count lines in a.txt",
        ])
        #expect(rows.allSatisfy { $0.mark == .failed })
        #expect(rows.allSatisfy { $0.opensOutput })
        // Truncation only. The wording of the failure is quoted, not paraphrased.
        #expect(rows.allSatisfy { $0.detail.text == "Agent terminated early due..." })
    }
}

// MARK: - The state machine

@Suite struct SubagentLifecycleTests {
    @Test func aSpawnedSubagentStartsRunning() {
        var roster = SubagentRoster()
        roster.apply(.started(SubagentStart(id: SubagentID("a"), description: "Look")))
        #expect(roster[SubagentID("a")]?.state == .running)
        #expect(roster.isWorking)
    }

    @Test func aSecondStartForTheSameIDIsLegalAndChangesNothing() {
        var roster = SubagentRoster()
        roster.apply(.started(SubagentStart(id: SubagentID("a"), description: "Look")))
        roster.apply(.started(SubagentStart(id: SubagentID("a"), description: "Different")))
        #expect(roster.subagents.count == 1)
        #expect(roster[SubagentID("a")]?.description == "Look")
        #expect(roster.refusals == 0)
    }

    @Test func aFinishedSubagentIsNeverPutBackToWork() {
        // The pump is restarted when a session is resumed, so a replayed `task_started` was a
        // real possibility, and it would have put a breathing mark on a row that ended minutes
        // ago.
        var roster = SubagentRoster()
        roster.apply(.started(SubagentStart(id: SubagentID("a"))))
        roster.apply(.reported(SubagentReport(id: SubagentID("a"), status: "completed")))
        roster.apply(.started(SubagentStart(id: SubagentID("a"))))
        roster.apply(.patched(SubagentPatch(id: SubagentID("a"), status: "running")))
        #expect(roster[SubagentID("a")]?.state == .completed)
        #expect(roster.refusals == 2)
    }

    @Test func bothEndingLinesAgreeingIsNotAnError() {
        // `task_updated` then `task_notification`, both saying failed, is what happens every time.
        var roster = SubagentRoster()
        roster.apply(.started(SubagentStart(id: SubagentID("a"))))
        roster.apply(.patched(SubagentPatch(id: SubagentID("a"), status: "failed", error: "boom")))
        roster.apply(.reported(SubagentReport(id: SubagentID("a"), status: "failed")))
        #expect(roster[SubagentID("a")]?.state == .failed)
        #expect(roster.refusals == 0)
    }

    @Test func twoEndingsThatDisagreeKeepTheFirst() {
        var roster = SubagentRoster()
        roster.apply(.started(SubagentStart(id: SubagentID("a"))))
        roster.apply(.patched(SubagentPatch(id: SubagentID("a"), status: "failed")))
        roster.apply(.reported(SubagentReport(id: SubagentID("a"), status: "completed")))
        #expect(roster[SubagentID("a")]?.state == .failed)
        #expect(roster.refusals == 1)
    }

    @Test func aStatusWordNobodyKnowsIsRefusedRatherThanGuessed() {
        #expect(SubagentState(reported: "throttled") == nil)
        #expect(SubagentState.running.transition(on: .reported(status: "throttled")).isRefused)
        #expect(SubagentState(reported: "KILLED") == .stopped)
        #expect(SubagentState(reported: "in_progress") == .running)
    }

    @Test func aTurnEndingStopsWhateverWasStillRunning() {
        // The process that would have reported the ending is the one that just went away.
        var roster = SubagentRoster()
        roster.apply(.started(SubagentStart(id: SubagentID("a"))))
        roster.apply(.started(SubagentStart(id: SubagentID("b"))))
        roster.apply(.reported(SubagentReport(id: SubagentID("b"), status: "completed")))
        roster.turnEnded()
        #expect(roster[SubagentID("a")]?.state == .stopped)
        #expect(roster[SubagentID("b")]?.state == .completed)
        #expect(!roster.isWorking)
        #expect(roster.refusals == 0)
    }
}

// MARK: - The clearing rule

@Suite struct SubagentClearingTests {
    private var finishedTurn: SubagentRoster {
        var roster = SubagentRoster()
        roster.apply(.started(SubagentStart(id: SubagentID("a"), description: "One")))
        roster.apply(.reported(SubagentReport(id: SubagentID("a"), status: "completed")))
        roster.turnEnded()
        return roster
    }

    @Test func aFinishedSubagentKeepsItsPlaceUntilTheNextTurn() {
        // This is the whole of option 2: not removed when it finishes, which is the version that
        // takes everything below it up the pane while you are reading it.
        var roster = finishedTurn
        #expect(roster.subagents.count == 1)
        #expect(SubagentRow.rows(roster).first?.mark == .done)

        roster.turnStarted()
        #expect(roster.isEmpty)
    }

    @Test func clearingForgetsTheToolUseMapToo() {
        // A stale map would let the next turn's `tool_progress` tick a row from the last one.
        var roster = finishedTurn
        roster.turnStarted()
        roster.apply(.progressed(SubagentProgress(parentToolUseID: "", elapsedSeconds: 9)))
        #expect(roster.isEmpty)
    }
}

// MARK: - What a row says

@Suite struct SubagentRowTests {
    private func running(elapsed: Int, retry: SubagentRetry? = nil) -> Subagent {
        Subagent(
            id: SubagentID("a"), description: "Find Store.upsert call sites", type: "Explore",
            state: .running, elapsedSeconds: elapsed, retry: retry
        )
    }

    @Test func aRunningRowCountsSeconds() {
        #expect(SubagentRow(running(elapsed: 11)).detail == .elapsed(seconds: 11))
        #expect(SubagentRow(running(elapsed: 11)).detail.text == "11s")
        #expect(SubagentRow(running(elapsed: 72)).detail.text == "1m 12s")
        #expect(SubagentRow(running(elapsed: 0)).detail.text == "")
    }

    @Test func aRetryingRowCarriesTheFactsAndLeavesTheWordsToTheRetryWork() {
        let retry = SubagentRetry(attempt: 3, maxRetries: 10, status: 529, category: "overloaded")
        let row = SubagentRow(running(elapsed: 4, retry: retry))
        #expect(row.detail == .retrying(retry))
        #expect(row.spokenValue.hasPrefix("working, being retried"))
    }

    @Test func aFinishedRowCarriesWhatItAnswered() {
        let row = SubagentRow(Subagent(
            id: SubagentID("a"), description: "Count lines", state: .completed, summary: "3 lines"
        ))
        #expect(row.mark == .done)
        #expect(row.detail == .summary("3 lines"))
        #expect(row.spokenValue == "finished, 3 lines")
    }

    @Test func aStoppedRowIsNotACross() {
        let row = SubagentRow(Subagent(id: SubagentID("a"), state: .stopped))
        #expect(row.mark == .stopped)
        #expect(row.spokenValue == "stopped")
    }

    @Test func aRowWithNoFileToOpenRefusesTheClick() {
        #expect(!SubagentRow(Subagent(id: SubagentID("a"), state: .failed)).opensOutput)
        #expect(SubagentRow(Subagent(id: SubagentID("a"), outputFile: "/tmp/x")).opensOutput)
    }

    @Test func aRowWithNoDescriptionFallsBackToItsType() {
        #expect(SubagentRow(Subagent(id: SubagentID("a"), type: "Explore")).title == "Explore")
        #expect(SubagentRow(Subagent(id: SubagentID("a"))).title == "Subagent")
    }

    @Test func aSummaryIsCutOnAWordAndOnlyEverCut() {
        #expect(SubagentRow.shorten("3 lines") == "3 lines")
        #expect(SubagentRow.shorten("first\nsecond") == "first")
        #expect(SubagentRow.shorten(String(repeating: "x", count: 40)).hasSuffix("..."))
        #expect(SubagentRow.shorten("the quick brown fox jumps over it") == "the quick brown fox jumps...")
    }

    @Test func depthGreaterThanOneIsDrawnFlatAndInSpawnOrder() {
        // A fourth outline level in a 260 point pane leaves a name six characters wide, so the
        // depth is carried on the model and deliberately not turned into an indent. The order is
        // what preserves the reading.
        let roster = SubagentRoster([
            Subagent(id: SubagentID("a"), description: "Parent", spawnDepth: 1),
            Subagent(id: SubagentID("b"), description: "Child", spawnDepth: 2),
            Subagent(id: SubagentID("c"), description: "Grandchild", spawnDepth: 3),
        ])
        #expect(SubagentRow.rows(roster).map(\.title) == ["Parent", "Child", "Grandchild"])
    }
}

// MARK: - Reading a subagent's own transcript

@Suite struct SubagentTranscriptTests {
    @Test func aFailedSubagentStillLeftAReadableFile() throws {
        let text = try bloomFixtureLines("subagent-output-529.jsonl").joined(separator: "\n")
        let transcript = SubagentTranscript.parse(text)
        // Four lines in, two of them `attachment` records carrying the whole deferred tool list.
        #expect(transcript.entries.count == 2)
        #expect(transcript.entries.first?.kind == .prompt)
        #expect(transcript.entries.first?.body.hasPrefix("Read the file a.txt") == true)
        let answer = try #require(transcript.answer)
        #expect(answer.kind == .failure)
        #expect(answer.body.contains("529 Overloaded"))
    }

    @Test func toolCallsAndResultsAreKept() {
        // Synthetic, because every subagent in the capture died before it could call a tool.
        let text = """
        {"type":"assistant","message":{"role":"assistant","content":[\
        {"type":"thinking","thinking":"weighing it"},\
        {"type":"tool_use","name":"Read","input":{"file_path":"/a.txt"}}]}}
        {"type":"user","message":{"role":"user","content":[\
        {"type":"tool_result","content":[{"type":"text","text":"three lines"}]}]}}
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"3"}]}}
        """
        let transcript = SubagentTranscript.parse(text)
        #expect(transcript.entries.map(\.kind) == [.thinking, .tool, .toolResult, .text])
        #expect(transcript.entries[1].title == "Read")
        #expect(transcript.entries[1].body.contains("/a.txt"))
        #expect(transcript.entries[2].body == "three lines")
        #expect(transcript.answer?.body == "3")
    }

    @Test func aLineThatWillNotParseIsSkippedRatherThanEndingTheRead() {
        // Bloom does not own this file, so a shape it does not know degrades to fewer entries.
        let transcript = SubagentTranscript.parse("""
        not json at all
        {"type":"summary","summary":"something new"}
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"ok"}]}}
        """)
        #expect(transcript.entries.map(\.body) == ["ok"])
    }

    @Test func anEmptyFileIsEmptyRatherThanAFailure() {
        #expect(SubagentTranscript.parse("").isEmpty)
    }
}

// MARK: - The pane the rows are drawn into

/// Subagent rows appear BETWEEN workspace rows, which is the one place they can break something
/// that already worked: `onMove` hands back offsets into the drawn run, and every offset below a
/// running workspace moves by the number of children it is drawing.
@Suite struct SubagentReorderTests {
    private let project = RepoID("p")

    /// Two workspaces, the first of them running two subagents.
    private var rows: [SidebarReorder.Row] {
        [
            .project(project),
            .workspace(id: WorkspaceID("a"), projectID: project),
            .subagent(projectID: project),
            .subagent(projectID: project),
            .workspace(id: WorkspaceID("b"), projectID: project),
        ]
    }

    @Test func aSubagentRowIsNeverSomethingToPickUp() {
        let moved = SidebarReorder.destination(rows: rows, from: IndexSet(integer: 2), to: 1)
        #expect(moved == .nothing)
    }

    @Test func draggingTheSecondWorkspaceAboveTheFirstCountsWorkspacesAndNotRows() {
        // The offsets are 4 and 1 in the drawn run, and 1 and 0 among the project's workspaces.
        // Subtracting the run's lower bound instead of ranking would have said 3 and 0, which
        // `move(visible:all:from:to:)` reads as an offset off the end of a two row project.
        let moved = SidebarReorder.destination(rows: rows, from: IndexSet(integer: 4), to: 1)
        #expect(moved == .workspace(
            projectID: project, from: IndexSet(integer: 1), to: 0, landedOutside: false
        ))
    }

    @Test func aDropBelowTheLastWorkspacesChildrenIsInsideTheProject() {
        // The insertion line under the last subagent row is the end of the project, not outside
        // it, so this must not report `landedOutside` and raise the "Kept in" note.
        let rows: [SidebarReorder.Row] = [
            .project(project),
            .workspace(id: WorkspaceID("a"), projectID: project),
            .workspace(id: WorkspaceID("b"), projectID: project),
            .subagent(projectID: project),
        ]
        let moved = SidebarReorder.destination(rows: rows, from: IndexSet(integer: 1), to: 4)
        #expect(moved == .workspace(
            projectID: project, from: IndexSet(integer: 0), to: 2, landedOutside: false
        ))
    }

    @Test func aPaneWithNoSubagentsBehavesExactlyAsItDid() {
        let rows: [SidebarReorder.Row] = [
            .project(project),
            .workspace(id: WorkspaceID("a"), projectID: project),
            .workspace(id: WorkspaceID("b"), projectID: project),
        ]
        #expect(SidebarReorder.destination(rows: rows, from: IndexSet(integer: 2), to: 1)
            == .workspace(projectID: project, from: IndexSet(integer: 1), to: 0, landedOutside: false))
    }
}
