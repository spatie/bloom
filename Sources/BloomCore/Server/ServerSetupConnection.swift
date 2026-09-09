import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

public struct ServerInstallNotice: Codable, Sendable, Equatable {
    public var code: String
    public var message: String
}

public struct ServerInstallCheck: Codable, Sendable {
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

    public init(executable: String, dataDirectory: String, serviceUser: String) {
        event = "complete"; self.executable = executable; self.dataDirectory = dataDirectory; self.serviceUser = serviceUser
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
        guard result.ok else { throw ServerSetupFailure.classify(status: result.status, stderr: result.stderr) }
        return result
    }

    public func inspect(script: String) async throws -> ServerInstallCheck {
        let result = try await Shell.run("/usr/bin/ssh", arguments(command: "python3 - --check"), stdin: script, timeout: .seconds(35))
        if let line = result.stdout.split(separator: "\n").last,
           let check = try? JSONDecoder().decode(ServerInstallCheck.self, from: Data(line.utf8)) { return check }
        throw ServerSetupFailure.classify(status: result.status, stderr: result.stderr)
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
        _ = try await run("umask 077; mkdir " + ServerSetupSSH.shellQuote(staging))
        do {
            try await upload(archive, to: staging + "/server.tar.gz")
            try await upload(clientPublicKey, to: staging + "/client.pub")
            let digest = SHA256.hash(data: try Data(contentsOf: archive, options: .mappedIfSafe)).map { String(format: "%02x", $0) }.joined()
            let command = "if [ \"$(id -u)\" = 0 ]; then python3 -; else sudo -n python3 -; fi"
            // Arguments belong to python, not to the shell's condition.
            let args = ["--package", staging + "/server.tar.gz", "--sha256", digest, "--client-public-key-file", staging + "/client.pub"].map(ServerSetupSSH.shellQuote).joined(separator: " ")
            let invocation = command.replacingOccurrences(of: "python3 -", with: "python3 - " + args)
            let result = try await stream(invocation, script: script, progress: progress)
            _ = try? await run("rm -f " + ServerSetupSSH.shellQuote(staging + "/server.tar.gz") + " " + ServerSetupSSH.shellQuote(staging + "/client.pub") + "; rmdir " + ServerSetupSSH.shellQuote(staging))
            return result
        } catch {
            _ = try? await run("rm -f " + ServerSetupSSH.shellQuote(staging + "/server.tar.gz") + " " + ServerSetupSSH.shellQuote(staging + "/client.pub") + "; rmdir " + ServerSetupSSH.shellQuote(staging))
            throw error
        }
    }

    private func upload(_ file: URL, to remotePath: String) async throws {
        // scp uses the same pinned host and identity options as the control connection.
        var options = try arguments(command: "")
        options.removeLast(2)
        options.removeAll { $0 == "-T" }
        let result = try await Shell.run("/usr/bin/scp", options + [file.path, host + ":" + remotePath], stdin: "", timeout: .seconds(300))
        guard result.ok else { throw ServerSetupFailure.classify(status: result.status, stderr: result.stderr) }
    }

    private func stream(_ command: String, script: String, progress: @escaping @Sendable (ServerInstallEvent) async -> Void) async throws -> ServerInstallEvent {
        let process = StreamingProcess(executable: "/usr/bin/ssh", arguments: try arguments(command: command), mergeStderr: false)
        let timeout = Task { try? await Task.sleep(for: .seconds(900)); if !Task.isCancelled { process.terminate() } }
        defer { timeout.cancel() }
        return try await withTaskCancellationHandler {
            async let errors: String = {
                var tail = ""
                for await line in process.errorLines { tail = String((tail + line + "\n").suffix(8192)) }
                return tail
            }()
            try process.start()
            process.write(script)
            process.closeStdin()
            var completed: ServerInstallEvent?
            var failure: ServerInstallEvent?
            for try await line in process.lines {
                guard let event = try? JSONDecoder().decode(ServerInstallEvent.self, from: Data(line.utf8)) else { continue }
                await progress(event)
                if event.event == "complete" { completed = event }
                if event.event == "error" { failure = event }
            }
            let status = await process.exitStatus
            let stderr = await errors
            if status == 0, let completed { return completed }
            if Task.isCancelled { throw CancellationError() }
            if let failure {
                throw ServerSetupFailure.installation(code: failure.code ?? "installation_failed")
            }
            throw ServerSetupFailure.classify(status: status, stderr: stderr)
        } onCancel: { process.terminate() }
    }
}
