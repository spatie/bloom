import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

public struct ServerInstallNotice: Codable, Sendable, Equatable {
    public var code: String
    public var message: String
    public var recovery: String?

    public var recoverySuggestion: String {
        recovery ?? ServerSetupFailure.installation(code: code).recovery
    }
}

public struct ServerInstallCheck: Codable, Sendable {
    public var installationRoot: String?
    public var serviceHome: String?
    public var platform: String
    public var architecture: String
    public var privilege: String
    public var existing: Bool
    public var blockers: [ServerInstallNotice]
    public var warnings: [ServerInstallNotice]
    public var executable: String
    public var dataDirectory: String
    public var serviceUser: String
}

public struct ServerInstallEvent: Decodable, Sendable {
    public var event: String
    public var step: String?
    public var message: String?
    public var code: String?
    public var recovery: String?
    public var executable: String?
    public var dataDirectory: String?
    public var serviceUser: String?
    public var serviceHome: String?
    public var ready: Bool?
    public var details: String?
    public var command: String?
    public var exitStatus: Int?

    public init(event: String, step: String? = nil, message: String? = nil, code: String? = nil,
                recovery: String? = nil, details: String? = nil, command: String? = nil, exitStatus: Int? = nil,
                executable: String? = nil, dataDirectory: String? = nil, serviceUser: String? = nil,
                serviceHome: String? = nil, ready: Bool? = nil) {
        self.event = event; self.step = step; self.message = message; self.code = code
        self.recovery = recovery; self.details = details; self.command = command; self.exitStatus = exitStatus
        self.executable = executable; self.dataDirectory = dataDirectory; self.serviceUser = serviceUser
        self.serviceHome = serviceHome; self.ready = ready
    }

    public init(executable: String, dataDirectory: String, serviceUser: String, serviceHome: String? = nil) {
        event = "complete"; self.executable = executable; self.dataDirectory = dataDirectory; self.serviceUser = serviceUser; self.serviceHome = serviceHome
    }
}

public struct ServerSetupHostKey: Sendable {
    public let fingerprint: String
    let line: String
    let lookup: String
}

/// SSH owns encryption and host verification. Only the public half of the new client key is uploaded.
public struct ServerSetupConnection: Sendable {
    public let host: String
    public let identityFile: String?
    public let knownHostsFile: String

    public init(host: String, identityFile: String?, knownHostsFile: String) throws {
        self.host = try ServerSetupSSH.validateDestination(host)
        self.identityFile = try ServerSetupSSH.validateIdentityFile(identityFile ?? "")
        self.knownHostsFile = knownHostsFile
    }

    public func arguments(command: String) throws -> [String] {
        try ServerSetupSSH.arguments(destination: host, knownHostsFile: knownHostsFile, identityFile: identityFile, command: command)
    }

    public func run(_ command: String, input: String? = nil, timeout: Duration = .seconds(25)) async throws -> ShellResult {
        let result = try await Shell.run("/usr/bin/ssh", arguments(command: command), stdin: input ?? "", timeout: timeout)
        try Task.checkCancellation()
        guard result.ok else { throw ServerSetupFailure.classify(status: result.status, stderr: result.stderr, command: "ssh") }
        return result
    }

    public func inspect(script: String) async throws -> ServerInstallCheck {
        let result = try await Shell.run("/usr/bin/ssh", arguments(command: "python3 - --check"), stdin: script, timeout: .seconds(35))
        try Task.checkCancellation()
        if let line = result.stdout.split(separator: "\n").last,
           var check = try? JSONDecoder().decode(ServerInstallCheck.self, from: Data(line.utf8)) {
            check.blockers = check.blockers.map(Self.sanitisedNotice)
            check.warnings = check.warnings.map(Self.sanitisedNotice)
            return check
        }
        throw ServerSetupFailure.classify(status: result.status, stderr: result.stderr, command: "ssh")
    }

    private static func sanitisedNotice(_ notice: ServerInstallNotice) -> ServerInstallNotice {
        var value = notice
        value.message = ServerSetupDiagnostics.sanitise(value.message)
        value.recovery = ServerSetupDiagnostics.optional(value.recovery)
        return value
    }

    /// Scan only direct connections. Jump-host users can establish trust with their normal SSH client first.
    public func candidateKey() async throws -> ServerSetupHostKey {
        let config = try await Shell.run("/usr/bin/ssh", ["-G", host], stdin: "", timeout: .seconds(5))
        guard config.ok else { throw ServerSetupFailure(code: .invalidAddress) }
        var values: [String: String] = [:]
        for line in config.lines {
            let parts = line.split(separator: " ", maxSplits: 1)
            if parts.count == 2 { values[String(parts[0])] = String(parts[1]) }
        }
        guard let hostname = values["hostname"], let port = values["port"], let number = Int(port), (1...65535).contains(number),
              values["proxycommand"] == nil || values["proxycommand"] == "none",
              values["proxyjump"] == nil || values["proxyjump"] == "none",
              values["hostkeyalias"] == nil || values["hostkeyalias"] == "none" else { throw ServerSetupFailure(code: .hostUnknown) }
        _ = try ServerSetupSSH.validateDestination(hostname)
        let scan = try await Shell.run("/usr/bin/ssh-keyscan", ["-T", "5", "-p", port, "-t", "ed25519", hostname], stdin: "", timeout: .seconds(10))
        let candidates = scan.lines.filter { !$0.hasPrefix("#") && $0.split(separator: " ").count == 3 }
        guard let line = candidates.first, Set(candidates).count == 1 else { throw ServerSetupFailure(code: .unreachable) }
        let lookup = number == 22 ? hostname : "[\(hostname)]:\(port)"
        let key = line.split(separator: " ")
        guard key[1] == "ssh-ed25519" else { throw ServerSetupFailure(code: .hostUnknown) }
        let normalised = "\(lookup) \(key[1]) \(key[2])\n"
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("bloom-host-\(UUID().uuidString)")
        try Data(normalised.utf8).write(to: path, options: .atomic)
        defer { try? FileManager.default.removeItem(at: path) }
        let fingerprint = try await Shell.run("/usr/bin/ssh-keygen", ["-lf", path.path, "-E", "sha256"], stdin: "", timeout: .seconds(5))
        guard fingerprint.ok, let value = fingerprint.trimmed.split(separator: " ").dropFirst().first else { throw ServerSetupFailure(code: .hostUnknown) }
        return ServerSetupHostKey(fingerprint: String(value), line: normalised, lookup: lookup)
    }

    public func trust(_ key: ServerSetupHostKey) async throws {
        let existing = try await Shell.run("/usr/bin/ssh-keygen", ["-F", key.lookup, "-f", knownHostsFile], stdin: "", timeout: .seconds(5))
        if existing.ok {
            guard ServerSetupSSH.trustMatches(lookupOutput: existing.stdout, candidateLine: key.line) else { throw ServerSetupFailure(code: .hostChanged) }
            return
        }
        guard existing.status == 1 else { throw ServerSetupFailure(code: .permission) }
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: knownHostsFile))
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(("\n" + key.line).utf8))
    }

    public func install(script: String, archive: URL, clientPublicKey: URL,
                        progress: @escaping @Sendable (ServerInstallEvent) async -> Void) async throws -> ServerInstallEvent {
        let staging = "/tmp/bloom-setup-\(UUID().uuidString.lowercased())"
        try Task.checkCancellation()
        await progress(ServerInstallEvent(event: "progress", step: "staging", message: "Preparing a private upload directory on the server."))
        _ = try await run("umask 077; mkdir " + ServerSetupSSH.shellQuote(staging))
        do {
            let bytes = (try archive.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0
            await progress(ServerInstallEvent(event: "progress", step: "upload-package", message: "Uploading the server package (\(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)))."))
            try await upload(archive, to: staging + "/server.tar.gz", step: "upload-package", progress: progress)
            await progress(ServerInstallEvent(event: "output", step: "upload-package", message: "Server package upload complete."))
            await progress(ServerInstallEvent(event: "progress", step: "upload-key", message: "Uploading this client's public SSH key."))
            try await upload(clientPublicKey, to: staging + "/client.pub", step: "upload-key", progress: progress)
            await progress(ServerInstallEvent(event: "output", step: "upload-key", message: "Public key upload complete."))
            let digest = SHA256.hash(data: try Data(contentsOf: archive, options: .mappedIfSafe)).map { String(format: "%02x", $0) }.joined()
            let command = "if [ \"$(id -u)\" = 0 ]; then python3 -; else sudo -n python3 -; fi"
            // Arguments belong to python, not to the shell's condition.
            let args = ["--package", staging + "/server.tar.gz", "--sha256", digest, "--client-public-key-file", staging + "/client.pub"].map(ServerSetupSSH.shellQuote).joined(separator: " ")
            let invocation = command.replacingOccurrences(of: "python3 -", with: "python3 - " + args)
            try Task.checkCancellation()
            await progress(ServerInstallEvent(event: "progress", step: "launch-installer", message: "Starting the server installer."))
            let result = try await stream(invocation, script: script, progress: progress)
            _ = try? await run("rm -f " + ServerSetupSSH.shellQuote(staging + "/server.tar.gz") + " " + ServerSetupSSH.shellQuote(staging + "/client.pub") + "; rmdir " + ServerSetupSSH.shellQuote(staging))
            return result
        } catch {
            _ = try? await run("rm -f " + ServerSetupSSH.shellQuote(staging + "/server.tar.gz") + " " + ServerSetupSSH.shellQuote(staging + "/client.pub") + "; rmdir " + ServerSetupSSH.shellQuote(staging))
            throw error
        }
    }

    /// Static Python wrapper preserves the reviewed helper source for its protected launchers.
    /// Values are argv, never interpolated into Python source. Admin access is the pinned setup connection.
    public static func browserInstallerCommand(user: String, serviceHome: String) throws -> String {
        guard user.range(of: #"^[a-z_][a-z0-9_-]{0,31}$"#, options: .regularExpression) != nil,
              serviceHome.hasPrefix("/"), serviceHome.utf8.count <= 4096,
              !serviceHome.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw ServerSetupFailure(code: .invalidAddress)
        }
        let wrapper = "import sys; source=sys.stdin.read(); exec(compile(source, '<bloom-browser>', 'exec'), {'__name__':'__main__', '__bloom_browser_source':source})"
        let python = "python3 -c " + [wrapper, "--user", user, "--service-home", serviceHome].map(ServerSetupSSH.shellQuote).joined(separator: " ")
        return "if [ \"$(id -u)\" = 0 ]; then " + python + "; else sudo -n " + python + "; fi"
    }

    public func installBrowser(script: String, user: String, serviceHome: String,
                               progress: @escaping @Sendable (ServerInstallEvent) async -> Void) async throws -> ServerInstallEvent {
        try Task.checkCancellation()
        await progress(ServerInstallEvent(event: "progress", step: "browser_dependencies", message: "Starting optional browser setup."))
        return try await stream(Self.browserInstallerCommand(user: user, serviceHome: serviceHome), script: script,
                                acceptsFailureEvent: true, commandLabel: "python3 (browser installer)", step: "browser_dependencies", progress: progress)
    }

    private func upload(_ file: URL, to remotePath: String, step: String,
                        progress: @escaping @Sendable (ServerInstallEvent) async -> Void) async throws {
        // scp uses the same pinned host and identity options as the control connection.
        var options = try arguments(command: "")
        options.removeLast(2)
        options.removeAll { $0 == "-T" }
        let process = StreamingProcess(executable: "/usr/bin/scp", arguments: options + [file.path, host + ":" + remotePath], mergeStderr: false)
        _ = try await ServerSetupStream.run(process, input: "", timeout: .seconds(300), requiresCompletion: false,
                                           commandLabel: "scp", step: step, progress: progress)
    }

    private func stream(_ command: String, script: String, acceptsFailureEvent: Bool = false,
                        commandLabel: String = "ssh", step: String? = nil, progress: @escaping @Sendable (ServerInstallEvent) async -> Void) async throws -> ServerInstallEvent {
        let process = StreamingProcess(executable: "/usr/bin/ssh", arguments: try arguments(command: command), mergeStderr: false)
        return try await ServerSetupStream.run(process, input: script, acceptsFailureEvent: acceptsFailureEvent,
                                             commandLabel: commandLabel, step: step, progress: progress)
    }
}
