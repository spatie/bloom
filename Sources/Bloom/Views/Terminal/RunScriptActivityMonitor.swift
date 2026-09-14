import Foundation
import Darwin
import Observation
import BloomCore

/// The poll behind a run script tab's dot and its stopped strip.
///
/// **What it reads is who holds each terminal, and nothing else.** A run script is typed into a
/// shell, so there is no exit status to wait for; what the machine does say is the terminal's
/// foreground process group, which is the shell's own at its prompt and the job's while a job
/// runs. What those readings mean, and how many of them it takes to believe one, is
/// `RunScriptActivity` in the core. This only takes the readings and keeps the answers.
///
/// **Two ways to read, because a pane is one of two things.** A shell Bloom forked itself has its
/// pty's primary side in this process, and `tcgetpgrp` on that is one system call with no process
/// behind it, so those are read every second. A tmux-backed pane's pty belongs to a client whose
/// terminal says nothing about the shell inside the session; that shell's own terminal is only
/// visible to `ps`, as `tpgid`, from the pid `list-panes` names. That costs two subprocesses, so
/// it is done every other tick, and once for all such panes rather than once per pane.
///
/// Only panes of tabs opened for a run script are polled, and the loop ends itself when there
/// are none, so a workspace with no run scripts pays nothing for any of this.
///
/// A helper type beside the views rather than a view, for the same reason as
/// `TerminalCommandRecall`: it runs `ps` and a `View` does not.
@MainActor
@Observable
final class RunScriptActivityMonitor {
    /// How a pane's terminal can be asked who holds it.
    enum Probe {
        /// A shell this process forked: the pty's primary descriptor and the shell's pid.
        case direct(descriptor: Int32, shell: Int32)
        /// A shell held in a tmux session, named so `list-panes` can say which pid it is.
        case tmux(session: String)
    }

    /// What the strip and the tab draw, per pane. Written only when a pane's answer changes, so a
    /// reading that confirms what was already believed invalidates nothing on screen.
    private var states: [String: RunScriptActivity.State] = [:]

    /// The readings behind those answers, including the half-believed streaks nothing draws.
    @ObservationIgnored private var activities: [String: RunScriptActivity] = [:]

    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var tick = 0

    /// Which panes to read and how, asked afresh on every tick so a pane closed between two ticks
    /// is simply not there on the next. Set once by `TerminalSessionStore`, which owns both the
    /// shells and the knowledge of which tab each belongs to.
    @ObservationIgnored var probes: @MainActor () -> [String: Probe] = { [:] }

    /// The tmux server the sessions live on, when there is one.
    @ObservationIgnored var persistence: @MainActor () -> TerminalPersistence? = { nil }

    /// Called when a pane is believed running, which is the moment an offer from the last launch
    /// stops being true.
    @ObservationIgnored var onRunning: @MainActor (String) -> Void = { _ in }

    /// How often the loop wakes, and how many of those wakes a tmux pane is read on.
    private static let interval: Duration = .seconds(1)
    private static let tmuxEvery = 2

    // MARK: - Reading

    func state(inPane pane: String) -> RunScriptActivity.State {
        states[pane] ?? .idle
    }

    // MARK: - Writing

    /// Bloom typed a command into this pane. Nothing is recorded for a pane nobody polls, which is
    /// every pane of an ordinary terminal: an agent's `terminal_write` goes through the same door.
    func typed(inPane pane: String) {
        guard probes()[pane] != nil else { return }
        update(pane) { $0.typed(at: .now) }
        ensurePolling()
    }

    /// The cross on the stopped strip.
    func dismiss(inPane pane: String) {
        update(pane) { $0.dismiss() }
    }

    /// Panes that are gone for good. Their answers would otherwise sit here for the launch, keyed
    /// to ids nothing can name again.
    func forget(panes: [String]) {
        for pane in panes {
            activities[pane] = nil
            if states[pane] != nil { states[pane] = nil }
        }
    }

    /// The quit path. Nothing is read after the shells have been told to go.
    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    // MARK: - Polling

    /// Starts the loop if there is anything to read and it is not already running. Cheap enough
    /// to call whenever a shell is forked.
    func ensurePolling() {
        guard pollTask == nil, !probes().isEmpty else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.interval)
                guard !Task.isCancelled, let self else { return }
                guard await self.poll() else {
                    self.pollTask = nil
                    return
                }
            }
        }
    }

    /// One tick. False when there is nothing left to read, which ends the loop.
    private func poll() async -> Bool {
        let probes = probes()
        guard !probes.isEmpty else { return false }
        tick += 1

        let readTmux = tick % Self.tmuxEvery == 0
        let readings = await read(probes, includingTmux: readTmux)
        apply(readings) { activity, busy, moment in activity.observe(busy: busy, at: moment) }
        return true
    }

    /// Reads these panes now and believes a busy answer at once.
    ///
    /// For the moment before a decision is taken on a pane that has not been polled yet: a tab
    /// restored from tmux with its dev server still going, which a pick would otherwise type the
    /// command into a second time. See `RunScriptActivity.adopt`.
    func readNow(panes: [String]) async {
        let probes = probes().filter { panes.contains($0.key) }
        guard !probes.isEmpty else { return }
        let readings = await read(probes, includingTmux: true)
        apply(readings) { activity, busy, moment in activity.adopt(busy: busy, at: moment) }
        ensurePolling()
    }

    private func read(_ probes: [String: Probe], includingTmux: Bool) async -> [String: Bool] {
        var readings: [String: Bool] = [:]
        var sessions: [String: String] = [:]

        for (pane, probe) in probes {
            switch probe {
            case .direct(let descriptor, let shell):
                readings[pane] = Self.isBusy(descriptor: descriptor, shell: shell)
            case .tmux(let session):
                if includingTmux { sessions[pane] = session }
            }
        }

        guard !sessions.isEmpty, let persistence = persistence() else { return readings }
        let pids = await persistence.panePIDs()
        guard let table = await ProcessTable.current() else { return readings }
        for (pane, session) in sessions {
            // A session tmux does not list yet is one whose client is still starting it, and a
            // shell that does not exist is running nothing.
            readings[pane] = pids[session].flatMap { table.isBusy(shell: $0) } ?? false
        }
        return readings
    }

    /// Whether a shell's terminal has been handed to a job. A descriptor that no longer answers is
    /// a pty that has closed, which is a shell running nothing.
    private static func isBusy(descriptor: Int32, shell: Int32) -> Bool {
        guard descriptor >= 0, shell > 0 else { return false }
        let group = tcgetpgrp(descriptor)
        return group > 0 && group != shell
    }

    /// Applies readings taken across an await. A pane that was closed while `ps` ran is not
    /// brought back by its late answer.
    private func apply(
        _ readings: [String: Bool], _ change: (inout RunScriptActivity, Bool, Date) -> Void
    ) {
        guard !readings.isEmpty else { return }
        let live = probes()
        let moment = Date.now
        for (pane, busy) in readings where live[pane] != nil {
            update(pane) { change(&$0, busy, moment) }
        }
    }

    private func update(_ pane: String, _ change: (inout RunScriptActivity) -> Void) {
        var activity = activities[pane] ?? RunScriptActivity()
        change(&activity)
        activities[pane] = activity
        let state = activity.state
        guard (states[pane] ?? .idle) != state else { return }
        let wasRunning = states[pane]?.isRunning == true
        states[pane] = state
        if state.isRunning, !wasRunning { onRunning(pane) }
    }
}
