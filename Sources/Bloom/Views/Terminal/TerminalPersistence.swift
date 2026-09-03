import Foundation
import BloomCore

/// The tmux server that holds shells for panes, so quitting Bloom no longer takes them with it.
///
/// One instance per database, owned by `TerminalSessionStore`. It knows three things: whether tmux
/// is on the machine, which sessions exist, and how to kill one. The naming, the restore decision
/// and the orphan rule are all in `TmuxSessions`, which is where the tests reach them.
///
/// The server runs on a private socket with a configuration Bloom writes itself, so the user's own
/// tmux, their `~/.tmux.conf` and their sessions are untouched by all of this.
@MainActor
final class TerminalPersistence {
    /// The Settings switch. Off by default: a shell that outlives the app is a real change in what
    /// quitting means, and nobody should get it without asking.
    static let defaultsKey = "terminal.persistSessions"

    /// nil when tmux is not installed, which is the whole of the fallback: every caller then reads
    /// `.inProcess` and gets exactly today's behaviour.
    let command: TmuxCommand?

    /// Sessions as of the last refresh. Only ever used to tell a restore from a fresh start, never
    /// to decide what to exec, because `new-session -A` already resolves that against the server
    /// rather than against this snapshot.
    private var knownSessions: Set<String> = []

    /// Where tmux is, resolved once for the whole launch.
    ///
    /// `Shell.which` walks the merged PATH and stats a candidate per entry, 37 of them on this
    /// machine, and it was asked twice: here and again in `init`, which runs on the main actor
    /// during bootstrap. One walk answers both.
    static let tmuxPath: String? = Shell.which("tmux")

    /// Whether tmux is on this machine at all, for the Settings row that has to say so plainly
    /// rather than letting a user find out when a terminal fails to open.
    static var isTmuxInstalled: Bool { tmuxPath != nil }

    /// The switch as the user set it, which is not the same as whether it can be honoured.
    static var isSwitchedOn: Bool { UserDefaults.standard.bool(forKey: defaultsKey) }

    var isAvailable: Bool { command != nil }

    /// **Synchronous disk work on the main actor, deliberately.** It writes tmux's configuration,
    /// and the path it writes to is handed to `TmuxCommand` in the same breath, so a terminal
    /// opened a moment later launches against it. Moving the write off the actor would make that
    /// ordering a race for a saving nobody can feel: the PATH walk is shared now, and what is
    /// left is one `createDirectory` and one atomic write of a few hundred bytes, once per launch.
    init(databasePath: String) {
        guard let executable = Self.tmuxPath else {
            command = nil
            return
        }

        let directory = (databasePath as NSString).deletingLastPathComponent
        let configPath = (directory as NSString).appendingPathComponent("tmux.conf")
        command = TmuxCommand(
            executable: executable,
            socketName: TmuxSessions.socketName(databasePath: databasePath),
            configPath: configPath
        )
        writeConfiguration(to: configPath)
    }

    /// The configuration is regenerated on every launch rather than written once, so a Bloom update
    /// that changes an option reaches a machine that already has the file.
    private func writeConfiguration(to path: String) {
        // `LoginShell`, the same as the pty in `TerminalView`. These two decided it separately
        // and identically, which is one decision too many for a fact both terminals have to agree
        // about.
        let text = TmuxSessions.configuration(defaultShell: LoginShell.path())
        let directory = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        try? text.write(toFile: path, atomically: true, encoding: .utf8)
    }

    // MARK: - Launch

    /// What a pane should do, from the snapshot this instance last took.
    func decision(workspaceID: WorkspaceID, paneID: String) -> TerminalStartDecision {
        TmuxSessions.decide(
            workspaceID: workspaceID,
            paneID: paneID,
            persistenceEnabled: Self.isSwitchedOn,
            tmuxAvailable: isAvailable,
            existingSessions: knownSessions
        )
    }

    /// Refreshes the snapshot, and pushes the current configuration into a server that was already
    /// running. `-f` is only read when a server starts, so without this a session created by
    /// yesterday's build would keep yesterday's options for as long as it lives.
    func refresh() async {
        guard let command else { return }
        knownSessions = Set(await sessionNames())
        guard !knownSessions.isEmpty else { return }
        _ = try? await Shell.run(command.executable, command.sourceConfiguration, timeout: .seconds(5))
    }

    private func sessionNames() async -> [String] {
        await sessions() ?? []
    }

    /// The sessions on our socket, or nil when the question could not be asked at all.
    ///
    /// The difference matters in exactly one place, and it matters there a great deal: the
    /// migration that moved the bottom panel's tabs into the centre column drops a tab that holds
    /// nothing, and "tmux answered, there are none" is a fact while "tmux did not answer" is not.
    /// A tab whose shell MIGHT still be alive is carried over rather than thrown away, so this
    /// says which of the two happened instead of flattening both to an empty list.
    ///
    /// tmux not being installed is a fact, not a silence: nothing can be alive on a machine with
    /// no tmux, so that answers with none rather than with nil.
    func sessions() async -> [String]? {
        guard let command else { return [] }
        // The exit status is deliberately ignored: "no server running" is a failure to tmux and
        // simply "nothing persisted yet" here. A throw is different, and is the nil case: the
        // process could not be run, or it was still running when the timeout came round.
        guard let result = try? await Shell.run(
            command.executable, command.listSessions, timeout: .seconds(5)
        ) else { return nil }
        return TmuxSessions.parseSessionList(result.stdout)
    }

    /// The shell pid inside each session on our socket.
    ///
    /// A tmux-backed pane's pty child is a *client*, so its process group holds nothing the user
    /// started: the shell and everything under it belong to the server. This is the only way from
    /// a pane to the pid whose children say what is running there, which is what
    /// `TerminalCommandRecall` needs both to record a command and to know it is still going.
    ///
    /// Empty rather than nil when tmux is absent or the server is down, for the same reason
    /// `sessions()` answers with none: nothing can be running in a session that does not exist.
    func panePIDs() async -> [String: Int32] {
        guard let command else { return [:] }
        guard let result = try? await Shell.run(
            command.executable, command.listPanes, timeout: .seconds(5)
        ) else { return [:] }
        return TmuxSessions.parsePanePIDs(result.stdout)
    }

    // MARK: - Teardown

    /// Kills the sessions of panes that are going away for good.
    ///
    /// Deliberately not gated on `isSwitchedOn`. Sessions outlive the setting: a user who turns
    /// persistence off, or who archives a workspace whose shells were started while it was on,
    /// must still be left with nothing running in a worktree that is being deleted.
    func kill(workspaceID: WorkspaceID, paneIDs: [String]) async {
        await kill(sessions: paneIDs.map {
            TmuxSessions.sessionName(workspaceID: workspaceID, paneID: $0)
        })
    }

    /// Everything one workspace owns, read off the session names rather than off Bloom's own
    /// bookkeeping. Archiving deletes the worktree, so this may not depend on a tab list that was
    /// never loaded or a split layout that was lost.
    func killEverything(workspaceID: WorkspaceID) async {
        guard command != nil else { return }
        let sessions = await sessionNames()
        await kill(sessions: TmuxSessions.sessions(ofWorkspace: workspaceID, in: sessions))
    }

    func kill(sessions: [String]) async {
        guard let command, !sessions.isEmpty else { return }
        for session in sessions {
            _ = try? await Shell.run(
                command.executable, command.killSession(session), timeout: .seconds(5)
            )
            knownSessions.remove(session)
        }
    }

    /// The launch sweep. Everything on our socket whose pane is no longer reachable from the
    /// database goes, which is the rule stated in `TmuxSessions.orphans`.
    ///
    /// `doubtful` is the workspaces the census could not enumerate. They are handed straight
    /// through to `orphans`, which spares them: see its note on why silence is not unreachability.
    func sweepOrphans(livePaneIDs: Set<String>, doubtful: Set<WorkspaceID>) async {
        guard command != nil else { return }
        let sessions = await sessionNames()
        knownSessions = Set(sessions)
        let reachable = TmuxSessions.reachablePanes(livePaneIDs, persistenceEnabled: Self.isSwitchedOn)
        await kill(sessions: TmuxSessions.orphans(
            sessions: sessions, livePaneIDs: reachable, sparing: doubtful
        ))
    }
}
