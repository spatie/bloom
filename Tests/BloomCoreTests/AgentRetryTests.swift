import Foundation
import Testing
@testable import BloomCore

/// The retry surface, replayed off the stream that caused it.
///
/// `Tests/fixtures/claude-api-retry.ndjson` is a real 66 line capture from `claude` 2.1.241 taken
/// during an evening of 529s: one `api_retry`, a `rate_limit_event`, thirty `tool_progress` lines
/// carrying `subagent_retry` for three different subagents, and a `result` that succeeded while
/// every one of those subagents failed. Everything here is asserted against that file rather than
/// against a payload written to match the code, which is the whole reason the capture was kept:
/// the outage is not repeatable and nobody should have to pay for another one to change a word.
///
/// **The wording is tested because the wording is the feature.** What Bloom says about a 529 is
/// the only part of this a person ever sees, and a sentence nothing asserts is a sentence the next
/// change quietly breaks.
@Suite struct AgentRetryTests {
    private static func fixture(_ name: String) throws -> [AgentEvent] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("fixtures/\(name)")
        let text = try String(contentsOf: url, encoding: .utf8)
        return text.split(separator: "\n").compactMap { AgentEvent.decode(line: String($0)) }
    }

    private static func retries(in events: [AgentEvent]) -> [AgentRetry] {
        events.compactMap { if case .retrying(let retry) = $0 { retry } else { nil } }
    }

    /// A subagent's retries do not arrive as `.retrying`, and the route is the one thing about
    /// them that changed when the subagent rows landed.
    ///
    /// The block rides on a `tool_progress` line that also carries the subagent's elapsed seconds
    /// and its type, one line decodes to one event, and a retrying subagent is a subagent first:
    /// so that line is a `.subagent` and the retry is read off it. Same `AgentRetry`, parsed by
    /// the same `AgentRetry.subagentRetry`, said in the same words. Every assertion below is the
    /// one that was made when they came through `.retrying`.
    private static func subagentRetries(in events: [AgentEvent]) -> [AgentRetry] {
        events.compactMap {
            guard case .subagent(.progressed(let progress)) = $0 else { return nil }
            return progress.retry
        }
    }

    // MARK: The capture

    @Test func liftsEveryRetryOutOfTheRealStream() throws {
        let events = try Self.fixture("claude-api-retry.ndjson")
        let turn = Self.retries(in: events)
        let subagents = Self.subagentRetries(in: events)

        // One for the turn, ten each for three subagents. Thirty one announcements about one
        // outage on two levels, whichever event carries them.
        #expect(turn.count == 1)
        #expect(turn.allSatisfy { $0.scope == .turn })
        #expect(subagents.count == 30)
        #expect(Set(subagents.compactMap(\.scope.agentID)).count == 3)
        // Every one of them was the same outage.
        let all = turn + subagents
        #expect(all.count == 31)
        #expect(all.allSatisfy { $0.status == 529 })
        #expect(all.allSatisfy { $0.trouble == .overloaded })
    }

    @Test func readsTheTurnsOwnRetry() throws {
        let retry = try #require(Self.retries(in: try Self.fixture("claude-api-retry.ndjson"))
            .first { $0.scope == .turn })

        #expect(retry.attempt == 1)
        #expect(retry.maxAttempts == 10)
        #expect(retry.delay == 0.6)
        #expect(retry.status == 529)
        #expect(retry.category == "overloaded")
        #expect(retry.sessionID == "1f33862f-0d88-435e-b840-1340d98ee766")
    }

    /// The subagent block spells three of its six fields differently and hides one level down, so
    /// it gets its own assertion rather than riding on the turn's.
    @Test func readsASubagentsRetry() throws {
        let retry = try #require(
            Self.subagentRetries(in: try Self.fixture("claude-api-retry.ndjson"))
                .first { $0.scope.agentID == "ae8b434e1a270eeac" })

        #expect(retry.attempt == 1)
        #expect(retry.maxAttempts == 10)
        #expect(retry.delay == 0.576)
        #expect(retry.category == "overloaded")
        if case .subagent(_, let toolUseID, let kind) = retry.scope {
            // The Agent call, not the inner message id. A `task_notification` reports this same
            // subagent's failure under exactly this id, which is what makes the two joinable.
            #expect(toolUseID == "toolu_01Y1GvQ1JsWzGJAeaR8HKdHZ")
            #expect(kind == "general-purpose")
        } else {
            Issue.record("expected a subagent scope")
        }
    }

    /// The backoff really does grow, which is the fact the escalating wording rests on.
    @Test func theWaitsGetLonger() throws {
        let one = Self.subagentRetries(in: try Self.fixture("claude-api-retry.ndjson"))
            .filter { $0.scope.agentID == "ae8b434e1a270eeac" }
            .sorted { $0.attempt < $1.attempt }

        #expect(one.map(\.attempt) == Array(1...10))
        #expect(one[0].delay < 1)
        #expect(one[8].delay > 30)
    }

    /// A `tool_progress` line with no retry block is not a retry, and must not become one.
    @Test func plainProgressIsNotARetry() throws {
        let tick =
            #"{"type":"tool_progress","parent_tool_use_id":"toolu_1","elapsed_time_seconds":4}"#
        guard case .subagent(.progressed(let progress)) = try #require(
            AgentEvent.decode(line: tick))
        else {
            Issue.record("a progress tick is a line about a subagent")
            return
        }
        // The tick saying a subagent is four seconds in says nothing about trouble, and inventing
        // an attempt zero for it would put every working row into a retrying state.
        #expect(progress.retry == nil)

        // A tick naming no subagent at all is a line this decoder has no reading of, and keeps
        // its bytes rather than being half understood.
        let orphan = #"{"type":"tool_progress","tool_use_id":"t1","elapsed_time_seconds":4}"#
        guard case .unknown = try #require(AgentEvent.decode(line: orphan)) else {
            Issue.record("a tick naming no subagent belongs in .unknown")
            return
        }
    }

    /// Ten attempts are not ten rows. A stored transcript is history, and nine tenths of a retry
    /// run is stale the moment the next attempt starts.
    @Test func retriesAreNotStoredRows() throws {
        let events = try Self.fixture("claude-api-retry.ndjson")
        let retrying = events.filter {
            if case .retrying = $0 { return true } else { return false }
        }
        #expect(!retrying.isEmpty)
        #expect(retrying.allSatisfy { !$0.isTranscriptRow })
        // Nor are the thirty a subagent announced, by exactly the same argument. They travel as
        // `.subagent` now, and a line that was not a row must not become one by changing route.
        let ticks = events.filter {
            if case .subagent(.progressed) = $0 { return true } else { return false }
        }
        #expect(ticks.count == 33)
        #expect(ticks.allSatisfy { !$0.isTranscriptRow })
    }

    // MARK: What it says

    @Test func the529SaysWhoseFaultItIsNot() {
        let retry = AgentRetry(attempt: 1, maxAttempts: 10, delay: 0.6, status: 529)

        #expect(retry.headline == "Anthropic's API is overloaded")
        #expect(retry.note == "Trying again by itself, with nothing for you to do. It is "
            + "capacity at their end, not anything here.")
        // The attempt count is a figure the row draws on its own, so the sentence does not open
        // with it. A surface with no counter asks for both.
        #expect(retry.summary == "Attempt 1 of 10. " + retry.note)
        // Under five seconds nothing is said about the wait: the sentence would be replaced
        // before it had been read.
        #expect(retry.waitPhrase == nil)
    }

    @Test func attemptNineSaysTheTurnIsAboutToStop() {
        let retry = AgentRetry(attempt: 9, maxAttempts: 10, delay: 37.186, status: 529)

        #expect(retry.headline == "Anthropic's API is overloaded")
        #expect(retry.note == "Nearly out of attempts. If the last one fails the turn stops here "
            + "and you can send it again. It is capacity at their end, not anything here.")
        #expect(retry.waitPhrase == "Next attempt in about 40 seconds.")
    }

    /// The three bands read differently, which is the whole point of having three.
    @Test func theWordingEscalates() {
        let words = [1, 5, 9].map {
            AgentRetry(attempt: $0, maxAttempts: 10, delay: 1, status: 529).note
        }
        #expect(Set(words).count == 3)
        #expect(words[0].contains("nothing for you to do"))
        #expect(words[1].contains("longer waits"))
        #expect(words[2].contains("Nearly out of attempts"))
    }

    @Test func aRateLimitPointsAtTheOnePlaceThatKnows() {
        let retry = AgentRetry(attempt: 2, maxAttempts: 10, delay: 2, status: 429)

        #expect(retry.headline == "Anthropic's API is rate limiting this account")
        #expect(retry.note.contains("What is left of it is in the menu bar."))
    }

    /// A 5xx that is not 529 still gets a sentence saying it is theirs, and names the code, since
    /// there is nothing more useful to say about one Bloom has not met.
    @Test func anyOtherServerFaultIsStillTheirs() {
        let retry = AgentRetry(attempt: 1, maxAttempts: 10, delay: 1, status: 503)

        #expect(retry.headline == "Anthropic's API is failing")
        #expect(retry.note.contains("It is a fault at their end (503), not anything here."))
        #expect(!retry.trouble.isWorthActingOn)
    }

    /// The two cases where the reader might actually have something to do are the two where the
    /// sentence stops promising there is nothing.
    @Test func onlySomeTroubleIsWorthActingOn() {
        #expect(!RetryTrouble.overloaded.isWorthActingOn)
        #expect(!RetryTrouble.rateLimited.isWorthActingOn)
        #expect(!RetryTrouble.serverFault(500).isWorthActingOn)
        #expect(RetryTrouble.refused(400).isWorthActingOn)
        #expect(RetryTrouble.unreachable.isWorthActingOn)

        let unreachable = AgentRetry(attempt: 1, maxAttempts: 10, delay: 1, status: nil)
        #expect(unreachable.headline == "Bloom cannot reach Anthropic's API")
        #expect(unreachable.note.contains("Worth a glance at your connection."))
        // The reassurance is dropped here, because it would not be true.
        #expect(!unreachable.note.contains("nothing for you to do"))
    }

    @Test func aStatusAlwaysBeatsTheClisOwnWord() {
        // The CLI calls a 429 "overloaded" nowhere, but if it ever did, the number is the fact.
        #expect(RetryTrouble.diagnose(status: 429, category: "overloaded") == .rateLimited)
        // With no status the word is all there is.
        #expect(RetryTrouble.diagnose(status: nil, category: "overloaded") == .overloaded)
        #expect(RetryTrouble.diagnose(status: nil, category: "who knows") == .unreachable)
    }

    // MARK: Patience

    @Test func theBandsSplitTenAttemptsThreeWays() {
        let bands = (1...10).map { RetryPatience.of(attempt: $0, maxAttempts: 10) }
        #expect(bands == [.settling, .settling, .settling, .persisting, .persisting,
                          .persisting, .persisting, .persisting, .lastChances, .lastChances])
    }

    /// Stated in fractions, so a CLI shipping a different ceiling tomorrow still reads correctly.
    @Test func theBandsFollowTheCeilingRatherThanALiteral() {
        #expect(RetryPatience.of(attempt: 2, maxAttempts: 3) == .lastChances)
        #expect(RetryPatience.of(attempt: 1, maxAttempts: 30) == .settling)
        #expect(RetryPatience.of(attempt: 29, maxAttempts: 30) == .lastChances)
        // No stated ceiling: there is no last chance to warn about, and nothing to call settled.
        #expect(RetryPatience.of(attempt: 1, maxAttempts: 0) == .persisting)
    }

    /// The first third of a run must not spend anybody's attention outside the transcript.
    @Test func onlyALongRunIsWorthSayingElsewhere() {
        #expect(!RetryPatience.settling.deservesNoticeElsewhere)
        #expect(RetryPatience.persisting.deservesNoticeElsewhere)
        #expect(RetryPatience.lastChances.deservesNoticeElsewhere)
    }

    // MARK: The wait, in words

    @Test func theWaitIsRoundedUntilItStopsPretending() {
        #expect(AgentRetry.coarse(6) == "5 seconds")
        #expect(AgentRetry.coarse(8.757) == "10 seconds")
        #expect(AgentRetry.coarse(16.23) == "15 seconds")
        #expect(AgentRetry.coarse(37.475) == "40 seconds")
        #expect(AgentRetry.coarse(95) == "2 minutes")
        #expect(AgentRetry.coarse(60) == "60 seconds")
    }

    // MARK: A run, and what it leaves behind

    @Test func aRunFoldsItsAttemptsIntoOneFact() throws {
        let ten = Self.subagentRetries(in: try Self.fixture("claude-api-retry.ndjson"))
            .filter { $0.scope.agentID == "ae2e718c9c4fc1a7d" }
            .sorted { $0.attempt < $1.attempt }

        var run = RetryRun(ten[0])
        for retry in ten.dropFirst() { run.absorb(retry) }

        #expect(run.attempts == 10)
        #expect(run.patience == .lastChances)
        #expect(run.trouble == .overloaded)
    }

    /// The count survives a CLI that starts a fresh request inside the same turn and restarts its
    /// own numbering. The record keeps the worst the run reached.
    @Test func aRunKeepsTheWorstItSaw() {
        var run = RetryRun(AgentRetry(attempt: 7, maxAttempts: 10, delay: 1, status: 529))
        run.absorb(AgentRetry(attempt: 1, maxAttempts: 10, delay: 1, status: 529))
        #expect(run.attempts == 7)
    }

    /// What is left under a turn that waited and then got through. Past tense, no advice, and no
    /// count of anything the reader cannot act on.
    @Test func aRecoveredRunLeavesOneQuietSentence() {
        var run = RetryRun(AgentRetry(attempt: 1, maxAttempts: 10, delay: 1, status: 529))
        run.absorb(AgentRetry(attempt: 4, maxAttempts: 10, delay: 5, status: 529))

        #expect(run.recoveredSentence
            == "Anthropic's API was overloaded. This turn got through on attempt 4 of 10.")
    }
}

/// The `rate_limit_event` that rides along in the same capture, and the figure Bloom used to
/// invent from it.
@Suite struct RateLimitNoticeTests {
    /// The real line, from `Tests/fixtures/claude-api-retry.ndjson`. It has a window and a reset
    /// time and no `utilization` at all, which is the ordinary case: the CLI only sends a figure
    /// once the account is near its wall.
    private static let quiet = Data("""
        {"type":"rate_limit_event","rate_limit_info":{"status":"allowed","resetsAt":1787566800,\
        "rateLimitType":"five_hour","overageStatus":"rejected",\
        "overageDisabledReason":"org_level_disabled","isUsingOverage":false}}
        """.utf8)

    /// The transcript used to print "0% of the five hour window used" for this. Nothing said 0.
    @Test func anEventWithNoFigureDrawsNoRow() {
        #expect(RateLimitNotice.sentence(forRateLimitEvent: Self.quiet) == nil)
    }

    @Test func anEventWithAFigureSaysIt() {
        let near = Data("""
            {"type":"rate_limit_event","rate_limit_info":{"status":"allowed",\
            "resetsAt":1787566800,"rateLimitType":"seven_day","utilization":0.77,\
            "surpassedThreshold":0.75}}
            """.utf8)
        #expect(RateLimitNotice.sentence(forRateLimitEvent: near) == "77% of the week allowance used")
    }

    @Test func rubbishDrawsNothing() {
        #expect(RateLimitNotice.sentence(forRateLimitEvent: Data("not json".utf8)) == nil)
    }
}

/// The result that says `success` while `is_error` is true, which the second capture shows really
/// happens. See `TurnFailure`.
@Suite struct TurnFailureTests {
    private static func result() throws -> AgentResult {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("fixtures/claude-turn-died-mid-response.ndjson")
        let text = try String(contentsOf: url, encoding: .utf8)
        let events = text.split(separator: "\n").compactMap { AgentEvent.decode(line: String($0)) }
        for case .result(let value) in events { return value }
        throw CocoaError(.fileReadUnknown)
    }

    /// The shape of the thing: a success subtype on a turn that failed. Reading `subtype` alone,
    /// which is the obvious way, calls this turn finished.
    @Test func aSuccessSubtypeCanCarryAFailure() throws {
        let result = try Self.result()

        #expect(result.subtype == "success")
        #expect(result.isError)
        #expect(!result.succeeded)
        #expect(result.terminalReason == "api_error")
    }

    @Test func theFailureIsExplainedInBloomsWordsAndThenInTheClis() throws {
        let failure = try #require(TurnFailure.of(try Self.result()))

        #expect(failure.lead == "The turn stopped part way through, at the API's end rather than "
            + "yours. Whatever the agent had already changed is still in the worktree, and you "
            + "can ask again whenever you like.")
        // Kept whole and unedited. It is somebody else's message.
        #expect(failure.clisOwnWords
            == "API Error: Connection lost mid-response. The response above may be incomplete.")
    }

    /// An ending Bloom has no reading of does not get a sentence pretending otherwise.
    @Test func anUnknownEndingLeavesTheCliToSpeak() {
        let result = AgentResult(
            summary: "Something nobody has seen before.", isError: true, subtype: "success",
            terminalReason: "reason_from_the_future"
        )
        let failure = TurnFailure.of(result)
        #expect(failure?.lead == nil)
        #expect(failure?.clisOwnWords == "Something nobody has seen before.")
    }

    @Test func aTurnThatWorkedHasNothingToSay() {
        #expect(TurnFailure.of(AgentResult(summary: "done", subtype: "success")) == nil)
    }
}
