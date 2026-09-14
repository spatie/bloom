import Foundation

/// Whether a run script's command is still going in its tab, worked out from nothing but who holds
/// the terminal.
///
/// **There is no exit status to wait for, and that is the constraint everything here is shaped
/// by.** A run script is typed into a login shell rather than exec'd, so Ctrl+C, Up and Return work
/// the way they do in any terminal, and the price is that nothing reports the command ending. What
/// can be read is the terminal's foreground process group: the shell's own while it sits at its
/// prompt, the job's while the job runs. A poll of that is the only signal there is.
///
/// **A single reading is not believed, in either direction.** A shell's rc files and its prompt
/// hooks run `git` and friends as foreground jobs of their own, for a few tens of milliseconds at
/// a time, so a poll that lands on one sees a busy terminal with nothing the owner started in it.
/// And a dev server restarting its watcher can hand the terminal back for a beat. So a busy pane
/// is believed stopped only after two idle readings in a row, and a pane nobody typed into is only
/// believed busy after two busy ones.
///
/// **Idle before the command was typed means nothing.** A fresh shell is idle while it reads its
/// rc files, and the command it has been handed is sitting in the pty unread. So a typed command
/// counts as running from the moment it was typed, and an idle reading after that is only a stop
/// once the command has either been seen running or had `startGrace` to show up. A command that
/// finishes between two polls is never seen at all; that one is reported as stopped with no
/// duration, which is honest about what was measured.
///
/// Pure, and fed by the app's poll. The poll is in `RunScriptActivityMonitor`, beside the terminals
/// it reads; everything it decides is here where the tests reach it.
public struct RunScriptActivity: Sendable, Hashable {
    /// What the tab strip and the strip above the shell draw.
    public enum State: Sendable, Hashable {
        /// Nothing is known to be running and nothing has stopped that is worth saying so about.
        case idle
        /// The command is going, as far as the readings say, since this moment.
        case running(since: Date)
        /// It was running and is not any more. Nil when it ended too quickly to be seen running,
        /// so there is no measured length to report.
        case stopped(after: Duration?)

        public var isRunning: Bool {
            if case .running = self { return true }
            return false
        }
    }

    /// How long a typed command may go unseen before an idle terminal is believed.
    ///
    /// Eight seconds, because the shell does not read what was typed until its rc files have run,
    /// and a zsh with a plugin manager and `nvm` loading can spend whole seconds on those. Too
    /// long costs a dot that lingers on a command that ended at once; too short costs a strip
    /// saying a dev server stopped while it was still starting, which is the worse lie.
    public static let startGrace: Duration = .seconds(8)

    enum Phase: Sendable, Hashable {
        /// Nothing typed, nothing believed. `busySince` is the first reading of a busy streak that
        /// has not been confirmed yet.
        case idle(busySince: Date?)
        /// Bloom typed the command at this moment and it has not been seen running yet.
        case typed(at: Date)
        /// Seen running. `idleSince` is the first reading of an idle streak that has not been
        /// confirmed yet.
        case busy(since: Date, idleSince: Date?)
        /// Seen running and then seen stopped.
        case stopped(after: Duration?, busySince: Date?)
    }

    private(set) var phase: Phase = .idle(busySince: nil)

    public init() {}

    public var state: State {
        switch phase {
        case .idle: .idle
        case .typed(let at): .running(since: at)
        case .busy(let since, _): .running(since: since)
        case .stopped(let after, _): .stopped(after: after)
        }
    }

    /// Bloom typed the command into the shell.
    ///
    /// Ignored while the pane is already believed busy with nothing suggesting otherwise: text
    /// submitted into a running command is an answer to it rather than a new one, and restarting
    /// the clock would make "stopped after" measure from somebody pressing `y`.
    public mutating func typed(at moment: Date) {
        if case .busy(_, nil) = phase { return }
        phase = .typed(at: moment)
    }

    /// One reading of the terminal, from the poll.
    public mutating func observe(busy: Bool, at moment: Date) {
        switch phase {
        case .idle(let busySince):
            guard busy else { return phase = .idle(busySince: nil) }
            phase = busySince.map { .busy(since: $0, idleSince: nil) } ?? .idle(busySince: moment)

        case .typed(let at):
            if busy { return phase = .busy(since: at, idleSince: nil) }
            guard Self.length(from: at, to: moment) >= Self.startGrace else { return }
            phase = .stopped(after: nil, busySince: nil)

        case .busy(let since, let idleSince):
            guard !busy else { return phase = .busy(since: since, idleSince: nil) }
            guard let idleSince else { return phase = .busy(since: since, idleSince: moment) }
            phase = .stopped(after: Self.length(from: since, to: idleSince), busySince: nil)

        case .stopped(let after, let busySince):
            guard busy else { return phase = .stopped(after: after, busySince: nil) }
            // Up and Return in the shell, or anything else typed there by hand. Two readings, for
            // the same prompt hooks an untyped idle pane is guarded against.
            phase = busySince.map { .busy(since: $0, idleSince: nil) }
                ?? .stopped(after: after, busySince: moment)
        }
    }

    /// A reading taken on purpose, the moment before a decision has to be made on it, and believed
    /// at once.
    ///
    /// For a tab restored from tmux with its dev server still going. Picking the script, or a
    /// workspace opening with it set to autostart, must not wait two polls to learn that, because
    /// the answer it would have acted on meanwhile is to type the command again into the running
    /// server. Only a busy reading is taken at its word: an idle one is what an rc file looks like.
    public mutating func adopt(busy: Bool, at moment: Date) {
        guard busy else { return }
        switch phase {
        case .idle, .stopped: phase = .busy(since: moment, idleSince: nil)
        case .typed, .busy: return
        }
    }

    /// The cross on the stopped strip. The pane goes back to saying nothing until something runs.
    public mutating func dismiss() {
        guard case .stopped = phase else { return }
        phase = .idle(busySince: nil)
    }

    /// From one moment to a later one, never negative: a clock that stepped backwards is not a
    /// reason to report a command as having run for minus a second.
    private static func length(from start: Date, to end: Date) -> Duration {
        .milliseconds(max(0, Int((end.timeIntervalSince(start) * 1000).rounded())))
    }
}
