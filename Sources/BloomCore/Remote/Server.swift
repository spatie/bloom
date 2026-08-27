import Foundation

/// How a server last answered.
///
/// Five, and the two that are not obvious are the ones worth having. `unknown` is a row that has
/// been added and never looked at, which is a real state and not a stand-in for `unreachable`: the
/// Add field writes a row before anything has been asked, so that a server whose first probe hangs
/// is still in the list when the user comes back. `incomplete` is reachable and not usable, which
/// is a server with no git or no Python, and it is kept apart from `unreachable` because the fix
/// is a package manager rather than a network.
///
/// Written only by `Store.recordProbe`, which is why the property on `Server` is `internal(set)`.
/// A state is what a probe found, and a state set by anything that did not just probe is a claim
/// about a machine nobody looked at. Same reasoning as `Workspace.state`, and the same shape.
public enum ServerState: String, Sendable, Codable, CaseIterable, Hashable {
    /// Added, never asked.
    case unknown
    /// A probe is in flight. Never persisted for long: it is written when the probe starts so a
    /// window opened elsewhere sees the same spinner, and overwritten when it lands.
    case probing
    /// Reachable, has what it needs, and `bloomd` on it is the version this Bloom ships.
    case ready
    /// Reachable, and something it needs is not there.
    case incomplete
    /// `ssh` did not get there. See `SSHFailure` for which of the several ways.
    case unreachable

    /// Whether a row should read as a problem rather than as a note. `unknown` and `probing` are
    /// neither: nothing has been claimed about them yet.
    public var isSettled: Bool {
        switch self {
        case .unknown, .probing: false
        case .ready, .incomplete, .unreachable: true
        }
    }

    public var title: String {
        switch self {
        case .unknown: "Not checked"
        case .probing: "Checking"
        case .ready: "Ready"
        case .incomplete: "Needs setting up"
        case .unreachable: "Unreachable"
        }
    }
}

/// One server the user has added.
///
/// The table behind it is called `hosts`, which is what SSH calls the thing and what
/// `~/.ssh/known_hosts` calls it, and the type is called `Server`, which is what the person adding
/// one calls it. The two names are deliberate rather than an oversight.
///
/// **There is no credential column and there never will be.** Bloom shells out to the user's own
/// `ssh`, which reads their config, their agent and their keys. What is stored here is a
/// destination, a label, and what the last look found.
public struct Server: Identifiable, Sendable, Hashable, Codable {
    public let id: ServerID
    /// What the row is called. Seeded from the host name and renameable, because a person with
    /// four VPSes calls them by what they do rather than by their DNS.
    public var label: String
    public var destination: SSHDestination
    public internal(set) var state: ServerState
    /// One sentence about the state, from `ServerVerdict`. Empty when there is nothing to add.
    public internal(set) var detail: String
    /// What `bloomd` on that server reported at the end of the last checkup.
    public internal(set) var bloomdVersion: String?
    public var sortOrder: Int
    public let createdAt: Date
    public internal(set) var probedAt: Date?

    public init(
        id: ServerID = .new(),
        label: String,
        destination: SSHDestination,
        sortOrder: Int = 0,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.label = label
        self.destination = destination
        self.state = .unknown
        self.detail = ""
        self.bloomdVersion = nil
        self.sortOrder = sortOrder
        self.createdAt = createdAt
        self.probedAt = nil
    }

    /// The initialiser the store reads a row back through. Internal, for the reason
    /// `Workspace.init` is: a public one taking a state is a public way to claim a machine is
    /// ready without having looked at it.
    init(
        id: ServerID,
        label: String,
        destination: SSHDestination,
        state: ServerState,
        detail: String,
        bloomdVersion: String?,
        sortOrder: Int,
        createdAt: Date,
        probedAt: Date?
    ) {
        self.id = id
        self.label = label
        self.destination = destination
        self.state = state
        self.detail = detail
        self.bloomdVersion = bloomdVersion
        self.sortOrder = sortOrder
        self.createdAt = createdAt
        self.probedAt = probedAt
    }
}
