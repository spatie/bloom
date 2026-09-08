import Foundation
#if os(Linux)
import Glibc
#endif

/// A separate data directory and a process lock prevent the server from sharing live ownership
/// with another server. The lock is acquired before SQLite recovery or socket replacement.
public final class ServerDaemon: Sendable {
    public let runtime: ServerRuntime
    public let socketPath: String
    private let lock: ServerLock
    private let listener: UnixSocketListener

    private init(runtime: ServerRuntime, socketPath: String, lock: ServerLock, listener: UnixSocketListener) {
        self.runtime = runtime
        self.socketPath = socketPath
        self.lock = lock
        self.listener = listener
    }

    public static func start(
        directory: String,
        makeRunner: @escaping ServerRuntime.RunnerFactory = { session, path, store in
            SessionRunnerFactory.make(session: session, workspacePath: path, store: store)
        }
    ) async throws -> ServerDaemon {
        let lock = try ServerLock(directory: directory)
        let database = databasePath(directory: directory)
        let store = try Store(path: database)
        try await store.resetRunningSessions()
        _ = try await store.abandonPendingPermissionAsks()
        let runtime = ServerRuntime(store: store, makeRunner: makeRunner)
        let socketPath = try socketPath(directory: directory)
        let listener = try UnixSocketListener(path: socketPath) { connection in
            Task { await serve(connection, runtime: runtime) }
        }
        return ServerDaemon(runtime: runtime, socketPath: socketPath, lock: lock, listener: listener)
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

    private static func serve(_ connection: UnixSocketConnection, runtime: ServerRuntime) async {
        defer { connection.close() }
        for await line in connection.lines {
            guard line.utf8.count <= 2_097_152,
                  let request = try? JSONDecoder().decode(ServerRequest.self, from: Data(line.utf8)) else { return }
            // A setup script can take minutes. Keep accepting reads and Stop commands while
            // it runs, and let the runtime own mutations even after this connection closes.
            Task {
                let reply = await runtime.respond(to: request)
                guard let data = try? JSONEncoder().encode(reply) else { return }
                connection.writeLine(String(decoding: data, as: UTF8.self))
            }
        }
    }

    public func shutdown() async {
        listener.stop()
        await runtime.shutdown()
    }
}

private final class ServerLock: Sendable {
    private let descriptor: Int32

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
        descriptor = open(path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw ServerFailure("Cannot open the server lock in \(directory).") }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            throw ServerFailure("A Bloom server already owns this data directory.")
        }
    }

    deinit { close(descriptor) }
}
