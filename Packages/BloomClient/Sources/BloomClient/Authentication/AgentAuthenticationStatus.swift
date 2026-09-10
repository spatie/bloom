import Foundation

/// CLI presence and authentication are separate facts. Unknown permits providers whose login
/// cannot be inspected noninteractively; only a definite missing login blocks a turn.
public struct AgentAuthenticationStatus: Codable, Sendable, Equatable {
    public enum State: String, Codable, Sendable { case ready, signInRequired, unavailable, unknown }
    public var agent: AgentKind
    public var state: State
    public init(agent: AgentKind, state: State) { self.agent = agent; self.state = state }
    public var requiresSignIn: Bool { state == .signInRequired }
    public var message: String {
        switch state {
        case .ready: "\(agent.label) has a saved sign-in on this server."
        case .signInRequired: "Sign in to \(agent.label) on this server before sending a prompt. Your draft has been kept."
        case .unavailable: "\(agent.label) is not installed on this server."
        case .unknown: "\(agent.label) authentication could not be checked before starting."
        }
    }

    /// Error actions classify authentication failures, never an arbitrary occurrence of a status
    /// number in an agent's answer or a workspace URL. Call only for an actual failed operation.
    public static func isSignInFailure(_ text: String) -> Bool {
        let value = text.lowercased()
        return value.contains("sign in to") && value.contains("on this server")
            || value.contains("not logged in") || value.contains("not authenticated")
            || value.contains("authentication required") || value.contains("authentication_error")
            || value.contains("invalid_api_key") || value.contains("invalid api key")
            || value.contains("token has expired") || value.contains("token expired")
            || value.contains("refresh token") && (value.contains("expired") || value.contains("invalid") || value.contains("reused"))
            || value.contains("401 unauthorized") || value.contains("401: unauthorized")
            || value.contains("401") && (value.contains("unauthorized") || value.contains("authentication"))
    }
}

/// A definite preflight refusal, distinct from a provider failure after a turn was delivered.
public struct AgentAuthenticationRequired: Error, LocalizedError, Sendable {
    public let agent: AgentKind
    public init(agent: AgentKind) { self.agent = agent }
    public var errorDescription: String? { AgentAuthenticationStatus(agent: agent, state: .signInRequired).message }
}
