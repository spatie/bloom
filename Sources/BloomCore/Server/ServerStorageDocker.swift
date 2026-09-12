import Foundation
#if os(Linux)
import Glibc
#else
import Darwin
#endif

/// A storage action can address only the managed user's private engine. Pinning its socket in
/// every engine command prevents a concurrent Docker context change from redirecting cleanup.
struct ServerStorageDocker: Sendable {
    struct Output: Sendable {
        let status: Int32
        let text: String
    }

    typealias Run = @Sendable ([String], [String: String], TimeInterval, Int) async throws -> Output
    typealias ValidateFiles = @Sendable () throws -> Void

    struct Configuration: Sendable {
        let home: String
        let uid: UInt32
        let supported: Bool
        var socket: String { "/run/user/\(uid)/docker.sock" }
        var data: String { home + "/bloom/docker/data" }
        var environment: [String: String] { ["HOME": home, "PATH": "/usr/bin:/bin", "LANG": "C", "LC_ALL": "C"] }
    }

    enum Failure: Error, LocalizedError, Equatable {
        case unsupported
        case missing
        case unsafe
        case unavailable
        case invalidResponse

        var errorDescription: String? {
            switch self {
            case .unsupported: "Docker storage cleanup is available on Linux servers running as a non-root account."
            case .missing: "Docker is not installed on this server."
            case .unsafe: "Storage cleanup requires Bloom's private rootless Docker installation. Check Docker setup for this server."
            case .unavailable: "Docker storage could not be inspected. Check that Docker is running, then refresh."
            case .invalidResponse: "Docker returned storage information Bloom could not verify. Refresh or update the server tools."
            }
        }
    }

    struct Usage: Equatable, Sendable {
        let kind: String
        let totalCount: Int
        let activeCount: Int
        let size: String
        let reclaimable: String?
    }

    let configuration: Configuration
    let run: Run
    let validateFiles: ValidateFiles

    init() {
        #if os(Linux)
        let supported = true
        #else
        let supported = false
        #endif
        let configuration = Configuration(home: NSHomeDirectory(), uid: geteuid(), supported: supported)
        self.configuration = configuration
        validateFiles = { try Self.validateFiles(configuration) }
        run = { arguments, environment, timeout, limit in
            let result = try await ServerCredentialImportProcess.run("/usr/bin/docker", arguments, environment: environment,
                limit: limit, timeout: timeout, workingDirectory: "/", captureStderr: true)
            return Output(status: result.status, text: String(decoding: result.output, as: UTF8.self))
        }
    }

    init(configuration: Configuration, run: @escaping Run, validateFiles: @escaping ValidateFiles) {
        self.configuration = configuration; self.run = run; self.validateFiles = validateFiles
    }

    func validate() async throws {
        try Task.checkCancellation()
        guard configuration.supported, configuration.uid != 0 else { throw Failure.unsupported }
        try validateFiles()
        let context = try await checked(["context", "show"])
        let endpoint = try await checked(["context", "inspect", "--format", "{{json .Endpoints.docker.Host}}"])
        guard context.trimmingCharacters(in: .whitespacesAndNewlines) == "rootless",
              let decoded = try? JSONDecoder().decode(String.self, from: Data(endpoint.utf8)),
              decoded == "unix://" + configuration.socket else { throw Failure.unsafe }
        let info = try await checked(engineArguments(["info", "--format", #"{"root":{{json .DockerRootDir}},"security":{{json .SecurityOptions}}}"#]))
        struct Info: Decodable { let root: String; let security: [String] }
        guard let value = try? JSONDecoder().decode(Info.self, from: Data(info.utf8)),
              value.root == configuration.data,
              value.security.contains(where: { $0 == "name=rootless" || $0.hasPrefix("name=rootless,") }) else { throw Failure.unsafe }
        // Socket ownership is checked again after the asynchronous probes, before callers can
        // submit an engine mutation. All paths are fixed by the server account, never a client.
        try validateFiles()
    }

    func usage() async throws -> [Usage] {
        try await validate()
        return try Self.parseUsage(try await checked(engineArguments(["system", "df", "--format", "json"]), timeout: 30))
    }

    func engineArguments(_ arguments: [String]) -> [String] {
        ["--host", "unix://" + configuration.socket] + arguments
    }

    func checked(_ arguments: [String], timeout: TimeInterval = 10) async throws -> String {
        let result = try await run(arguments, configuration.environment, timeout, 65_536)
        try Task.checkCancellation()
        guard result.status == 0 else { throw Failure.unavailable }
        return result.text
    }

    static func parseUsage(_ text: String) throws -> [Usage] {
        struct Row: Decodable {
            let kind: String
            let totalCount: String
            let active: String
            let size: String
            let reclaimable: String
            enum CodingKeys: String, CodingKey {
                case kind = "Type", totalCount = "TotalCount", active = "Active", size = "Size", reclaimable = "Reclaimable"
            }
        }
        let kinds = ["Images", "Containers", "Local Volumes", "Build Cache"]
        guard text.utf8.count <= 65_536 else { throw Failure.invalidResponse }
        var rows: [Usage] = []
        for line in text.split(separator: "\n") {
            guard let row = try? JSONDecoder().decode(Row.self, from: Data(line.utf8)), kinds.contains(row.kind),
                  !rows.contains(where: { $0.kind == row.kind }),
                  let count = Int(row.totalCount), count >= 0, let active = Int(row.active), (0...count).contains(active),
                  validSize(row.size) else { throw Failure.invalidResponse }
            // Images/cache can share layers. Docker's image reclaimable percentage has reported
            // 100% even with active images, so never present it as a safe cleanup estimate.
            let reclaimable = row.kind == "Build Cache" && validSize(row.reclaimable) ? row.reclaimable : nil
            rows.append(Usage(kind: row.kind, totalCount: count, activeCount: active, size: row.size, reclaimable: reclaimable))
        }
        guard rows.count == kinds.count else { throw Failure.invalidResponse }
        return kinds.compactMap { kind in rows.first { $0.kind == kind } }
    }

    static func validSize(_ text: String) -> Bool {
        text.utf8.count <= 40 && text.range(of: #"^[0-9]+(?:\.[0-9]+)? ?(?:B|kB|MB|GB|TB|PB|EB)$"#, options: .regularExpression) != nil
    }

    static func reclaimed(_ text: String) -> String? {
        let prefix = "Total reclaimed space:"
        guard let line = text.split(separator: "\n").last(where: { $0.hasPrefix(prefix) }) else { return nil }
        let value = line.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
        return validSize(value) ? value : nil
    }

    static func validateFiles(_ configuration: Configuration) throws {
        var executable = stat()
        guard lstat("/usr/bin/docker", &executable) == 0 else { throw Failure.missing }
        guard executable.st_mode & S_IFMT == S_IFREG, executable.st_uid == 0, executable.st_mode & 0o022 == 0 else { throw Failure.unsafe }
        for path in [configuration.home, configuration.home + "/bloom", configuration.home + "/bloom/docker", configuration.data, "/run/user/\(configuration.uid)"] {
            try ownedDirectory(path, uid: configuration.uid,
                privateAccess: path == configuration.home || path == "/run/user/\(configuration.uid)")
        }
        let marker = URL(fileURLWithPath: configuration.home + "/bloom/docker/.bloom-managed")
        guard let data = try? ServerCredentialImportFiles.read(marker, limit: 100),
              String(data: data, encoding: .utf8) == "Bloom rootless Docker v1\n" else { throw Failure.unsafe }
        try ownedSocket(configuration.socket, uid: configuration.uid)
    }

    static func ownedDirectory(_ path: String, uid: UInt32, privateAccess: Bool) throws {
        guard ServerCredentialImportFiles.canonicalDirectory(URL(fileURLWithPath: path))?.path == path else { throw Failure.unsafe }
        var info = stat()
        guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == uid,
              info.st_mode & (privateAccess ? 0o077 : 0o022) == 0 else { throw Failure.unsafe }
    }

    static func ownedSocket(_ path: String, uid: UInt32) throws {
        var socket = stat()
        guard lstat(path, &socket) == 0, socket.st_mode & S_IFMT == S_IFSOCK,
              socket.st_uid == uid, socket.st_mode & 0o007 == 0 else { throw Failure.unsafe }
    }
}
