import Foundation

/// When a client asks its server whether updates exist, without anybody opening Updates.
///
/// The question goes to the supervisor's ordinary `inspect`, which already caches its GitHub
/// lookup for fifteen minutes, so no client ever calls GitHub itself and a fleet of clients costs
/// the release API one request per server. The interval is hours because an update is reviewed and
/// installed by a person; a check every few seconds would only show the same answer sooner. A
/// failed request retries sooner than that, because it says nothing about the server's releases.
public struct ServerUpdateCheckSchedule: Sendable, Equatable {
    public enum Outcome: Sendable, Equatable {
        /// Components were read with maintenance access.
        case checked
        /// The server answered, but cannot say: no supervisor, or this client has no key yet.
        case unavailable
        /// The request did not complete, so the next attempt comes after `retryInterval`.
        case failed
    }

    public let interval: TimeInterval
    public let retryInterval: TimeInterval
    public private(set) var scope: String?
    public private(set) var lastAttempt: Date?
    public private(set) var lastOutcome: Outcome?

    public init(interval: TimeInterval = 6 * 60 * 60, retryInterval: TimeInterval = 20 * 60) {
        self.interval = interval; self.retryInterval = retryInterval
    }

    /// A scope names one connection to one server. A new scope is a new connection, which is
    /// checked straight away: that is the "on connect" check, with no separate trigger to forget.
    public static func scope(serverID: String?, connectionGeneration: Int) -> String? {
        guard let serverID, !serverID.isEmpty else { return nil }
        return serverID + "#" + String(connectionGeneration)
    }

    /// `busy` is anything that already talks to the maintenance session or replaces the server,
    /// so a background check never queues behind a review or races an administrator update.
    public func isDue(scope: String?, connected: Bool, busy: Bool, now: Date = Date()) -> Bool {
        guard connected, !busy, let scope else { return false }
        guard scope == self.scope, let lastAttempt else { return true }
        let wait = lastOutcome == .failed ? retryInterval : interval
        return now.timeIntervalSince(lastAttempt) >= wait
    }

    public mutating func record(_ outcome: Outcome, scope: String, at date: Date = Date()) {
        self.scope = scope; lastAttempt = date; lastOutcome = outcome
    }

    public static func outcome(authorized: Bool, capability: Bool?, failure: ServerMaintenanceFailure?) -> Outcome {
        if capability == false || failure?.code == "unsupported" || failure?.isAuthorizationFailure == true { return .unavailable }
        if failure != nil || capability == nil { return .failed }
        return authorized ? .checked : .unavailable
    }
}

/// Whether to tell somebody an update exists, and in what words.
///
/// Quiet by design: nothing is shown without maintenance access, because an unauthorised client
/// reads no components, and nothing is shown while a job is running, because the job's own
/// progress is the better answer. A component whose latest job already installed the advertised
/// version is left out too, since the supervisor's list is only re-read on the next check.
public struct ServerUpdateNotice: Sendable, Equatable {
    /// Updates the supervisor can install after review.
    public var updates: [ServerMaintenanceComponent]
    /// Newer releases that need the Mac's administrator update instead.
    public var incompatible: [ServerMaintenanceComponent]

    public var count: Int { updates.count + incompatible.count }

    public static func resolve(authorized: Bool, capability: Bool?, components: [ServerMaintenanceComponent],
                               jobs: [ServerMaintenanceJob]) -> Self? {
        guard authorized, capability == true, !jobs.contains(where: \.isActive) else { return nil }
        func announced(_ component: ServerMaintenanceComponent) -> Bool {
            guard let available = component.availableVersion, !available.isEmpty, available != component.installedVersion else { return false }
            let latest = jobs.filter { $0.component == component.id }.max { $0.updatedAt < $1.updatedAt }
            return !(latest?.phase == .succeeded && latest?.targetVersion == available)
        }
        let updates = components.filter { $0.canUpdate && !$0.isIncompatible && announced($0) }
        let incompatible = components.filter { $0.isIncompatible && announced($0) }
        guard !updates.isEmpty || !incompatible.isEmpty else { return nil }
        return Self(updates: updates, incompatible: incompatible)
    }

    /// The component a single "Review Update…" should open: the server first, as it matters most.
    public var primary: ServerMaintenanceComponent? { updates.first { $0.id == .server } ?? updates.first }

    /// Short enough for a sidebar.
    public var headline: String { count == 1 ? "Update available" : "\(count) updates available" }

    /// One sentence per component, for Server Settings and help tags.
    public var summary: String {
        (updates.map { "\($0.title) \($0.availableVersion ?? "") is available." }
            + incompatible.map { "\($0.title) \($0.availableVersion ?? "") needs Update Server… from this Mac." })
            .joined(separator: " ")
    }
}

public extension ServerMaintenanceSession {
    var updateNotice: ServerUpdateNotice? {
        ServerUpdateNotice.resolve(authorized: authorized, capability: capability, components: components, jobs: jobs)
    }
}
