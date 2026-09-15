import Foundation

/// One workspace's setup as the server knows it right now: the state, the output so far, and when
/// the run began.
///
/// The catalogue already carries `setupState` and `setupLog`, but for every workspace at once and
/// every three seconds, which is a slow way to watch one Docker build and has no start time in it
/// to count from. A remote workspace in the middle of setup asks for this every second instead,
/// for itself alone. The server's own copy of the log is flushed to its row every 250 ms by
/// `SetupOutputBuffer`, so a second is the finest grain worth asking at.
public struct ServerSetupOutput: Codable, Sendable, Equatable {
    public var state: SetupState
    public var log: String
    /// When the run in progress, or the last one this server process watched, began. Nil after a
    /// restart, which is honest: the server did not see that run start.
    public var startedAt: Date?
    /// How long the last finished run took, when this server process watched all of it.
    public var durationMS: Int?

    public init(state: SetupState, log: String, startedAt: Date? = nil, durationMS: Int? = nil) {
        self.state = state
        self.log = log
        self.startedAt = startedAt
        self.durationMS = durationMS
    }
}

public extension Workspace {
    /// Take the server's setup state and log onto a client's copy of its row.
    ///
    /// The one write of `setupState` that does not go through `apply(_: SetupEvent)`, and it is
    /// not a transition: a remote row on the Mac is a mirror of a row the server's
    /// `SetupLifecycle` has already moved, and replaying events to reach the same state would be
    /// a second machine free to disagree with the first. State and log arrive together, which is
    /// the half of that rule that matters here.
    mutating func mirrorSetup(_ output: ServerSetupOutput) {
        setupState = output.state
        setupLog = output.log
    }
}
