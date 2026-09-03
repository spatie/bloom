import Foundation
import Observation
import BloomCore

/// What each terminal pane was running, kept so a pane that comes back without its process can say
/// what it lost and offer it back.
///
/// **It starts nothing.** The command is written down, drawn in the pane by `TerminalRestartStrip`
/// and run only when somebody presses Start. That is the whole shape of the feature and it is not
/// a detail: a command remembered here may have been written by an agent through `terminal_start`
/// rather than typed by the owner, and an app that re-ran the last thing an agent asked for, on a
/// launch nobody connected to that agent, would be executing a model's words with no one in the
/// loop. See `TerminalCommandMemory`, which is the same point made where the tests can reach it.
///
/// A helper type beside the views rather than a view: it runs `ps` through `ProcessTable` and talks
/// to the store, and neither belongs in a `body`.
@MainActor
@Observable
final class TerminalCommandRecall {
    /// One live pane, as the recorder needs it: the pane, the pid of the pty child, and the tmux
    /// session holding its shell when there is one.
    struct Pane: Sendable {
        let pane: String
        let shell: Int32
        let session: String?
    }

    /// Panes with a command to offer, which is what the strip draws. Set when a pane opens with a
    /// remembered command and nothing running, cleared when the offer is taken or dismissed.
    private var offers: [String: String] = [:]

    /// What Bloom itself last sent into a pane, which is preferred over what `ps` reports.
    ///
    /// The two answer different questions and the difference is the whole reason this exists. `ps`
    /// says `node /opt/homebrew/lib/node_modules/npm/bin/npm-cli.js run dev`, which is true and
    /// unreadable and not what anybody would type; the run script and `terminal_start` both know
    /// the command was `npm run dev`. So the exact text wins whenever Bloom has it.
    ///
    /// It is dropped the moment a poll finds the pane idle, so a command that has been stopped
    /// cannot be reported over whatever was started by hand afterwards.
    private var sent: [String: String] = [:]

    /// What the store already holds, so an unchanged answer costs no write. Absent means no row,
    /// which is how nil is stored.
    private var recorded: [String: String] = [:]

    /// Panes that had something running as of the last poll. See `remember`.
    private var busy: Set<String> = []

    // MARK: - What Bloom typed

    /// A line Bloom put into a pane itself.
    ///
    /// Refused for a pane that already had something running, because text sent into one of those
    /// is an answer rather than a command: `terminal_write` is how an agent says `y` to a prompt as
    /// much as how it starts a server, and a `y` remembered as what the pane was running is what
    /// the strip would offer back. Which of the two a keystroke is cannot be known as it is typed,
    /// so the last poll's reading of the pane decides, and a pane nobody has polled yet is one
    /// whose shell was forked seconds ago.
    func remember(_ command: String, sentTo pane: String) {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !busy.contains(pane) else { return }
        sent[pane] = trimmed
    }

    // MARK: - The offer

    /// The offers standing for a whole tab's panes at once.
    ///
    /// Plural because of where it has to be read from. `TerminalSplitView` positions its panes
    /// inside a `GeometryReader`, and a store read that only happens in the layout pass is a redraw
    /// that only happens by luck: the same note is already on the layout and the focus request it
    /// reads at the top of its body. So the whole tab asks once, up there, and the panes are handed
    /// their answer.
    func offers(inPanes panes: [String]) -> [String: String] {
        offers.filter { panes.contains($0.key) }
    }

    /// The user pressed Start. The offer goes because the command is running again, and it becomes
    /// what Bloom last sent into this pane, so the next poll records it as the pane's own text
    /// rather than as whatever `ps` calls it.
    func accepted(inPane pane: String) {
        if let command = offers.removeValue(forKey: pane) { sent[pane] = command }
    }

    /// The user pressed the dismiss button, which is the one way a command is deliberately
    /// forgotten. It goes from the database too: an offer that came back after being waved away
    /// would be the app arguing.
    func dismiss(inPane pane: String, store: Store?) {
        offers[pane] = nil
        forget(panes: [pane], store: store)
    }

    /// A pane that is going away for good. Its row would otherwise sit in the settings table for
    /// the life of the database, keyed to an id nothing can ever name again.
    func forget(panes: [String], store: Store?) {
        for pane in panes {
            offers[pane] = nil
            sent[pane] = nil
            recorded[pane] = nil
            busy.remove(pane)
        }
        guard let store, !panes.isEmpty else { return }
        Task {
            for pane in panes {
                try? await store.setSetting(TerminalCommandMemory.key(paneID: pane), nil)
            }
        }
    }

    /// Whether a pane that has just been drawn should offer its remembered command.
    ///
    /// A pane with no tmux session behind it has a shell forked seconds ago and is running nothing
    /// by definition, so the offer stands on the stored value alone. A pane with one may have kept
    /// its process through the quit, and that is asked of tmux rather than inferred from the start
    /// decision: `TmuxSessions.decide` answers off a snapshot that is still empty on the first
    /// frame after launch, so it reports a session that does exist as a fresh one and lets tmux
    /// sort it out. Harmless there, and here it would draw an offer to start a dev server over a
    /// dev server that never stopped.
    func considerOffer(
        inPane pane: String,
        session: String?,
        persistence: TerminalPersistence?,
        store: Store?
    ) async {
        guard let store, offers[pane] == nil else { return }
        let stored = try? await store.setting(TerminalCommandMemory.key(paneID: pane))
        guard let command = TerminalCommandMemory.offerable(stored) else { return }
        recorded[pane] = command

        if let session, let persistence {
            let pids = await persistence.panePIDs()
            if let shell = pids[session], let table = await ProcessTable.current(),
               table.foregroundCommand(ofShell: shell) != nil {
                return
            }
        }
        offers[pane] = command
    }

    // MARK: - Recording

    /// Writes down what each live pane is running, or clears the pane's row when it is idle.
    ///
    /// **When this runs is the decision the feature turns on.** Quitting is the obvious moment and
    /// it is the wrong one to rely on alone: Bloom is developed in Bloom, it gets killed, force
    /// quit and crashed, and a memory that only exists because the app was allowed to shut down
    /// tidily is a memory that is missing exactly when the shutdown was not tidy. So it is a slow
    /// poll as well, and the poll is what carries the answer through a `kill -9`. Thirty seconds
    /// because a dev server runs for hours: losing the last half minute of a memory costs nothing,
    /// and the sweep is one `ps` for every pane at once, plus one `list-panes` when tmux is holding
    /// any of them.
    ///
    /// An outstanding offer is never cleared. The pane it belongs to has a fresh shell sitting idle
    /// in it, so the honest reading of the machine is "nothing running", and acting on that would
    /// delete the command the pane is at that moment offering to start.
    func record(panes: [Pane], persistence: TerminalPersistence?, store: Store) async {
        guard !panes.isEmpty, let table = await ProcessTable.current() else { return }

        var pids: [String: Int32] = [:]
        if panes.contains(where: { $0.session != nil }) {
            pids = await persistence?.panePIDs() ?? [:]
        }

        for pane in panes {
            // A tmux-backed pane's own pty child is a client, so its children are nothing the user
            // started. The shell is the server's, and only tmux can name it.
            let shell = pane.session.flatMap { pids[$0] } ?? pane.shell
            let running = table.foregroundCommand(ofShell: shell)
            if running == nil {
                busy.remove(pane.pane)
                sent[pane.pane] = nil
                guard offers[pane.pane] == nil else { continue }
            } else {
                busy.insert(pane.pane)
            }
            let remembered = TerminalCommandMemory.remembered(
                sent: sent[pane.pane], running: running
            )
            guard remembered != recorded[pane.pane] else { continue }
            try? await store.setSetting(TerminalCommandMemory.key(paneID: pane.pane), remembered)
            recorded[pane.pane] = remembered
        }
    }
}
