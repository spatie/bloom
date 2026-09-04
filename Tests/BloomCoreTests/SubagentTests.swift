import Testing
import Foundation
@testable import BloomCore

// MARK: - Replaying the capture

/// `Tests/fixtures/claude-api-retry.ndjson` is a real 66 line stream-json capture from `claude`
/// 2.1.241 in which three subagents genuinely spawned, on a night the API was returning 529s.
/// Every assertion about what the CLI sends is made against it rather than against a shape
/// somebody remembered, which is the whole reason it was captured.
///
/// It arrived here twice, once under this name and once as `subagents-529.ndjson`, because the
/// same evening was captured for the retry surface and for these rows. Byte for byte the same
/// file: one copy, read by both suites, since two copies of a capture drift the moment somebody
/// adds a line to one of them. `AgentRetryTests` reads it for the turn's own retry.
@Suite struct SubagentCaptureTests {
    private func events() throws -> [AgentEvent] {
        try bloomFixtureLines("claude-api-retry.ndjson").compactMap(AgentEvent.decode(line:))
    }

    private func roster() throws -> SubagentRoster {
        var roster = SubagentRoster()
        for event in try events() {
            switch event {
            case .subagent(let signal): roster.apply(signal)
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
        #expect(retries.first?.maxAttempts == 10)
    }

    /// The join, end to end, on the real capture: a `tool_progress` carrying a `subagent_retry`
    /// has to reach the sidebar as a row in a retrying state, saying the outage in the words the
    /// transcript uses for the same 529 one level up.
    @Test func aRetryingSubagentIsARowThatSaysWhy() throws {
        var roster = SubagentRoster()
        for event in try events() {
            guard case .subagent(let signal) = event else { continue }
            roster.apply(signal)
            // Stop at the first retry, which is mid turn. The endings arrive later and a finished
            // row reads out what it answered rather than what went wrong on the way to it.
            if case .progressed(let progress) = signal, progress.retry != nil { break }
        }

        let row = try #require(SubagentRow.rows(roster).first {
            if case .retrying = $0.detail { true } else { false }
        })
        #expect(row.mark == .working)
        #expect(row.detail.text == "overloaded 1/10")
        #expect(row.spokenValue == "working, being retried, overloaded 1/10")
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

    @Test func theAgentExitingStopsWhateverWasStillRunning() {
        // The process that would have reported the ending is the one that just went away.
        var roster = SubagentRoster()
        roster.apply(.started(SubagentStart(id: SubagentID("a"))))
        roster.apply(.started(SubagentStart(id: SubagentID("b"))))
        roster.apply(.reported(SubagentReport(id: SubagentID("b"), status: "completed")))
        roster.agentExited()
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

// MARK: - Subagents that outlive the turn that spawned them

/// **"Seems like some subagents are not displayed."** A workspace drew three subagent rows while
/// its turn ran, and minutes later drew a spinner and no children at all while the transcript said
/// two of them were still going, six minutes in.
///
/// Nothing was wrong with the parsing. The `Agent` tool answers "Async agent launched
/// successfully. The agent is working in the background", so the turn's result line lands while
/// the subagent has minutes left; `SubagentRoster.turnEnded` then marked every running subagent
/// `stopped`, retention took the rows off two and a half seconds later, and the next turn's
/// `turnStarted` emptied the roster, so the `task_notification` that would have ended them had
/// nothing left to land on. `claude` runs for the whole session, which is why the ending was
/// always still coming and why nothing had the right to declare these subagents finished.
@Suite struct SubagentsOutlivingTheirTurnTests {
    private func spawned() -> SubagentRoster {
        var roster = SubagentRoster()
        roster.apply(.started(SubagentStart(
            id: SubagentID("live"), toolUseID: "toolu_live", description: "Prototype exploration",
            isBackgrounded: true, taskType: "local_agent"
        )))
        roster.apply(.started(SubagentStart(
            id: SubagentID("done"), toolUseID: "toolu_done", description: "Study conventions",
            taskType: "local_agent"
        )))
        roster.apply(.reported(SubagentReport(
            id: SubagentID("done"), status: "completed", summary: "Read it"
        )))
        return roster
    }

    @Test func aTurnEndingSaysNothingAboutASubagentStillWorking() {
        // The result line used to stop everything. `claude` is still there and so is the subagent.
        var roster = spawned()
        roster.turnStarted()
        #expect(roster[SubagentID("live")]?.state == .running)
        #expect(roster.isWorking)
    }

    @Test func theNextTurnKeepsARunningRowAndDropsAFinishedOne() {
        var roster = spawned()
        roster.turnStarted()
        #expect(roster.subagents.map(\.id) == [SubagentID("live")])

        let rows = SubagentRetention.rows(roster, now: Date())
        #expect(rows.map(\.title) == ["Prototype exploration"])
        #expect(rows.first?.mark == .working)
    }

    @Test func theEndingStillLandsAfterTheTurnBoundary() {
        // The whole point of keeping the row: the `task_notification` arrives in a later turn,
        // under the same `task_id`, and there has to be something for it to land on.
        var roster = spawned()
        roster.turnStarted()
        roster.apply(.reported(SubagentReport(
            id: SubagentID("live"), status: "completed", summary: "Explored", outputFile: "/tmp/a"
        )))
        #expect(roster[SubagentID("live")]?.state == .completed)
        #expect(roster[SubagentID("live")]?.outputFile == "/tmp/a")
        #expect(roster.refusals == 0)
    }

    @Test func theToolUseMapSurvivesForTheRowsThatDo() {
        // A tick names the subagent by its parent's `tool_use_id` and by nothing else, so a map
        // cleared with the turn would leave a kept row unable to count.
        var roster = spawned()
        roster.turnStarted()
        roster.apply(.progressed(SubagentProgress(parentToolUseID: "toolu_live", elapsedSeconds: 400)))
        #expect(roster[SubagentID("live")]?.elapsedSeconds == 400)

        // And the finished one's entry goes with it, or the next turn's ticks find a dead row.
        roster.apply(.progressed(SubagentProgress(parentToolUseID: "toolu_done", elapsedSeconds: 9)))
        #expect(roster[SubagentID("done")] == nil)
        #expect(roster.subagents.count == 1)
    }

    @Test func onlyTheAgentGoingAwayStopsOne() {
        var roster = spawned()
        roster.turnStarted()
        roster.agentExited()
        #expect(roster[SubagentID("live")]?.state == .stopped)
        #expect(!roster.isWorking)
    }

    @Test func aBackgroundAgentStillHasARowMinutesIntoALaterTurn() {
        // The owner's own reading: three rows counting up while the turn ran, and a spinner with
        // nothing under it once two more turns had been and gone.
        let start = Date(timeIntervalSince1970: 1_000_000)
        var roster = SubagentRoster()
        roster.apply(
            .started(SubagentStart(
                id: SubagentID("a"), toolUseID: "t", description: "there-there conventions sweep",
                isBackgrounded: true, taskType: "local_agent"
            )),
            now: start
        )
        // Two turns end and two more begin while it works.
        roster.turnStarted()
        roster.turnStarted()

        let sixMinutesIn = start.addingTimeInterval(6 * 60)
        let rows = SubagentRetention.rows(roster, now: sixMinutesIn)
        #expect(rows.count == 1)
        #expect(rows.first?.detail == .elapsed(seconds: 360))
        #expect(rows.first?.detail.text == "6m 0s")
    }
}

// MARK: - What a row says

@Suite struct SubagentRowTests {
    private func running(elapsed: Int, retry: AgentRetry? = nil) -> Subagent {
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

    /// The row carries the retry whole and says it in the retry surface's own words, which is
    /// what stops the sidebar and the transcript describing one 529 two ways.
    @Test func aRetryingRowSaysItInTheRetrySurfacesWords() {
        let retry = AgentRetry(attempt: 3, maxAttempts: 10, delay: 1.1, status: 529)
        let row = SubagentRow(running(elapsed: 4, retry: retry))
        #expect(row.detail == .retrying(retry))
        #expect(row.detail.text == "overloaded 3/10")
        // The same diagnosis the transcript spells out at length, from the same `RetryTrouble`.
        #expect(retry.headline == "Anthropic's API is overloaded")
        #expect(row.detail.text.count <= SubagentRow.detailLimit)
        #expect(row.spokenValue == "working, being retried, overloaded 3/10")
    }

    /// A retry the row draws while the count is still climbing has to keep changing, or three
    /// minutes of waiting look like three minutes of nothing.
    @Test func theReadoutMovesWithTheAttempts() {
        let readouts = (1...4).map { attempt in
            SubagentRow(running(
                elapsed: 4,
                retry: AgentRetry(attempt: attempt, maxAttempts: 10, delay: 1, status: 529)
            )).detail.text
        }
        #expect(Set(readouts).count == 4)
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

    /// An agent's row opens whatever state it is in, because there is always the prompt and there
    /// are always the nested rows Bloom stored, and because the file is named on the line that
    /// ENDS it: gating on the file made a running subagent unclickable, which is the one it is
    /// worth looking inside. A background command still needs the file, since its output lives
    /// nowhere else.
    @Test func anAgentOpensWhateverItIsDoingAndACommandNeedsItsFile() {
        #expect(SubagentRow(Subagent(id: SubagentID("a"))).opensOutput)
        #expect(SubagentRow(Subagent(id: SubagentID("a"), state: .failed)).opensOutput)

        let command = Subagent(id: SubagentID("b"), taskType: "local_bash")
        #expect(!SubagentRow(command).opensOutput)
        #expect(SubagentRow(
            Subagent(id: SubagentID("b"), taskType: "local_bash", outputFile: "/tmp/x")
        ).opensOutput)
    }

    /// The readout used to be the CLI's count alone, and a fan-out of seven arrived with no
    /// `tool_progress` at all: `duration(0)` is the empty string, so a working row said nothing
    /// and never moved. Bloom's own clock is the floor under it.
    @Test func aRunningRowCountsItsOwnSecondsWhenNoTickDoes() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let silent = Subagent(id: SubagentID("a"), startedAt: start)
        #expect(SubagentRow(silent, now: start.addingTimeInterval(42)).detail == .elapsed(seconds: 42))
        #expect(SubagentRow(silent, now: start.addingTimeInterval(42)).detail.text == "42s")

        // The CLI's number wins where it is further on: it counts the work, and this counts the row.
        let ticked = Subagent(id: SubagentID("a"), elapsedSeconds: 90, startedAt: start)
        #expect(SubagentRow(ticked, now: start.addingTimeInterval(5)).detail == .elapsed(seconds: 90))

        // And a finished one stops counting, whichever clock it was on.
        let done = Subagent(
            id: SubagentID("a"), state: .completed,
            finishedAt: start.addingTimeInterval(8), startedAt: start
        )
        #expect(done.secondsElapsed(at: start.addingTimeInterval(600)) == 8)
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
    /// The parent's session, which is the one these lines came off.
    private static let session = SessionID("s1")

    @Test func aFailedSubagentStillLeftAReadableFile() throws {
        let text = try bloomFixtureLines("subagent-output-529.jsonl").joined(separator: "\n")
        let transcript = SubagentTranscript.parse(text, sessionID: Self.session)
        // Four lines in, two of them `attachment` records carrying the whole deferred tool list.
        // The brief is the first, and it is not one of the rows: it is drawn above them.
        #expect(transcript.prompt.hasPrefix("Read the file a.txt"))
        #expect(transcript.messages.map(\.kind) == [.assistantText])
        let answer = try #require(transcript.messages.last)
        #expect(String(decoding: answer.payload, as: UTF8.self).contains("529 Overloaded"))
    }

    @Test func toolCallsAndResultsAreKept() {
        // Synthetic, because every subagent in the capture died before it could call a tool.
        let text = """
        {"type":"assistant","uuid":"u1","message":{"role":"assistant","content":[\
        {"type":"thinking","thinking":"weighing it"}]}}
        {"type":"assistant","uuid":"u2","message":{"role":"assistant","content":[\
        {"type":"tool_use","id":"toolu_1","name":"Read","input":{"file_path":"/a.txt"}}]}}
        {"type":"user","uuid":"u3","message":{"role":"user","content":[\
        {"type":"tool_result","tool_use_id":"toolu_1","content":[{"type":"text","text":"three lines"}]}]}}
        {"type":"assistant","uuid":"u4","message":{"role":"assistant","content":[{"type":"text","text":"3"}]}}
        """
        let transcript = SubagentTranscript.parse(text, sessionID: Self.session)
        #expect(transcript.messages.map(\.kind) == [.thinking, .toolUse, .toolResult, .assistantText])
        // The call and its result are filed under the same id, which is how the window folds the
        // one onto the other. See `TranscriptModel.rows(from:)`.
        #expect(transcript.messages[1].refID == "toolu_1")
        #expect(transcript.messages[2].refID == "toolu_1")
    }

    /// Every row has to decode to the event its bucket promises, because that is what the window
    /// dispatches on. A row filed as a tool call whose line decodes to something else draws
    /// nothing at all.
    @Test func everyRowDecodesToTheEventItsBucketPromises() throws {
        let text = """
        {"type":"assistant","uuid":"u1","message":{"role":"assistant","content":[{"type":"text","text":"ok"}]}}
        {"type":"assistant","uuid":"u2","message":{"role":"assistant","content":[\
        {"type":"tool_use","id":"toolu_1","name":"Bash","input":{"command":"ls"}}]}}
        {"type":"user","uuid":"u3","message":{"role":"user","content":[\
        {"type":"tool_result","tool_use_id":"toolu_1","content":"a.txt"}]}}
        """
        for message in SubagentTranscript.parse(text, sessionID: Self.session).messages {
            let event = try #require(
                AgentEvent.decode(line: String(decoding: message.payload, as: UTF8.self))
            )
            #expect(event.kind == message.kind)
        }
    }

    /// One line means one row throughout Bloom, and `AgentEvent` reads the first block of a
    /// message and no others, so a message carrying two has to become two lines first.
    @Test func aMessageCarryingSeveralBlocksBecomesSeveralRows() throws {
        let text = """
        {"type":"assistant","uuid":"u1","session_id":"s","message":{"role":"assistant","content":[\
        {"type":"text","text":"Reading it"},\
        {"type":"tool_use","id":"toolu_1","name":"Read","input":{"file_path":"/a.txt"}}]}}
        """
        let transcript = SubagentTranscript.parse(text, sessionID: Self.session)
        #expect(transcript.messages.map(\.kind) == [.assistantText, .toolUse])
        for message in transcript.messages {
            let json = try #require(JSONValue.parse(message.payload))
            // Every key outside `content` survives the split, because the renderers read them.
            #expect(json["uuid"]?.stringValue == "u1")
            #expect(json["session_id"]?.stringValue == "s")
            #expect(json["message"]?["content"]?.arrayValue?.count == 1)
        }
    }

    @Test func aLineThatWillNotParseIsSkippedRatherThanEndingTheRead() {
        // Bloom does not own this file, so a shape it does not know degrades to fewer rows.
        let transcript = SubagentTranscript.parse("""
        not json at all
        {"type":"summary","summary":"something new"}
        {"type":"attachment","attachment":{"type":"skill_listing","content":"a page of skills"}}
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"ok"}]}}
        """, sessionID: Self.session)
        #expect(transcript.messages.count == 1)
        #expect(transcript.messages[0].kind == .assistantText)
    }

    @Test func anEmptyFileIsEmptyRatherThanAFailure() {
        #expect(SubagentTranscript.parse("", sessionID: Self.session).isEmpty)
    }

    // MARK: Identity

    /// **A row that was never stored is numbered below every row that was.** The window caches how
    /// a tool call is drawn under the row's id alone, and a `messages` rowid is a positive
    /// `AUTOINCREMENT`, so a synthetic row numbered from zero would read the label of whichever
    /// real row shared its number.
    @Test func aRowThatWasNeverStoredIsNumberedBelowEveryRowThatWas() {
        let line = #"{"type":"assistant","uuid":"u1","message":{"content":[{"type":"text","text":"ok"}]}}"#
        let transcript = SubagentTranscript.parse(line, sessionID: Self.session)
        #expect(transcript.messages.allSatisfy { $0.id < 0 })
    }

    /// The same bytes get the same number every time, so a row stays itself across the re-read
    /// that happens once a second and across the handover from the live stream to the file. Row
    /// numbers taken from the position moved under both.
    @Test func aRowKeepsItsNumberAcrossAReRead() {
        let payload = Data(#"{"type":"assistant","uuid":"u1"}"#.utf8)
        #expect(SubagentTranscript.rowID(for: payload) == SubagentTranscript.rowID(for: payload))
        #expect(SubagentTranscript.rowID(for: payload) != SubagentTranscript.rowID(for: Data("x".utf8)))
    }

    /// Two identical lines are still two rows, and a list handed rows whose identifiers repeat
    /// lays them out in whatever order it pleases.
    @Test func twoIdenticalLinesStillGetTwoIdentities() {
        let line = #"{"type":"assistant","message":{"content":[{"type":"text","text":"same"}]}}"#
        let transcript = SubagentTranscript.parse(
            [line, line].joined(separator: "\n"), sessionID: Self.session
        )
        #expect(transcript.messages.count == 2)
        #expect(transcript.messages[0].id != transcript.messages[1].id)
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
