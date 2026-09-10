import Foundation

public enum RemoteConnectionPhase: Sendable, Equatable {
    case disconnected, connecting, connected, reconnecting, offline, suspended
}

/// Transport failures never own a conversation or its draft. Clients own retry scheduling;
/// this shared state supplies bounded backoff and the same recovery language.
public struct RemoteConnectionRecovery: Sendable, Equatable {
    public private(set) var phase: RemoteConnectionPhase = .disconnected
    public private(set) var failureCount = 0
    public private(set) var lastError: String?
    public private(set) var hasConnected = false
    public private(set) var automaticallyRetries = false
    public init() {}

    public var retryDelaySeconds: Int { min(30, 1 << min(failureCount, 5)) }
    public var canRetry: Bool { phase == .offline || phase == .disconnected || phase == .suspended }
    public var title: String {
        switch phase {
        case .disconnected: "Server disconnected"
        case .connecting: "Connecting to server"
        case .connected: "Connected"
        case .reconnecting: "Reconnecting to server"
        case .offline: "Connection interrupted"
        case .suspended: "Connection paused"
        }
    }
    public var detail: String {
        switch phase {
        case .offline where automaticallyRetries:
            "Bloom will try again automatically. Your conversation and draft stay here."
        case .offline:
            "Check the server connection, then retry. Your conversation and draft stay here."
        case .connecting, .reconnecting:
            "Catching up with the server. Unsent drafts are not sent automatically."
        case .disconnected, .suspended:
            "Work runs on the server independently. Reconnect to see its latest progress."
        case .connected: ""
        }
    }

    public mutating func beginAttempt() { phase = hasConnected ? .reconnecting : .connecting }
    public mutating func connected() {
        phase = .connected; hasConnected = true; failureCount = 0; lastError = nil; automaticallyRetries = true
    }
    public mutating func failed(message: String, automaticallyRetry: Bool = true) {
        phase = .offline; failureCount = min(failureCount + 1, 30)
        lastError = message; automaticallyRetries = automaticallyRetry
    }
    public mutating func disconnect() { phase = .disconnected; automaticallyRetries = false; failureCount = 0 }
    public mutating func suspend() { phase = .suspended; automaticallyRetries = false }

    /// Explicit identity, account and compatibility failures cannot be fixed by polling harder.
    public static func requiresUserAction(_ message: String) -> Bool {
        let value = message.lowercased()
        return ["permission denied (publickey", "permission denied (password", "permission denied (keyboard-interactive",
                "host key verification failed", "remote host identification has changed",
                "signing failed", "authentication required", "sign in", "sign-in",
                "server refused this device's ssh key", "server's ssh host key has changed", "verify the server's ssh fingerprint", "verify this server's ssh fingerprint",
                "incompatible bloom server protocol", "update bloom server and the app", "not a bloom server"]
            .contains { value.contains($0) }
    }
}
