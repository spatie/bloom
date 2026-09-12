import Foundation
#if os(Linux)
import Glibc
#else
import Darwin
#endif

/// This socket is inherited from the trusted launcher, never selected by an RPC request.
/// Close-on-exec is set before any agents start so a child tool cannot keep or use the channel.
final class ServerMaintenanceControl: Sendable {
    struct Status: Codable, Sendable {
        var ready: Bool
        var busy: Bool
        var message: String?
    }
    private struct Request: Decodable { var id: String; var action: String }
    private struct Reply: Encodable { var id: String; var ready: Bool; var busy: Bool; var message: String? }
    let trialID: UUID?
    private let connection: UnixSocketConnection

    private init(descriptor: Int32, trialID: UUID?) {
        self.trialID = trialID
        connection = UnixSocketConnection(descriptor: descriptor)
    }

    static func inherited() throws -> ServerMaintenanceControl? {
        let environment = ProcessInfo.processInfo.environment
        guard let value = environment["BLOOM_MAINTENANCE_FD"] else { return nil }
        guard let descriptor = Int32(value), descriptor >= 3 else {
            throw ServerFailure("Invalid supervisor descriptor.")
        }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFSOCK),
              fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0 else {
            throw ServerFailure("The supervisor channel is not an inherited socket.")
        }
        let trial = environment["BLOOM_MAINTENANCE_TRIAL"]
        guard trial == nil || UUID(uuidString: trial ?? "") != nil else {
            throw ServerFailure("Invalid supervisor update identifier.")
        }
        unsetenv("BLOOM_MAINTENANCE_FD")
        unsetenv("BLOOM_MAINTENANCE_TRIAL")
        return Self(descriptor: descriptor, trialID: trial.flatMap(UUID.init(uuidString:)))
    }

    func run(runtime: ServerRuntime) async {
        var event = ["event": trialID == nil ? "ready" : "prepared"]
        event["jobID"] = trialID?.uuidString.lowercased()
        await send(event)
        for await line in connection.lines {
            guard !Task.isCancelled, line.utf8.count <= 4096,
                  let request = try? JSONDecoder().decode(Request.self, from: Data(line.utf8)),
                  UUID(uuidString: request.id) != nil else { break }
            let status: Status
            do { status = try await runtime.maintenanceControl(request.action) } catch {
                status = Status(ready: false, busy: true, message: error.localizedDescription)
            }
            await send(Reply(id: request.id, ready: status.ready, busy: status.busy, message: status.message))
        }
        connection.close()
        // A trial without its supervisor must never begin accepting work on its own.
        // The service manager owns process restart after this channel is lost.
        await runtime.shutdown()
    }

    private func send<Value: Encodable>(_ value: Value) async {
        guard let data = try? JSONEncoder().encode(value) else { return }
        await connection.writeLineAsync(String(decoding: data, as: UTF8.self))
    }

    func close() { connection.close() }
}

extension ServerOperation {
    var allowedDuringMaintenance: Bool {
        switch self {
        case .answer, .stop, .cancelQueued, .markRead, .closeSession: true
        case .uiBridge: true
        default: !mutates
        }
    }
}
