import Foundation
import Testing
@testable import BloomCore

/// The whole of `SetupState`'s transition table, and the bugs each refusal is written for.
///
/// Every case of every event against every state, because a table with a hole in it is a table
/// nobody can rely on and the hole is always in the row nobody thought about.
@Suite("The setup lifecycle")
struct SetupLifecycleTests {
    private func workspace(_ state: SetupState, log: String = "") -> Workspace {
        Workspace(
            repoID: "r", name: "w", branch: "b", path: "/tmp/w", baseBranch: "main",
            setupState: state, setupLog: log
        )
    }

    // MARK: - The table

    @Test("a run starts from every state that is not already running", arguments: [
        SetupState.pending, .succeeded, .failed, .skipped,
    ])
    func runStarts(from state: SetupState) {
        #expect(state.transition(on: .runStarted) == .moves(to: .running))
    }

    /// Not refused, on purpose. Two runs at once is guarded where the runs are, and the column
    /// already says the true thing, so refusing here would fire on the ordinary re-run race.
    @Test("a second start while a run is in flight changes nothing and is not refused")
    func secondStart() {
        #expect(SetupState.running.transition(on: .runStarted) == .unchanged)
    }

    @Test("a finished run is only ever filed against the run that was started", arguments: [
        SetupState.pending, .succeeded, .failed, .skipped,
    ])
    func outcomeOutsideARun(from state: SetupState) {
        #expect(state.transition(on: .runFinished(succeeded: true, log: "x")) == .refused)
        #expect(state.transition(on: .runFinished(succeeded: false, log: "x")) == .refused)
    }

    @Test("a run in flight ends where its exit status says")
    func outcomeInsideARun() {
        #expect(
            SetupState.running.transition(on: .runFinished(succeeded: true, log: "x"))
                == .moves(to: .succeeded)
        )
        #expect(
            SetupState.running.transition(on: .runFinished(succeeded: false, log: "x"))
                == .moves(to: .failed)
        )
    }

    @Test("nothing to run is decided before anything is launched, never during", arguments: [
        SetupState.pending, .succeeded, .failed,
    ])
    func skipping(from state: SetupState) {
        #expect(state.transition(on: .runSkipped(note: nil)) == .moves(to: .skipped))
    }

    @Test("a live run cannot be filed as a run that never happened")
    func skippingARunningScript() {
        #expect(SetupState.running.transition(on: .runSkipped(note: nil)) == .refused)
        #expect(SetupState.skipped.transition(on: .runSkipped(note: nil)) == .unchanged)
    }

    // MARK: - Recovery, which is in the table rather than around it

    /// Commit 89e8d35. A setup script is a child of this process, so a row still `running` at
    /// launch is a run that was killed. `running` had no exit edge other than the live process
    /// writing one, so after a crash during project creation the sidebar drew a setup spinner
    /// forever for a workspace that was doing nothing.
    @Test("the app dying mid run leaves a workspace asking to be set up, not one that failed")
    func interruptedRun() {
        var subject = workspace(.running, log: "installing")
        #expect(subject.apply(.runInterrupted) == .moves(to: .pending))
        #expect(subject.setupState == .pending)
        // `.pending` and not `.failed`: nobody witnessed a failure. The line is what separates
        // this from a workspace whose setup genuinely never started.
        #expect(subject.setupLog.hasPrefix("installing\n[bloom] The app stopped"))
    }

    @Test("there is nothing to interrupt outside a run", arguments: [
        SetupState.pending, .succeeded, .failed, .skipped,
    ])
    func interruptingNothing(from state: SetupState) {
        #expect(state.transition(on: .runInterrupted) == .refused)
    }

    /// A rebuilt worktree is a fact about a directory, so it is legal from every state including
    /// `running`. A machine that could refuse this would be a machine that argues with the disk.
    @Test("a rebuilt worktree is never refused, from any state", arguments: SetupState.allCases)
    func rebuildIsAlwaysLegal(from state: SetupState) {
        #expect(state.transition(on: .worktreeRebuilt(hasSetupScript: true)).isRefused == false)
        #expect(state.transition(on: .worktreeRebuilt(hasSetupScript: false)).isRefused == false)
    }

    // MARK: - The bugs, written as transitions that can no longer happen

    /// Commit e2025f3. Archiving removes the whole worktree; restoring cuts it again from the
    /// branch and copies the `.env*` back, which is everything git tracks plus everything
    /// `files_to_copy` names, and none of that is `node_modules`, `vendor`, a built binary or the
    /// local database. The row went on saying `succeeded` about a directory deleted months
    /// earlier, so a restored workspace looked ready with nothing installed in it.
    @Test("a restored workspace can no longer claim its setup script has already run")
    func restoreCannotKeepSucceeded() {
        var subject = workspace(.succeeded, log: "installed 400 packages")
        subject.state = .archived
        subject.archivedAt = Date()

        subject.restore(to: "/tmp/w2", hasSetupScript: true)

        #expect(subject.setupState == .pending)
        #expect(subject.setupLog.contains("Run setup again"))
        // The rest of the restore is in the same statement, so there is no version of this that
        // does the state without the path or the date.
        #expect(subject.state == .active)
        #expect(subject.archivedAt == nil)
        #expect(subject.path == "/tmp/w2")
    }

    /// `skipped` when the project has no setup script, because `pending` there is an invitation to
    /// press a button that does nothing.
    @Test("a restored workspace in a project with no setup script has nothing to run")
    func restoreWithNoScript() {
        var subject = workspace(.succeeded)
        subject.restore(to: "/tmp/w2", hasSetupScript: false)
        #expect(subject.setupState == .skipped)
    }

    /// Pressing "Run setup again" cancels the task in flight and starts another, and the cancelled
    /// one still reaches its completion handler. Its outcome used to land on top of the new run's
    /// `running`, so the sidebar said a workspace was ready while its `composer install` was still
    /// going. The row is not tracking that run any more, so its result is not news.
    @Test("a superseded run can no longer report its outcome over the run that replaced it")
    func supersededRunCannotReport() {
        var subject = workspace(.running, log: "second run, still going")

        // The first run, cancelled, arriving late. It moves the row to `succeeded` in the old
        // code; here the machine refuses and the log it would have overwritten survives.
        var superseded = subject
        superseded.setupState = .pending
        #expect(superseded.apply(.runFinished(succeeded: true, log: "first run")) == .refused)
        #expect(superseded.setupState == .pending)
        #expect(superseded.setupLog == "second run, still going")

        // And the run the row is actually tracking is unaffected by any of that.
        #expect(subject.apply(.runFinished(succeeded: true, log: "done")) == .moves(to: .succeeded))
        #expect(subject.setupLog == "done")
    }

    /// The state and the log are one statement. `.failed` with nothing to read is the half-truth
    /// the next reader treats as whole, and the only way to spell an outcome is with its output.
    @Test("an outcome cannot be filed without the output that justifies it")
    func outcomeCarriesItsLog() {
        var subject = workspace(.running)
        subject.apply(.runFinished(succeeded: false, log: "composer: command not found"))
        #expect(subject.setupState == .failed)
        #expect(subject.setupLog == "composer: command not found")
    }

    /// A `swift build` in a cold worktree prints tens of megabytes and none of it is worth
    /// carrying in every read of the workspaces table. Capped where the write is, so nothing can
    /// route around it.
    @Test("a long log is capped by the write rather than by whoever remembered to")
    func logIsCapped() {
        var subject = workspace(.running)
        let huge = String(repeating: "x", count: Workspace.setupLogLimit + 5_000)
        subject.apply(.runFinished(succeeded: true, log: huge))
        #expect(subject.setupLog.count == Workspace.setupLogLimit)
    }

    /// Commit 34b840b, one column over. `state = .archived` on its own is not archiving, and a row
    /// that says a workspace is live after its worktree has gone does not heal: it is still there
    /// after a relaunch. So the date is in the same statement as the state.
    @Test("archiving cannot record the state without the date")
    func archiveWritesBothColumns() {
        var subject = workspace(.succeeded)
        let at = Date(timeIntervalSince1970: 1_700_000_000)
        subject.archive(at: at)
        #expect(subject.state == .archived)
        #expect(subject.archivedAt == at)
    }
}

/// The register, which has to be asserted on one test at a time because it is process wide.
@Suite("Refused transitions are recorded", .serialized)
struct RefusedTransitionsTests {
    /// The one thing a refusal must never do is succeed quietly, which is the state every one of
    /// these enums was in before the lifecycles existed.
    @Test("a refusal leaves the state alone and says so")
    func refusalIsRecorded() {
        RefusedTransitions.forget()
        var subject = Workspace(
            repoID: "r", name: "w", branch: "b", path: "/tmp/w", baseBranch: "main",
            setupState: .succeeded
        )

        #expect(subject.apply(.runInterrupted) == .refused)

        #expect(subject.setupState == .succeeded)
        #expect(RefusedTransitions.count == 1)
        #expect(RefusedTransitions.recent.last?.sentence == "setup refused runInterrupted from succeeded")
        RefusedTransitions.forget()
    }

    /// A refusal is a bug, and a bug that has happened two hundred times has told you everything
    /// it is going to. The count keeps climbing so nothing looks quieter than it is.
    @Test("the list is bounded and the count is not")
    func registerIsBounded() {
        RefusedTransitions.forget()
        var subject = Workspace(
            repoID: "r", name: "w", branch: "b", path: "/tmp/w", baseBranch: "main",
            setupState: .succeeded
        )
        for _ in 0..<250 { subject.apply(.runInterrupted) }
        #expect(RefusedTransitions.count == 250)
        #expect(RefusedTransitions.recent.count == 200)
        RefusedTransitions.forget()
    }
}
