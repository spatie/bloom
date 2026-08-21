import Foundation
import Testing
@testable import BloomCore

/// The whole of `SessionState`'s transition table, and the bugs each refusal is written for.
@Suite("The session lifecycle")
struct SessionLifecycleTests {
    private func session(_ state: SessionState) -> Session {
        Session(workspaceID: WorkspaceID("w"), state: state)
    }

    // MARK: - The table

    @Test("a turn starts from every state with no turn open", arguments: [
        SessionState.idle, .failed, .cancelled,
    ])
    func turnStarts(from state: SessionState) {
        #expect(state.transition(on: .turnStarted) == .moves(to: .running))
    }

    /// The agent is blocked on a question and is not reading its stdin for anything else. A turn
    /// sent into that goes nowhere, and marking the session `running` for it hides the raised hand
    /// that is the only thing telling the user why nothing is happening.
    @Test("a turn cannot be started while the agent is waiting on an answer")
    func turnCannotStartWhileWaiting() {
        #expect(SessionState.waiting.transition(on: .turnStarted) == .refused)
        #expect(SessionState.running.transition(on: .turnStarted) == .unchanged)
    }

    @Test("a turn in flight ends where the result says")
    func turnFinishes() {
        for state in [SessionState.running, .waiting] {
            #expect(state.transition(on: .turnFinished(isError: false)) == .moves(to: .idle))
            #expect(state.transition(on: .turnFinished(isError: true)) == .moves(to: .failed))
        }
    }

    /// SIGTERM makes the CLI report `error_during_execution` on its way out, so a result after a
    /// stop is the ordinary case rather than news, and a result arriving just behind the process
    /// exit that already filed the turn is the same shape. Both runners used to carry a
    /// `cancelled ? .cancelled : ...` ternary to say the first of those at the call site.
    @Test("a result for a turn that is already closed is ignored, not refused", arguments: [
        SessionState.idle, .failed, .cancelled,
    ])
    func lateResult(from state: SessionState) {
        #expect(state.transition(on: .turnFinished(isError: false)) == .unchanged)
        #expect(state.transition(on: .turnFinished(isError: true)) == .unchanged)
    }

    @Test("answering when nothing is blocked does nothing and is never refused", arguments: [
        SessionState.idle, .running, .failed, .cancelled,
    ])
    func unblockingNothing(from state: SessionState) {
        #expect(state.transition(on: .unblocked) == .unchanged)
    }

    @Test("answering the last question puts the turn back to work")
    func unblocking() {
        #expect(SessionState.waiting.transition(on: .unblocked) == .moves(to: .running))
    }

    @Test("a process that ends says which of the two things happened")
    func processEnds() {
        for state in [SessionState.running, .waiting] {
            #expect(state.transition(on: .processExited) == .moves(to: .idle))
            #expect(state.transition(on: .processFailed) == .moves(to: .failed))
        }
        for state in [SessionState.idle, .failed, .cancelled] {
            #expect(state.transition(on: .processExited) == .unchanged)
            #expect(state.transition(on: .processFailed) == .unchanged)
        }
    }

    // MARK: - Recovery, which is in the table rather than around it

    /// Commit d81efda. A blocked agent holds its turn open until it is answered and the CLI puts
    /// no timer on that, so a session left `waiting` when Bloom died came back claiming to be
    /// waiting on a question whose process was long gone: the sidebar showed the raised hand, the
    /// Dock carried a badge, and the transcript offered four live buttons that wrote into a closed
    /// pipe. `waiting` is the half of this that needed saying; `running` is the obvious half.
    @Test("nothing the last launch left mid turn is mid turn after a relaunch", arguments: [
        SessionState.running, .waiting,
    ])
    func relaunchClearsMidTurn(from state: SessionState) {
        #expect(state.transition(on: .appRelaunched) == .moves(to: .idle))
    }

    /// Recovery runs once per launch over every row, so it has to be silent about the ones it has
    /// nothing to say about. A machine that refused here would file a bug per idle session per
    /// launch, which is how a rule stops being believed.
    @Test("a relaunch is never refused, from any state", arguments: SessionState.allCases)
    func relaunchIsAlwaysLegal(from state: SessionState) {
        #expect(state.transition(on: .appRelaunched).isRefused == false)
    }

    // MARK: - The bugs, written as transitions that can no longer happen

    /// Commit dff8a01. Two routes race to answer a permission question, the stored project grants
    /// and the person clicking, and the loser used to write `waiting` for a decision that had
    /// already been made: the session sat marked as blocked on nothing, and the CLI discarded the
    /// second answer as a request id mismatch. `AgentRunner` still guards this by hand at the call
    /// site; this is the same sentence as a rule, so `CodexRunner` gets it too.
    @Test("a settled question can no longer mark a session as waiting", arguments: [
        SessionState.idle, .failed, .cancelled,
    ])
    func blockedOnASettledQuestion(from state: SessionState) {
        var subject = session(state)
        #expect(subject.apply(.blocked) == .refused)
        #expect(subject.state == state)
    }

    @Test("a question during a turn is what waiting means")
    func blockedDuringATurn() {
        #expect(SessionState.running.transition(on: .blocked) == .moves(to: .waiting))
        #expect(SessionState.waiting.transition(on: .blocked) == .unchanged)
    }

    /// Stop is fire and forget from a button that cannot await, so the request reaches the actor
    /// whenever the actor gets to it. Landing on a session that has already finished files a turn
    /// that ended normally as one the user abandoned, and the transcript then says so for ever.
    @Test("stopping a turn that is not running can no longer rewrite how it ended", arguments: [
        SessionState.idle, .failed,
    ])
    func cancellingNothing(from state: SessionState) {
        var subject = session(state)
        #expect(subject.apply(.cancelled) == .refused)
        #expect(subject.state == state)
    }

    @Test("stopping a turn that is running or blocked is what cancelling means")
    func cancelling() {
        for state in [SessionState.running, .waiting] {
            #expect(state.transition(on: .cancelled) == .moves(to: .cancelled))
        }
        #expect(SessionState.cancelled.transition(on: .cancelled) == .unchanged)
    }

    /// `updatedAt` is not a separate chore a caller remembers. It is what
    /// `TranscriptModel.refreshSession` reads to decide whether the row it is holding still
    /// describes the last turn, so a state change written without it is one nothing downstream
    /// notices. Commit de3f173 is the family this belongs to.
    @Test("a state that moves always stamps when it moved")
    func moveStampsTheMoment() {
        var subject = session(.idle)
        subject.updatedAt = Date(timeIntervalSince1970: 0)
        let at = Date(timeIntervalSince1970: 1_700_000_000)

        subject.apply(.turnStarted, at: at)
        #expect(subject.state == .running)
        #expect(subject.updatedAt == at)
    }

    /// A refusal and a no-op both leave the state alone, and only one of them should touch the
    /// clock. A session whose `updatedAt` moved for a transition that did not happen is a session
    /// every reader believes has news.
    @Test("a state that does not move leaves the clock alone")
    func stillnessDoesNotStampTheMoment() {
        var subject = session(.idle)
        let before = Date(timeIntervalSince1970: 0)
        subject.updatedAt = before

        subject.apply(.blocked, at: Date())
        subject.apply(.unblocked, at: Date())
        #expect(subject.updatedAt == before)
    }
}
