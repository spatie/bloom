import Foundation
import Synchronization
#if os(Linux)
import Glibc
#endif

/// A separate data directory and a process lock prevent the server from sharing live ownership
/// with another server. The lock is acquired before SQLite recovery or socket replacement.
public final class ServerDaemon: Sendable {
    public let runtime: ServerRuntime
    public let socketPath: String
    public let bridge: BridgeServer
    private let lock: ServerLock
    private let listener: UnixSocketListener
    private let connections: ServerConnections

    private init(runtime: ServerRuntime, socketPath: String, bridge: BridgeServer, lock: ServerLock, listener: UnixSocketListener, connections: ServerConnections) {
        self.runtime = runtime
        self.socketPath = socketPath
        self.bridge = bridge
        self.lock = lock
        self.listener = listener
        self.connections = connections
    }

    public static func start(
        authentication: @escaping ServerAgentAuthentication.Check = ServerAgentAuthentication.inspect,
        directory: String,
        gatewayGroupID: UInt32? = nil,
        installedAgents: @escaping ServerRuntime.AgentDiscovery = ServerAgentAvailability.installed,
        makeRunner: ServerRuntime.RunnerFactory? = nil,
        maintenanceTrial: Bool = false
    ) async throws -> ServerDaemon {
        let lock = try ServerLock(directory: directory)
        let database = databasePath(directory: directory)
        let store = try Store(path: database)
        try await store.resetRunningSessions()
        _ = try await store.abandonPendingPermissionAsks()
        let runtime = ServerRuntime(store: store, authentication: authentication, gatewayGroupID: gatewayGroupID, installedAgents: installedAgents, makeRunner: makeRunner, maintenanceTrial: maintenanceTrial)
        do {
            let bridge = try await runtime.startBridge(socketPath: mcpSocketPath(directory: directory))
            if !maintenanceTrial { try await runtime.restoreQueuedPrompts() }
            let socketPath = try socketPath(directory: directory)
            let connections = ServerConnections { request in await runtime.respond(to: request) }
            let listener = try UnixSocketListener(path: socketPath, groupID: gatewayGroupID) { connections.accept($0) }
            return ServerDaemon(runtime: runtime, socketPath: socketPath, bridge: bridge, lock: lock, listener: listener, connections: connections)
        } catch {
            await runtime.shutdown()
            throw error
        }
    }

    deinit {
        listener.stop()
        connections.stop()
        let runtime = runtime, ownership = lock, connections = connections
        Task {
            await runtime.shutdown()
            await connections.drain()
            ownership.release()
        }
    }

    public static func mcpSocketPath(directory: String) throws -> String {
        // A dedicated directory can be mounted into a container without exposing other sockets.
        let path = "/tmp/bloom-mcp-" + TmuxSessions.fingerprint(databasePath(directory: directory))
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory,
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
              ((attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0o777) & 0o077 == 0 else {
            throw ServerFailure("The server MCP directory must be private and owned by this account.")
        }
        return try BridgeSocketPath.derive(databasePath: databasePath(directory: directory), directory: path)
    }

    public static func databasePath(directory: String) -> String {
        URL(fileURLWithPath: directory).standardizedFileURL.resolvingSymlinksInPath()
            .appendingPathComponent("server.sqlite").path
    }

    public static func socketPath(directory: String) throws -> String {
        guard directory.hasPrefix("/"), !directory.contains("\0") else {
            throw ServerFailure("The server data directory must be an absolute path.")
        }
        return try BridgeSocketPath.derive(databasePath: databasePath(directory: directory), directory: "/tmp")
    }

    public func shutdown() async {
        listener.stop()
        connections.stop()
        await runtime.shutdown()
        await connections.drain()
        lock.release()
    }
}

private final class ServerLock: Sendable {
    private let descriptor: Mutex<Int32?>

    init(directory: String) throws {
        guard directory.hasPrefix("/") else { throw ServerFailure("The server data directory must be an absolute path.") }
        try FileManager.default.createDirectory(
            atPath: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        let attributes = try FileManager.default.attributesOfItem(atPath: directory)
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0o777
        let owner = (attributes[.ownerAccountID] as? NSNumber)?.uint32Value
        guard permissions & 0o077 == 0, owner == getuid() else {
            throw ServerFailure("Use a dedicated data directory owned by you with permissions 700.")
        }
        let path = URL(fileURLWithPath: directory).appendingPathComponent("server.lock").path
        let opened = open(path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard opened >= 0 else { throw ServerFailure("Cannot open the server lock in \(directory).") }
        guard flock(opened, LOCK_EX | LOCK_NB) == 0 else {
            close(opened)
            throw ServerFailure("A Bloom server already owns this data directory.")
        }
        descriptor = Mutex(opened)
    }

    func release() {
        let opened = descriptor.withLock { value in
            let previous = value
            value = nil
            return previous
        }
        if let opened { close(opened) }
    }

    deinit { release() }
}
