import Foundation

/// What the New Workspace window shows while a server is creating a workspace, and when it stops
/// believing the server is still there.
///
/// **The bug.** Pressing Create for a server project greyed out the window's controls and put a
/// small spinner in its top right corner, and that was all it ever did. The server's reply used to
/// wait for the whole setup script, and the owner's project builds a Docker image from source on a
/// two core server, so the window sat there for many minutes with no words, no way to leave it
/// and no way to tell a slow build from a dead connection. The server now replies as soon as the
/// worktree exists, but fetching a pull request into a large repository still takes a while, and a
/// connection can still die with a request in flight.
///
/// **Two rules, and neither is a timeout on the work.** A quiet period first, so an ordinary
/// create that answers in a second never flashes a second screen. Then a liveness rule that asks
/// whether the server has answered anything recently, not whether the create has finished: the
/// client reads the catalogue every three seconds on the same connection, and a server that keeps
/// answering those is a server that is working, however long its `git fetch` takes. Only silence,
/// or a connection that has gone, is "not responding".
public enum RemoteCreationWait {
    public enum Phase: Sendable, Equatable {
        /// Too soon to say anything. The window keeps its small spinner.
        case quiet
        /// The server is answering and the create has not finished yet.
        case waiting
        /// The connection is gone, or nothing has come back from the server for too long.
        case notResponding
    }

    /// Long enough that a create which is going to answer promptly never shows a second screen.
    public static let quietPeriod: TimeInterval = 2
    /// Comfortably more than the poll's three second catalogue interval plus a slow reply, so one
    /// late answer on a busy server is not reported as a dead one. The catalogue read itself gives
    /// up after fifteen seconds and drops the connection, which is the other way this is reached.
    public static let silenceLimit: TimeInterval = 20

    /// - Parameters:
    ///   - lastHeardAt: the last time any reply arrived from the server on this connection.
    public static func phase(startedAt: Date, now: Date, isConnected: Bool, lastHeardAt: Date?) -> Phase {
        guard now.timeIntervalSince(startedAt) >= quietPeriod else { return .quiet }
        guard isConnected else { return .notResponding }
        // Measured from Create at the earliest, so a connection that was merely idle before the
        // button was pressed is not already counted as silent.
        let heard = max(lastHeardAt ?? startedAt, startedAt)
        return now.timeIntervalSince(heard) > silenceLimit ? .notResponding : .waiting
    }

    /// How long the server has been silent, for the sentence that says so. Zero while it is not.
    public static func silence(startedAt: Date, now: Date, lastHeardAt: Date?) -> TimeInterval {
        max(0, now.timeIntervalSince(max(lastHeardAt ?? startedAt, startedAt)))
    }

    /// What the server is doing, in the terms of what was asked for. It is not progress reported by
    /// the server, and it does not pretend to be: it names the work the request implies, so the
    /// sentence is true for the whole of the wait.
    public static func activity(checkout: WorkspaceCheckout?, baseBranch: String) -> String {
        switch checkout {
        case .pullRequest(let pull):
            "Fetching pull request #\(pull.number) (\(pull.headRefName)) and checking it out in a new worktree."
        case .branch(let branch):
            "Fetching \(branch.name) and checking it out in a new worktree."
        case nil:
            baseBranch.isEmpty
                ? "Creating a new branch and its worktree."
                : "Creating a new branch from \(baseBranch) and its worktree."
        }
    }

    /// Minutes and seconds, `0:07` or `12:40`, because this is a clock the reader is watching
    /// rather than a duration being reported, and a clock should not change width every minute.
    public static func clock(_ seconds: TimeInterval) -> String {
        let whole = max(0, Int(seconds))
        let hours = whole / 3600
        let minutes = whole % 3600 / 60
        let rest = whole % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, rest)
            : String(format: "%d:%02d", minutes, rest)
    }
}
