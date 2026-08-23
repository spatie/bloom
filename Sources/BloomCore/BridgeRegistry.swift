import Foundation
import Synchronization

/// Token to identity, for one launch of the app.
///
/// Minted by Bloom and handed to the CLI through the shim's environment, never claimed by the
/// agent. That is what lets every tool be implicitly scoped: no call carries "my workspace id",
/// so there is nothing to forge and nothing to go stale when a chat is replaced or a workspace is
/// renamed.
///
/// Held in memory and nowhere else, deliberately. A token is only ever wanted by a process this
/// launch started, and every argv that carries one is recomputed at each process start
/// (`AgentRunner.launch`, and a fresh `CodexClient.Configuration` per connect), so a session
/// resumed days later gets a new token for free. A token written to disk would be a token that
/// outlived the process it identified.
///
/// A `Mutex` rather than an actor, because minting has to be answerable from the synchronous
/// main-actor code that builds a runner, and an actor would make that an `await` in a place that
/// cannot have one.
public final class BridgeRegistry: Sendable {
    private struct State {
        var identities: [String: BridgeIdentity] = [:]
        /// So a re-mint for the same session retires the token it replaces, rather than leaving
        /// every token this launch ever made valid until the app quits.
        var tokens: [SessionID: String] = [:]
    }

    private let state = Mutex(State())
    private let makeToken: @Sendable () -> String

    /// `makeToken` is injectable so a test can pin what lands in argv. Production mints 256 bits
    /// from the system generator: a token is not a secret, but a guessable one would let a process
    /// that never saw the config file speak as a session it has nothing to do with.
    public init(makeToken: @escaping @Sendable () -> String = BridgeRegistry.randomToken) {
        self.makeToken = makeToken
    }

    public static let randomToken: @Sendable () -> String = {
        var bytes = [UInt8](repeating: 0, count: 32)
        for index in bytes.indices { bytes[index] = UInt8.random(in: 0...255) }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// A fresh token for this session, retiring any earlier one.
    @discardableResult
    public func mint(sessionID: SessionID, workspaceID: WorkspaceID, role: BridgeRole) -> String {
        let token = makeToken()
        state.withLock { state in
            if let previous = state.tokens[sessionID] { state.identities[previous] = nil }
            state.tokens[sessionID] = token
            state.identities[token] = BridgeIdentity(
                sessionID: sessionID,
                workspaceID: workspaceID,
                role: role
            )
        }
        return token
    }

    public func identity(forToken token: String) -> BridgeIdentity? {
        state.withLock { $0.identities[token] }
    }

    /// Drops a session's token, for a chat that has been archived or a runner that has stopped for
    /// good. Not called on every process exit: the CLI is restarted within one session all the
    /// time, and the token has to outlive that.
    public func retire(sessionID: SessionID) {
        state.withLock { state in
            if let token = state.tokens.removeValue(forKey: sessionID) { state.identities[token] = nil }
        }
    }

    /// The sessions holding a token this launch minted. What the config sweep asks, because a
    /// file for a session not in here can no longer be used by anything: its token was either
    /// retired or minted by a launch that has ended.
    public var liveSessions: Set<SessionID> {
        state.withLock { Set($0.tokens.keys) }
    }

    public var count: Int {
        state.withLock { $0.identities.count }
    }
}
