import Testing
import Foundation
@testable import BloomCore

/// The turn that stopped dead, written down.
///
/// The shape every case here is measured against came out of the owner's own database on 26
/// August 2026: four transcripts ending on a `content_block_start` with no result, no error and no
/// footer, and `ps` proving the processes behind them had exited. The rule that let that happen
/// was "only say something when the exit status is non-zero", so the first two tests are the two
/// halves of replacing it.
@Suite("UnfinishedRun")
struct UnfinishedRunTests {
    @Test("a clean exit in the middle of a turn is still worth a row")
    func cleanExitMidTurn() throws {
        let run = UnfinishedRun.of(
            status: 0, sawResult: false, state: .running, stderr: "", command: "/usr/bin/claude"
        )

        let unfinished = try #require(run)
        #expect(unfinished.leftATurnOpen)
        #expect(unfinished.wasSilent)
        #expect(unfinished.message == UnfinishedRun.silentSentence)
    }

    @Test("a clean exit with no turn open says nothing")
    func cleanExitBetweenTurns() {
        for state in [SessionState.idle, .failed, .cancelled] {
            #expect(UnfinishedRun.of(
                status: 0, sawResult: true, state: state, stderr: "", command: ""
            ) == nil)
        }
    }

    /// The rule this type grew from, kept: a CLI that falls over between turns is news even though
    /// no turn is hanging on it.
    @Test("a non-zero exit with nothing reported is still a row between turns")
    func failsBetweenTurns() throws {
        let run = UnfinishedRun.of(
            status: 2, sawResult: false, state: .idle, stderr: "error: not logged in", command: "c"
        )

        let unfinished = try #require(run)
        #expect(unfinished.leftATurnOpen == false)
        #expect(unfinished.wasSilent == false)
        #expect(unfinished.message.contains("status 2"))
        #expect(unfinished.message.contains("not logged in"))
    }

    /// `sawResult` is one flag for a run that serves many turns, so it is true for the rest of the
    /// run the moment the first turn closes. A process that died during turn five therefore read
    /// as a process with nothing left to report. The state does not go stale that way.
    @Test("a stale sawResult cannot silence a turn that is still open")
    func staleSawResult() {
        let run = UnfinishedRun.of(
            status: 0, sawResult: true, state: .running, stderr: "", command: ""
        )

        #expect(run?.leftATurnOpen == true)
    }

    /// The CLI holds a blocked turn open until it gets an answer. Once the pipe is gone the answer
    /// can never arrive, so `waiting` is as abandoned as `running` is.
    @Test("a turn blocked on a question is abandoned too")
    func waitingIsMidTurn() {
        let run = UnfinishedRun.of(
            status: 0, sawResult: false, state: .waiting, stderr: "", command: ""
        )

        #expect(run?.leftATurnOpen == true)
    }

    @Test("an exit that said something is reported in its own words, not as silence")
    func spokeOnTheWayOut() throws {
        let run = UnfinishedRun.of(
            status: 0, sawResult: false, state: .running,
            stderr: "Error: the weekly limit has been reached", command: ""
        )

        let unfinished = try #require(run)
        #expect(unfinished.wasSilent == false)
        #expect(unfinished.message.contains("weekly limit"))
        #expect(unfinished.subtype == UnfinishedRun.exitSubtype)
    }

    @Test("whitespace on stderr is not something said")
    func blankStderrIsSilence() {
        let run = UnfinishedRun.of(
            status: 0, sawResult: false, state: .running, stderr: "  \n \n", command: ""
        )

        #expect(run?.wasSilent == true)
    }

    // MARK: The row

    @Test("the payload is what AgentExit reads back")
    func payloadRoundTrips() throws {
        let run = try #require(UnfinishedRun.of(
            status: 0, sawResult: false, state: .running, stderr: "", command: "/opt/bin/claude"
        ))

        let exit = AgentExit.decode(run.payload)
        #expect(exit.cause == .endedMidTurn)
        #expect(exit.command == "/opt/bin/claude")
        #expect(exit.title == "Turn never finished")
        #expect(exit.summary.contains("middle of this turn"))
        #expect(exit.advice.contains("still in the worktree"))
        #expect(exit.advice.contains("/opt/bin/claude"))
    }

    /// A status of nought must not be drawn as "Agent exited (0)", which reads as nothing having
    /// gone wrong next to a turn that never finished.
    @Test("a clean status is never drawn as a clean ending")
    func cleanStatusIsNotACleanEnding() throws {
        let run = try #require(UnfinishedRun.of(
            status: 0, sawResult: false, state: .running, stderr: "", command: ""
        ))

        #expect(AgentExit.decode(run.payload).title.contains("(0)") == false)
    }

    @Test("a run that spoke on the way out keeps the old payload shape")
    func spokenPayloadIsAProcessExit() throws {
        let run = try #require(UnfinishedRun.of(
            status: 1, sawResult: false, state: .running, stderr: "Error: no credentials", command: ""
        ))

        let exit = AgentExit.decode(run.payload)
        #expect(exit.status == 1)
        #expect(exit.cause == .reported("Error: no credentials"))
    }
}
