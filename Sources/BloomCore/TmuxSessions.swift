import Foundation

/// Where a terminal pane's shell is going to run.
///
/// The two tmux cases carry the same argv, because `new-session -A` already means "attach if it is
/// there, create it if it is not". They stay separate anyway: the difference is the whole feature,
/// and a caller that cannot see it has no way to tell a restored `npm run dev` from a fresh shell.
public enum TerminalStartDecision: Sendable, Equatable {
    /// A pty forked as a child of the app, which dies with the app. The historical behaviour, and
    /// the fallback whenever tmux cannot be used.
    case inProcess
    /// A session that outlived the last quit and is being picked back up.
    case attach(session: String)
    /// Persistence is on, but this pane has no session yet.
    case createFresh(session: String)

    public var session: String? {
        switch self {
        case .inProcess: nil
        case .attach(let name), .createFresh(let name): name
        }
    }
}

/// Naming, argument building and the orphan rule for the tmux sessions that keep a pane's shell
/// alive across a quit.
///
/// One session per Bloom *pane*, never per window: `SplitLayout` already owns the geometry, so
/// tmux is only ever asked to hold one shell. Its own splitting, its status line and its prefix key
/// are all turned off, which is what keeps the feature invisible.
public enum TmuxSessions {
    /// Session names carry it so a stray `tmux ls` on our socket reads clearly, and so nothing here
    /// could ever act on a session a person created by hand.
    public static let sessionPrefix = "bloom"

    /// The one character an id may not contain, which is what makes a name splittable back into
    /// its parts. See `sanitized`.
    private static let separator: Character = "_"

    // MARK: - Naming

    /// `bloom_<workspace>_<pane>`.
    ///
    /// Stable across launches because both ids are: a pane is either a `terminal_tabs` row id or an
    /// id persisted inside the encoded `SplitLayout`, and both are UUIDs, so two panes can never
    /// land on one session.
    ///
    /// The workspace is in the name because archiving has to be able to kill every session of a
    /// workspace without asking anything else first. Reading the owner off the name means the
    /// teardown works even when the database, the tab list and the split layouts are all unreachable
    /// or already gone, which is exactly the moment it matters most.
    public static func sessionName(workspaceID: String, paneID: String) -> String {
        [sessionPrefix, sanitized(workspaceID), sanitized(paneID)].joined(separator: String(separator))
    }

    public static func paneID(ofSessionName name: String) -> String? {
        parts(of: name)?.pane
    }

    public static func workspaceID(ofSessionName name: String) -> String? {
        parts(of: name)?.workspace
    }

    public static func isBloomSession(_ name: String) -> Bool {
        parts(of: name) != nil
    }

    private static func parts(of name: String) -> (workspace: String, pane: String)? {
        let fields = name.split(separator: separator, omittingEmptySubsequences: false)
        guard fields.count == 3, fields[0] == sessionPrefix,
              !fields[1].isEmpty, !fields[2].isEmpty else { return nil }
        return (String(fields[1]), String(fields[2]))
    }

    /// tmux rejects `.` and `:` outright and treats the rest of a name as an addressable target, so
    /// anything outside the safe set is folded away rather than trusted. The underscore is folded
    /// too, because it is what separates the fields above: an id that could contain one would make
    /// a name that cannot be read back. Ids are UUIDs today, and this is what keeps that from being
    /// a load-bearing assumption.
    private static func sanitized(_ id: String) -> String {
        let safe = id.unicodeScalars.map { scalar -> Character in
            let isSafe = (scalar >= "a" && scalar <= "z")
                || (scalar >= "A" && scalar <= "Z")
                || (scalar >= "0" && scalar <= "9")
                || scalar == "-"
            return isSafe ? Character(scalar) : "-"
        }
        return String(safe)
    }

    // MARK: - Socket

    /// tmux is run on a private socket rather than the user's default one.
    ///
    /// It costs nothing and buys three things: `list-sessions` can never see a session the user
    /// started themselves, the sweep below can never kill one, and the user's own `~/.tmux.conf`
    /// is not loaded into shells Bloom drew, so their prefix key and status line stay theirs.
    ///
    /// The socket is per database, so an instance pointed at `BLOOM_DB_PATH` cannot adopt or sweep
    /// the sessions of the instance holding the user's real workspaces.
    public static func socketName(databasePath: String) -> String {
        "bloom-" + fingerprint(databasePath)
    }

    /// FNV-1a rather than `Hashable`, whose seed changes every launch. This value names a socket
    /// that has to be found again tomorrow.
    static func fingerprint(_ value: String) -> String {
        var hash: UInt32 = 2_166_136_261
        for byte in value.utf8 {
            hash ^= UInt32(byte)
            hash &*= 16_777_619
        }
        return String(format: "%08x", hash)
    }

    // MARK: - The decision

    /// What a pane should do when it is about to be drawn.
    ///
    /// `existingSessions` is a snapshot, so it may be stale or, on the very first frame after
    /// launch, empty. That is deliberately harmless: `attach` and `createFresh` produce identical
    /// arguments, and tmux itself resolves which one actually happens. A pane whose session was
    /// killed behind our back therefore gets a fresh shell rather than an error, which is the
    /// requirement.
    public static func decide(
        workspaceID: String,
        paneID: String,
        persistenceEnabled: Bool,
        tmuxAvailable: Bool,
        existingSessions: Set<String>
    ) -> TerminalStartDecision {
        guard persistenceEnabled, tmuxAvailable else { return .inProcess }
        let name = sessionName(workspaceID: workspaceID, paneID: paneID)
        return existingSessions.contains(name) ? .attach(session: name) : .createFresh(session: name)
    }

    // MARK: - The orphan rule

    /// Sessions that nothing in Bloom can ever reach again.
    ///
    /// A session belongs to exactly one pane, and a pane is reachable only through a terminal tab
    /// of a workspace that is still in the database. So the rule is reachability, not age: anything
    /// whose pane id is no longer among the live panes is gone for good and is killed.
    ///
    /// Age would be the wrong rule. A `npm run dev` left alone for a fortnight is precisely what
    /// this feature exists to keep, and a session abandoned four seconds ago by a crash is precisely
    /// what it should not keep.
    ///
    /// This is a net, not the primary path. Closing a pane, closing a tab and archiving a workspace
    /// each kill their sessions on the spot; the sweep catches only what a crash, a `kill -9` or an
    /// edit outside Bloom left behind.
    /// The panes a sweep should count as reachable.
    ///
    /// With the setting off, none are. No pane will attach to tmux on the next launch, so a session
    /// still sitting on the socket is something nothing in the app will ever come back for, and
    /// leaving it there would hold its processes for as long as the machine is up. Turning the
    /// setting off therefore means the shells go, which is what off has to mean.
    public static func reachablePanes(_ panes: Set<String>, persistenceEnabled: Bool) -> Set<String> {
        persistenceEnabled ? panes : []
    }

    public static func orphans(sessions: [String], livePaneIDs: Set<String>) -> [String] {
        // Both sides are put through the same fold before they are compared. A pane id whose name
        // changed on its way into a session name would otherwise read as unreachable, and this
        // function kills what it returns.
        let live = Set(livePaneIDs.map(sanitized))
        return sessions.filter { name in
            guard let pane = paneID(ofSessionName: name) else { return false }
            return !live.contains(pane)
        }
    }

    // MARK: - Teardown

    /// Every live session belonging to one workspace.
    ///
    /// This is what archiving kills, whatever the persistence setting says. The setting decides
    /// whether a shell may outlive a quit; it never decides whether a shell may outlive the worktree
    /// it is standing in, because that worktree is about to be deleted from under it.
    ///
    /// Matching on the name rather than walking tabs and split layouts is the point: a pane whose
    /// tab was never loaded this launch, or whose split layout was lost, still has its session
    /// killed. Nothing running is allowed to depend on Bloom having remembered it.
    public static func sessions(ofWorkspace workspace: String, in sessions: [String]) -> [String] {
        let owner = sanitized(workspace)
        return sessions.filter { workspaceID(ofSessionName: $0) == owner }
    }

    /// `list-sessions -F '#{session_name}'` output. An empty result is also what tmux prints to
    /// stderr when no server is running, so the caller can ignore the exit status entirely.
    public static func parseSessionList(_ output: String) -> [String] {
        output
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    // MARK: - Configuration

    /// The server configuration, written to disk and passed with `-f`.
    ///
    /// Everything here exists to stop tmux from being noticed. No status line, no prefix key and no
    /// key bindings mean none of the user's keystrokes are ever swallowed on their way to the
    /// shell. `escape-time 0` is the one that is felt if it is missing: without it tmux waits to
    /// see whether an Escape starts a sequence, and vim feels broken.
    ///
    /// The mouse is the exception, and it is on for a reason. A tmux client puts the outer terminal
    /// into its alternate screen, which freezes SwiftTerm's own scrollback, so with the mouse off a
    /// scroll wheel would do nothing at all. On, the wheel scrolls tmux's history instead and the
    /// user cannot tell the difference. `set-clipboard on` is what keeps a drag-selection landing
    /// on the macOS pasteboard: SwiftTerm implements OSC 52, so tmux's copy reaches it.
    public static func configuration(defaultShell: String) -> String {
        """
        # Written by Bloom on every launch. Edits will be overwritten.
        #
        # This file configures a private tmux server that holds one shell per Bloom terminal pane.
        # It is not your tmux configuration and does not affect your own sessions.

        set -g default-shell "\(defaultShell)"
        set -g default-terminal "xterm-256color"
        set -ga terminal-features ",xterm-256color:RGB"
        set -g escape-time 0
        set -g history-limit 50000
        set -g status off
        set -g mouse on
        set -g set-clipboard on
        set -g focus-events on
        set -g set-titles off
        set -g bell-action none
        set -g destroy-unattached off
        set -g renumber-windows on
        set -g prefix None
        set -g prefix2 None
        unbind-key -a -T prefix

        """
    }
}

/// One resolved tmux binary on one private socket, and every command line Bloom sends it.
///
/// A value rather than a singleton so the tests can build one without a tmux on the machine.
public struct TmuxCommand: Sendable, Equatable {
    public let executable: String
    public let socketName: String
    public let configPath: String

    public init(executable: String, socketName: String, configPath: String) {
        self.executable = executable
        self.socketName = socketName
        self.configPath = configPath
    }

    /// `-u` forces UTF-8 rather than inferring it from a LANG that a GUI-launched app may not have
    /// inherited. `-f` is read only when the server starts, which is why `sourceConfiguration`
    /// exists for the case where it is already up.
    public var globalArguments: [String] {
        ["-L", socketName, "-f", configPath, "-u"]
    }

    public func arguments(_ tail: [String]) -> [String] {
        globalArguments + tail
    }

    /// The command a pane's pty actually execs.
    ///
    /// `-A` attaches to the session when it exists and creates it otherwise, which is the whole
    /// reattach-or-start-fresh rule in one flag. `-D` detaches any client that is somehow still
    /// attached, so a leftover client from a crashed launch cannot shrink the pane to its old size.
    /// `-c` and `-e` are read only when the session is created, so a restored session keeps the
    /// directory and environment it was born with.
    public func attachOrCreate(
        session: String,
        directory: String,
        environment: [String: String]
    ) -> [String] {
        var tail = ["new-session", "-A", "-D", "-s", session, "-c", directory]
        for key in environment.keys.sorted() {
            tail.append("-e")
            tail.append("\(key)=\(environment[key]!)")
        }
        return arguments(tail)
    }

    public func killSession(_ session: String) -> [String] {
        arguments(["kill-session", "-t", "=" + session])
    }

    public var listSessions: [String] {
        arguments(["list-sessions", "-F", "#{session_name}"])
    }

    /// Re-applies the configuration to a server that was already running when Bloom launched,
    /// which is how a changed option reaches sessions started by yesterday's build.
    public var sourceConfiguration: [String] {
        arguments(["source-file", configPath])
    }
}
