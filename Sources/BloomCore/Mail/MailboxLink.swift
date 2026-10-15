import Foundation

/// Where the app's connection to Mailpit stands.
public enum MailboxConnection: Equatable, Sendable {
    /// Not looking: switched off, or not started.
    case idle
    case connecting
    /// The websocket is open and the list is following it.
    case live
    /// The last attempt failed, and another is on its way.
    case disconnected(MailpitFailure)
}

/// Every decision the loop that looks for Mailpit takes, as a value the loop drives.
///
/// The loop itself is the app's `Mailbox`: it asks `info`, opens the websocket and sleeps, none of
/// which a test can do. What it decides between those steps is here, because it is the part most
/// likely to be broken by the next change and the part that already has been once: a password
/// prompt counts as Mailpit answering, the failure count starts again after a connection that
/// worked, and the wait before the next look is the slow search until Mailpit has answered once
/// and the quick backoff after. Each step is one call, the loop does what the answer says, and the
/// tests walk the same calls.
public struct MailboxLink: Equatable, Sendable {
    public private(set) var presence: MailboxPresence
    public private(set) var connection: MailboxConnection = .idle
    /// Attempts in a row that have failed, which is what the backoff is measured in.
    private var failures = 0

    /// What the loop does after a look.
    public enum Next: Equatable, Sendable {
        /// Mailpit answered: open the websocket and follow it until it drops.
        case listen
        /// Mailpit did not: sleep this long and look again.
        case wait(Duration)
    }

    public init(isEnabled: Bool) {
        presence = MailboxPresence(isEnabled: isEnabled)
    }

    /// Settings changed, so whatever was known about the old address goes with it.
    public mutating func reconfigure(isEnabled: Bool) {
        presence.reconfigure(isEnabled: isEnabled)
        startLooking()
    }

    /// A new loop for the same settings: a retry, or Bloom coming to the front.
    public mutating func startLooking() {
        failures = 0
        connection = presence.isEnabled ? .connecting : .idle
    }

    /// No loop at all: switched off, or an address that is not one.
    public mutating func stopLooking() {
        failures = 0
        connection = .idle
    }

    /// Whether coming to the front should start a new loop. Not while one is already connected or
    /// connecting, which would drop a working socket for nothing.
    public var looksAgainOnActivation: Bool {
        presence.isEnabled && connection != .live && connection != .connecting
    }

    /// What `info` said.
    ///
    /// A password prompt still counts as Mailpit answering. The Mail destination explains it;
    /// anything else that fails is not counted as Mailpit answering.
    public mutating func probed(_ answer: Result<MailpitInfo, MailpitFailure>) -> Next {
        switch answer {
        case .success:
            presence.answered()
            failures = 0
            return .listen
        case .failure(.unauthorised):
            presence.answered()
            return failed(.unauthorised)
        case .failure(let failure):
            return failed(failure)
        }
    }

    /// The first page has been read over an open socket: the list is following Mailpit now.
    public mutating func listening() {
        connection = .live
    }

    /// The socket closed, or the first page over it could not be read. Counted as one failure
    /// rather than added to the ones before, because the connection just before it worked, and a
    /// Mailpit being restarted is back within a second or two.
    public mutating func dropped(_ failure: MailpitFailure) -> Duration {
        failures = 0
        guard case .wait(let pause) = failed(failure) else { return .zero }
        return pause
    }

    private mutating func failed(_ failure: MailpitFailure) -> Next {
        failures += 1
        connection = .disconnected(failure)
        return .wait(
            presence.isSearching
                ? MailboxPresence.searchInterval
                : MailboxPresence.reconnectDelay(afterFailures: failures)
        )
    }

}
