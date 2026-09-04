import Testing
import Foundation
@testable import BloomCore

/// **When a finished subagent's row goes.**
///
/// The rule has been three things. It removed the row on completion, which was replaced because
/// rows leaving one by one take everything below them up the pane. It then kept every finished row
/// until the next turn, which a real fan-out showed to be worse: eight rows under one workspace,
/// seven ticks and a cross, while the workspace was still running. This is the third answer and
/// the argument for each exemption is in `SubagentRetention`.
@Suite struct SubagentRetentionTests {
    private static let start = Date(timeIntervalSince1970: 1_700_000_000)

    private func subagent(
        _ id: String,
        state: SubagentState = .running,
        finishedAt: Date? = nil,
        summary: String = ""
    ) -> Subagent {
        Subagent(id: SubagentID(id), description: "Job \(id)", type: "Explore",
                 state: state, summary: summary, outputFile: "/x", finishedAt: finishedAt)
    }

    /// Seven ticks and one cross, which is the screenshot that prompted the change.
    private func fanOut(finishedAt: Date) -> SubagentRoster {
        var subagents = (1...7).map {
            subagent("\($0)", state: .completed, finishedAt: finishedAt, summary: "done")
        }
        subagents.append(subagent("8", state: .failed, finishedAt: finishedAt, summary: "529"))
        return SubagentRoster(subagents)
    }

    /// The same row, started as a backgrounded shell command rather than as an agent. `local_bash`
    /// is the one word the CLI uses for it, and `SubagentKind` matches it exactly.
    private func command(
        _ id: String,
        state: SubagentState = .running,
        finishedAt: Date? = nil,
        summary: String = ""
    ) -> Subagent {
        Subagent(id: SubagentID(id), description: "agent-browser open \"/settings\"",
                 taskType: "local_bash", state: state, summary: summary,
                 outputFile: "/x", finishedAt: finishedAt)
    }

    private func ids(_ rows: [SubagentRow]) -> [String] { rows.map(\.id.rawValue) }

    // MARK: Working rows are never touched

    @Test func aWorkingSubagentAlwaysHasARow() {
        let roster = SubagentRoster([subagent("1"), subagent("2")])
        let far = Self.start.addingTimeInterval(3_600)
        #expect(ids(SubagentRetention.rows(roster, now: far)) == ["1", "2"])
    }

    // MARK: A tick is held, then goes

    @Test func aTickIsHeldLongEnoughToBeSeen() {
        let roster = SubagentRoster([subagent("1", state: .completed, finishedAt: Self.start)])
        let midHold = Self.start.addingTimeInterval(SubagentRetention.lingerSeconds - 0.5)
        #expect(ids(SubagentRetention.rows(roster, now: midHold)) == ["1"])
    }

    @Test func aTickGoesWhenTheHoldRunsOut() {
        let roster = SubagentRoster([subagent("1", state: .completed, finishedAt: Self.start)])
        let after = Self.start.addingTimeInterval(SubagentRetention.lingerSeconds + 0.1)
        #expect(SubagentRetention.rows(roster, now: after).isEmpty)
    }

    /// A row that appears and vanishes inside two seconds is a flicker of its own, and the reflow
    /// that takes it away is itself 220 milliseconds. The hold has to be a decent multiple of it.
    @Test func theHoldIsWellClearOfTheReflowThatEndsIt() {
        #expect(SubagentRetention.lingerSeconds >= ProjectVisibilityMotion.seconds * 10)
    }

    /// The turn ending stops whatever was still running, and a stopped row is not a failure, so it
    /// leaves on the same clock as a tick.
    @Test func aStoppedRowLeavesLikeATick() {
        let roster = SubagentRoster([subagent("1", state: .stopped, finishedAt: Self.start)])
        let after = Self.start.addingTimeInterval(SubagentRetention.lingerSeconds + 0.1)
        #expect(SubagentRetention.rows(roster, now: after).isEmpty)
    }

    // MARK: A cross outlives a tick

    /// The judgement. "Done" was the instruction and a failure is also done, but a tick says what
    /// the workspace carrying on already says, and a cross is the only place a piece of a fan-out
    /// dying is visible at a glance.
    @Test func aCrossStaysWhenEveryTickHasGone() {
        let roster = fanOut(finishedAt: Self.start)
        let later = Self.start.addingTimeInterval(600)
        #expect(ids(SubagentRetention.rows(roster, now: later)) == ["8"])
    }

    /// Eight rows to one, which is the short list that was asked for, and the row that survives is
    /// the one worth surviving.
    @Test func theScreenshotThatPromptedThisGoesFromEightRowsToOne() {
        let roster = fanOut(finishedAt: Self.start)
        #expect(SubagentRetention.rows(roster, now: Self.start).count == 8)
        let later = Self.start.addingTimeInterval(SubagentRetention.lingerSeconds + 1)
        #expect(SubagentRetention.rows(roster, now: later).count == 1)
    }

    /// A cross has no clock at all, so nothing is scheduled to take it away. The backstop takes it.
    @Test func theNextTurnStillClearsEverything() {
        var roster = fanOut(finishedAt: Self.start)
        roster.turnStarted()
        let later = Self.start.addingTimeInterval(600)
        #expect(SubagentRetention.rows(roster, now: later).isEmpty)
        #expect(SubagentRetention.failureCount(roster) == 0)
    }

    // MARK: Failures do not become the log either

    /// A fan-out that half fails must not leave six rows behind. The first three in spawn order
    /// keep their crosses, which is the order the pane is read in.
    @Test func aFanOutThatHalfFailsDoesNotLeaveSixRowsBehind() {
        let roster = SubagentRoster((1...8).map {
            subagent("\($0)", state: $0 % 2 == 0 ? .failed : .completed, finishedAt: Self.start)
        })
        let later = Self.start.addingTimeInterval(600)
        let rows = SubagentRetention.rows(roster, now: later)
        #expect(rows.count == SubagentRetention.failureLimit)
        #expect(ids(rows) == ["2", "4", "6"])
        #expect(rows.allSatisfy { $0.mark == .failed })
    }

    /// The count is of every failure, not of the crosses drawn, which is what makes capping them
    /// safe: the workspace row and the three rows under it cannot disagree.
    @Test func theWorkspaceRowCountsEveryFailureIncludingTheCappedOnes() {
        let roster = SubagentRoster((1...8).map {
            subagent("\($0)", state: $0 % 2 == 0 ? .failed : .completed, finishedAt: Self.start)
        })
        #expect(SubagentRetention.failureCount(roster) == 4)
        let later = Self.start.addingTimeInterval(600)
        #expect(SubagentRetention.rows(roster, now: later).count < 4)
    }

    @Test func aTurnWithNoFailuresLeavesNothingOnTheWorkspaceRow() {
        var subagents = (1...7).map {
            subagent("\($0)", state: .completed, finishedAt: Self.start)
        }
        subagents.append(subagent("8"))
        #expect(SubagentRetention.failureCount(SubagentRoster(subagents)) == 0)
    }

    // MARK: The row you are reading

    /// A subagent's output can be the selected pane. Removing the row under a reader is the same
    /// yank as removing it under a glance, and worse, because they are looking at it.
    @Test func theRowWhoseOutputIsOpenIsNeverRemoved() {
        let roster = fanOut(finishedAt: Self.start)
        let later = Self.start.addingTimeInterval(600)
        let rows = SubagentRetention.rows(roster, now: later, opened: SubagentID("3"))
        #expect(ids(rows) == ["3", "8"])
    }

    /// Which means the only moment a subagent selection can be left pointing at nothing is the
    /// next turn clearing the roster, and that is where the fall back to the parent workspace is.
    @Test func closingThePaneLetsTheHeldRowGo() {
        let roster = fanOut(finishedAt: Self.start)
        let later = Self.start.addingTimeInterval(600)
        #expect(ids(SubagentRetention.rows(roster, now: later, opened: nil)) == ["8"])
    }

    /// Opening a failure past the cap keeps it, and it is the only thing that can put a fourth
    /// cross on the pane. That is the right way round: you asked for that one by clicking it, and
    /// a row that vanished the moment it was opened would be the yank the cap exists to avoid.
    @Test func openingAFailurePastTheCapKeepsItAndNothingElse() {
        let roster = SubagentRoster((1...6).map {
            subagent("\($0)", state: .failed, finishedAt: Self.start)
        })
        let later = Self.start.addingTimeInterval(600)
        let rows = SubagentRetention.rows(roster, now: later, opened: SubagentID("6"))
        #expect(ids(rows) == ["1", "2", "3", "6"])
    }

    // MARK: The clock nothing else winds

    /// A row leaving is the one change no line announces, so the pane has to be told when to look
    /// again. Without this a tick sits there until some other subagent ticks, or for ever if it
    /// was the last one working.
    @Test func theNextChangeIsWhenTheOldestHoldRunsOut() throws {
        let roster = SubagentRoster([
            subagent("1", state: .completed, finishedAt: Self.start),
            subagent("2", state: .completed, finishedAt: Self.start.addingTimeInterval(4)),
        ])
        let next = try #require(SubagentRetention.nextChange(roster, now: Self.start))
        #expect(next == Self.start.addingTimeInterval(SubagentRetention.lingerSeconds))
    }

    @Test func nothingIsScheduledWhenNothingIsOnAClock() {
        let failed = SubagentRoster([subagent("1", state: .failed, finishedAt: Self.start)])
        #expect(SubagentRetention.nextChange(failed, now: Self.start) == nil)
        #expect(SubagentRetention.nextChange(SubagentRoster(), now: Self.start) == nil)
    }

    /// The other change no line announces: a working row's readout counts seconds, and the ticks
    /// that were meant to move it do not always arrive. So a roster with anything running is
    /// always on a clock, at the second the readout is written in.
    @Test func aWorkingRowIsAskedForAgainASecondLater() {
        let running = SubagentRoster([subagent("1")])
        #expect(SubagentRetention.nextChange(running, now: Self.start) == Self.start.addingTimeInterval(1))

        // And it never delays a hold that runs out sooner.
        let mixed = SubagentRoster([
            subagent("1"),
            subagent("2", state: .completed, finishedAt: Self.start.addingTimeInterval(-2)),
        ])
        #expect(SubagentRetention.nextChange(mixed, now: Self.start)
            == Self.start.addingTimeInterval(SubagentRetention.lingerSeconds - 2))
    }

    @Test func anOpenedRowIsNotOnAClockEither() {
        let roster = SubagentRoster([subagent("1", state: .completed, finishedAt: Self.start)])
        #expect(SubagentRetention.nextChange(roster, now: Self.start, opened: SubagentID("1")) == nil)
    }

    // MARK: The clock comes off the stream, not off a view

    @Test func aSubagentIsTimedFromTheLineThatEndedIt() {
        var roster = SubagentRoster()
        roster.apply(.started(SubagentStart(id: SubagentID("1"), toolUseID: "t")), now: Self.start)
        #expect(roster[SubagentID("1")]?.finishedAt == nil)
        let ending = Self.start.addingTimeInterval(9)
        roster.apply(.reported(SubagentReport(id: SubagentID("1"), status: "completed")), now: ending)
        #expect(roster[SubagentID("1")]?.finishedAt == ending)
    }

    /// Two lines report one ending, and the second must not restart the hold: that would be a row
    /// that stayed twice as long as any other for no reason a reader could see.
    @Test func aSecondEndingLineDoesNotRestartTheHold() {
        var roster = SubagentRoster()
        roster.apply(.started(SubagentStart(id: SubagentID("1"), toolUseID: "t")), now: Self.start)
        let first = Self.start.addingTimeInterval(3)
        roster.apply(.patched(SubagentPatch(id: SubagentID("1"), status: "completed")), now: first)
        roster.apply(
            .reported(SubagentReport(id: SubagentID("1"), status: "completed", summary: "ok")),
            now: first.addingTimeInterval(2)
        )
        #expect(roster[SubagentID("1")]?.finishedAt == first)
    }

    @Test func theAgentExitingTimesWhateverItStopped() {
        var roster = SubagentRoster()
        roster.apply(.started(SubagentStart(id: SubagentID("1"), toolUseID: "t")), now: Self.start)
        let end = Self.start.addingTimeInterval(30)
        roster.agentExited(now: end)
        #expect(roster[SubagentID("1")]?.state == .stopped)
        #expect(roster[SubagentID("1")]?.finishedAt == end)
    }

    // MARK: The captured fan-out

    /// `Tests/fixtures/claude-api-retry.ndjson` end to end. Three subagents, all of which fail on
    /// the night the API was returning 529s, so every one of them keeps its row: the capture is
    /// the case where removing on completion removes nothing at all.
    @Test func theCapturedFanOutKeepsItsThreeCrosses() throws {
        var roster = SubagentRoster()
        var now = Self.start
        for event in try bloomFixtureLines("claude-api-retry.ndjson")
            .compactMap(AgentEvent.decode(line:)) {
            now = now.addingTimeInterval(0.1)
            switch event {
            case .subagent(let signal): roster.apply(signal, now: now)
            default: break
            }
        }
        #expect(roster.subagents.count == 3)
        #expect(SubagentRetention.failureCount(roster) == 3)
        let later = now.addingTimeInterval(600)
        #expect(SubagentRetention.rows(roster, now: later).count == 3)
    }

    // MARK: A shell command is not a subagent

    /// `system/task_started` is sent for a Task subagent and for a backgrounded shell command
    /// alike, and `task_type` is the only field between them. The pane had been drawing both, so
    /// three rows reading `agent-browser set viewport 1440 900 >/dev/null` stood under a
    /// workspace, two of them crossed. This pane is for the other AI working on the workspace.
    @Test func aBackgroundedShellCommandNeverHasARow() {
        let roster = SubagentRoster([
            command("1"),
            command("2", state: .failed, finishedAt: Self.start, summary: "exit 1"),
            command("3", state: .completed, finishedAt: Self.start, summary: "exit 0"),
        ])
        #expect(SubagentRetention.rows(roster, now: Self.start).isEmpty)
    }

    /// Including one somebody opened. The exemption that keeps an opened row is about a reader
    /// looking at a row this pane drew, and it never drew this one.
    @Test func evenAnOpenedCommandHasNoRow() {
        let roster = SubagentRoster([command("1", state: .failed, finishedAt: Self.start)])
        #expect(SubagentRetention.rows(roster, now: Self.start, opened: SubagentID("1")).isEmpty)
    }

    /// The agents beside it are untouched, which is the half that has to keep working.
    @Test func theAgentsBesideItKeepTheirRows() {
        let roster = SubagentRoster([subagent("1"), command("2"), subagent("3")])
        #expect(ids(SubagentRetention.rows(roster, now: Self.start)) == ["1", "3"])
    }

    /// A failed command must not put a number on the workspace row that nothing under it explains.
    @Test func aFailedCommandIsNotCountedOnTheWorkspaceRow() {
        let roster = SubagentRoster([
            command("1", state: .failed, finishedAt: Self.start),
            command("2", state: .failed, finishedAt: Self.start),
            subagent("3", state: .failed, finishedAt: Self.start),
        ])
        #expect(SubagentRetention.failureCount(roster) == 1)
    }

    /// Nothing is on a clock for a row that was never drawn, so no sweep is scheduled for one.
    @Test func aCommandPutsNothingOnTheClock() {
        let roster = SubagentRoster([
            command("1", state: .completed, finishedAt: Self.start, summary: "exit 0"),
        ])
        #expect(SubagentRetention.nextChange(roster, now: Self.start) == nil)
    }
}

@Suite struct SubagentRemovalMotionTests {
    /// The pane confirms everything in one length. A row leaving because a subagent finished is
    /// not a new register.
    @Test func aRowLeavingUsesThePanesOneLength() {
        #expect(ProjectVisibilityMotion.subagentRemoval(reduceMotion: false)
            == .reflow(seconds: ProjectVisibilityMotion.seconds))
    }

    @Test func reduceMotionDropsItRatherThanSlowingIt() {
        #expect(ProjectVisibilityMotion.subagentRemoval(reduceMotion: true) == .instant)
    }
}
