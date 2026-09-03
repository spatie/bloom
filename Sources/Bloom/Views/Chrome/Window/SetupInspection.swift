import Foundation
import Observation
import SwiftUI
import BloomCore

/// The welcome window's model: it runs the probes, and it holds back what the window draws so the
/// checks can be seen settling one after another.
///
/// Not a view, deliberately. `SetupProbe` shells out to four CLIs, and a `View` that did that
/// would do it again on every redraw, which is the rule `Tools/house-rules.sh` holds. This is what
/// the view calls instead.
///
/// Two reports, and the difference between them is the whole design. `truth` is what the machine
/// actually said, and it is what the primary button reads, so pressing on is never waiting for an
/// animation. `shown` is `truth` revealed one row at a time in reading order, and it is what the
/// rows and the headline read, so the window has a moment where the last check lands and the
/// sentence above it becomes the answer. The probes themselves run concurrently; only the drawing
/// is sequenced, because a person watching four rows resolve in a random order learns nothing from
/// the order and a person watching them resolve top to bottom is watching a list being read.
@MainActor
@Observable
final class SetupInspection {
    /// What the probes came back with. Complete once `isSettled`.
    private(set) var truth = SetupReport.pending
    /// What the window draws. Never ahead of `truth`, and usually a few hundred milliseconds
    /// behind it.
    private(set) var shown = SetupReport.pending

    /// True from the moment a run starts until every row has been revealed, so the window can
    /// hold the Check again button still rather than letting it be pressed into itself.
    private(set) var isRunning = false

    /// How long between one row settling and the next being allowed to.
    ///
    /// Short on purpose. This is not a progress bar and nobody is being asked to wait for it: four
    /// rows is 420 milliseconds of settling behind whatever the probes themselves cost, which is
    /// under the quarter second either side of half a second where a delay stops reading as the
    /// interface responding and starts reading as the interface thinking.
    private static let stagger = Duration.milliseconds(140)

    /// A run whose rows arrive all at once, for Reduce Motion. See `WelcomeView`.
    ///
    /// It is only ever correct because the sole construction path sets it from
    /// `accessibilityReduceMotion`, and `reveal` below used to call `withAnimation` ungated on the
    /// strength of that. A second caller who forgot would have got the animation with no way to
    /// see they had. The gate is inside `reveal` now, so the flag is what it says it is rather
    /// than a promise about who calls it.
    var revealsInstantly = false

    private var run: Task<Void, Never>?
    private var revealRun: Task<Void, Never>?
    /// True once the checks step is actually on screen. The probes run under the greeting so
    /// nobody ever waits for them, but the rows are held back until there is somebody looking at
    /// them: a settling nobody saw is a settling that may as well not have happened, and a list
    /// that was already finished when its screen arrived is the flat version of this window.
    private var isPresentingChecks = false
    private var hasProbed = false
    /// Detection results this window was handed rather than gathered. Debug builds only; see
    /// `SetupRehearsal`.
    private let rehearsal: SetupReport?
    /// The same database-backed executable paths the Agents pane and the runners use.
    private let agentOverrides: () async -> [AgentKind: String]

    init(
        rehearsal: SetupReport? = nil,
        agentOverrides: @escaping () async -> [AgentKind: String] = { [:] }
    ) {
        self.rehearsal = rehearsal
        self.agentOverrides = agentOverrides
    }

    /// Looks again, from the top. Idempotent while a run is in flight, because the button that
    /// calls this is on screen for the whole of one.
    func start() {
        guard run == nil else { return }
        revealRun?.cancel()
        revealRun = nil
        truth = .pending
        shown = .pending
        hasProbed = false
        isRunning = true
        run = Task { [weak self] in
            await self?.probe()
            guard let self else { return }
            self.hasProbed = true
            self.run = nil
            if self.isPresentingChecks {
                self.beginReveal()
            } else {
                self.isRunning = false
            }
        }
    }

    /// The checks step has arrived. Idempotent, because the view says so every time it appears,
    /// including on the way back from a step somebody walked away to and returned from.
    func presentChecks() {
        isPresentingChecks = true
        guard hasProbed, revealRun == nil, !shown.isSettled else { return }
        beginReveal()
    }

    /// The checks step has gone, because somebody walked back to the greeting. What was already
    /// revealed stays revealed: coming forward again shows the settled list rather than replaying
    /// four rows somebody has already read.
    func dismissChecks() {
        isPresentingChecks = false
    }

    func cancel() {
        run?.cancel()
        run = nil
        revealRun?.cancel()
        revealRun = nil
        isRunning = false
    }

    private func beginReveal() {
        isRunning = true
        revealRun = Task { [weak self] in
            await self?.reveal()
            self?.revealRun = nil
            self?.isRunning = false
        }
    }

    private func probe() async {
        if let rehearsal {
            for check in rehearsal.checks { record(check) }
        } else {
            let probe = SetupProbe(agentOverrides: await agentOverrides())
            for await check in probe.run() {
                if Task.isCancelled { return }
                record(check)
            }
        }
    }

    private func record(_ check: SetupCheck) {
        var checks = truth.checks
        if let index = checks.firstIndex(where: { $0.tool == check.tool }) {
            checks[index] = check
        }
        truth = SetupReport(checks: checks)
    }

    /// Walks down the column handing rows over one at a time.
    ///
    /// Runs after every probe has answered rather than alongside them, which is what makes the
    /// order the column's order and not the order four subprocesses happened to exit in.
    private func reveal() async {
        for tool in SetupTool.displayOrder {
            if Task.isCancelled { return }
            if !revealsInstantly, tool != SetupTool.displayOrder.first {
                try? await Task.sleep(for: Self.stagger)
                if Task.isCancelled { return }
            }
            var checks = shown.checks
            if let index = checks.firstIndex(where: { $0.tool == tool }) {
                checks[index] = SetupCheck(tool: tool, outcome: truth.outcome(for: tool))
            }
            let next = SetupReport(checks: checks)
            if revealsInstantly || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                shown = next
            } else {
                withAnimation(Motion.arrival) { shown = next }
            }
        }
    }

}
