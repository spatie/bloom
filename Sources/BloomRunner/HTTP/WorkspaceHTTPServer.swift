import BloomCore
import BloomProtocol
import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdWebSocket
import NIOCore

/// Everything Bloom Runner answers on its port, behind Caddy.
///
/// | Path | What |
/// | --- | --- |
/// | `POST /_bloom/v1/rpc` | a command, session token |
/// | `GET /_bloom/v1/events` | server-sent events, session token |
/// | `POST /_bloom/v1/streams/{id}/token` | a fresh token for an open stream |
/// | `GET /_bloom/v1/terminal?name=` | WebSocket, `auth` first frame |
/// | `GET /_bloom/preview/enter?token=` | the preview cookie exchange, preview token |
/// | `GET /_bloom/preview/check` | Caddy's forward_auth for the preview |
/// | `POST /_bloom/v1/control/*` | runbloom.app only, control token |
/// | `GET /_bloom/health` | unauthenticated, the version only |
public struct WorkspaceHTTPServer: Sendable {
    public struct Dependencies: Sendable {
        public var runtime: WorkspaceRuntime
        public var verifier: TokenVerifier
        public var gate: any RemoteTurnGate
        public var control: any MachineControl
        public var store: Store
        public var allowedOrigins: [String]
        public var version: String
        public var streams: EventStreams
        public var terminals: TerminalConnections
        /// Whether the terminal WebSocket is routed at all. A missing route is a refusal, and a
        /// client cannot tell it from a dropped connection, so switching it off leaves a client
        /// retrying rather than saying why.
        public var terminalsEnabled: Bool
        /// The project's services as the supervisor has them, for the page somebody sees when the
        /// preview has nothing to show.
        public var services: @Sendable () async -> [ServiceSupervisor.Status]
        /// Where the preview proxies, so the page that says the app is not answering can say what
        /// port it read.
        public var appPort: Int
        /// The ports Bloom itself holds, from `MachineLayout.reservedPorts`. Passed rather than
        /// restated, because both of them can be moved by the environment.
        public var reservedPorts: [Int]

        public init(runtime: WorkspaceRuntime, verifier: TokenVerifier, gate: any RemoteTurnGate, control: any MachineControl,
                    store: Store, allowedOrigins: [String], version: String, streams: EventStreams = EventStreams(),
                    terminals: TerminalConnections = TerminalConnections(), terminalsEnabled: Bool = true,
                    services: @escaping @Sendable () async -> [ServiceSupervisor.Status] = { [] },
                    appPort: Int = 3000,
                    reservedPorts: [Int] = []) {
            self.runtime = runtime
            self.verifier = verifier
            self.gate = gate
            self.control = control
            self.store = store
            self.allowedOrigins = allowedOrigins
            self.version = version
            self.streams = streams
            self.terminals = terminals
            self.terminalsEnabled = terminalsEnabled
            self.services = services
            self.appPort = appPort
            self.reservedPorts = reservedPorts
        }
    }

    public var streams: EventStreams { dependencies.streams }
    public var terminals: TerminalConnections { dependencies.terminals }
    let dependencies: Dependencies

    public init(dependencies: Dependencies) {
        self.dependencies = dependencies
    }

    func router() -> Router<WorkspaceRequestContext> {
        let router = Router(context: WorkspaceRequestContext.self)
        let version = dependencies.version
        router.get("/_bloom/health") { _, _ -> Response in
            WireResponses.json(["version": version])
        }
        RPCRoute.register(on: router, runtime: dependencies.runtime, verifier: dependencies.verifier)
        EventStreamRoute.register(on: router, runtime: dependencies.runtime, verifier: dependencies.verifier, streams: streams)
        ControlRoutes.register(on: router, verifier: dependencies.verifier, control: dependencies.control)
        PreviewRoutes.register(on: router, verifier: dependencies.verifier, sessions: PreviewSessions(store: dependencies.store, revocations: dependencies.verifier.revocations),
                               runtime: dependencies.runtime, services: dependencies.services,
                               appPort: dependencies.appPort, reservedPorts: dependencies.reservedPorts)
        return router
    }

    func webSocketRouter() -> Router<WorkspaceRequestContext> {
        let router = Router(context: WorkspaceRequestContext.self)
        if dependencies.terminalsEnabled {
            TerminalRoute.register(on: router, dependencies: .init(
                runtime: dependencies.runtime, verifier: dependencies.verifier,
                gate: dependencies.gate, connections: terminals
            ))
        }
        return router
    }

    static let idleTimeout: TimeAmount = .seconds(30)

    /// The application, listening on loopback only: Caddy is the one thing on the machine's URL.
    public func application(port: Int, host: String = "127.0.0.1",
                            onServerRunning: @escaping @Sendable (Int) async -> Void = { _ in }) -> some ApplicationProtocol {
        let responder = CORSResponder(wrapped: router().buildResponder(), allowedOrigins: Set(dependencies.allowedOrigins))
        return Application(
            responder: responder,
            // A connection that sends nothing, or nothing more after a reply, is closed after
            // thirty seconds rather than held for ever (L4 in the review of 19 September 2026).
            // An event stream is a request in progress, so its minutes of quiet are not idle.
            server: .http1WebSocketUpgrade(webSocketRouter: webSocketRouter(),
                                           configuration: .init(http1: .init(idleTimeout: Self.idleTimeout))),
            configuration: .init(address: .hostname(host, port: port), serverName: "bloom-runner"),
            onServerRunning: { channel in await onServerRunning(channel.localAddress?.port ?? port) }
        )
    }
}
