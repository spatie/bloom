import Foundation

/// Whether Mailpit has answered at the configured address, and how hard Bloom looks for it.
/// Mail stays in the sidebar while enabled. An answer changes the retry interval from a slow
/// discovery search to a short reconnect after a working connection. Changing address starts over.
public struct MailboxPresence: Equatable, Sendable {
    public private(set) var isEnabled: Bool
    public private(set) var hasAnswered = false

    public init(isEnabled: Bool) {
        self.isEnabled = isEnabled
    }

    /// Whether to keep knocking on a port that has never answered, every `searchInterval`.
    ///
    /// Only until the first answer. After that the websocket's own reconnect is doing the looking,
    /// and at its own pace: see `reconnectDelay`.
    public var isSearching: Bool { isEnabled && !hasAnswered }

    /// How often to look for a Mailpit that has not answered yet. Each look is one request to a
    /// port on this Mac, which costs nothing when nothing is listening.
    public static let searchInterval: Duration = .seconds(30)

    public mutating func answered() {
        guard isEnabled else { return }
        hasAnswered = true
    }

    /// Settings changed: switched off, switched on, or pointed somewhere else.
    public mutating func reconfigure(isEnabled: Bool) {
        self.isEnabled = isEnabled
        hasAnswered = false
    }

    /// How long to wait before reconnecting, after `failures` attempts in a row have failed.
    ///
    /// One second, doubling, held at thirty. A Mailpit being restarted is back within a couple of
    /// seconds, so the first retries find it quickly. One that has been stopped for the afternoon
    /// is asked twice a minute, which is the same pace as `searchInterval`.
    public static func reconnectDelay(afterFailures failures: Int) -> Duration {
        guard failures > 0 else { return .zero }
        let exponent = min(failures - 1, 5)
        return min(.seconds(1 << exponent), .seconds(30))
    }
}
