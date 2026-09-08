import Foundation

/// SSH owns authentication, host verification and encryption. A remote command is shell quoted
/// separately from SSH's argument vector because OpenSSH sends that command through a shell.
public enum ServerEndpoint: Sendable, Equatable {
    case local(directory: String)
    case ssh(host: String, executable: String, directory: String, identityFile: String? = nil)

    public var launch: AgentLaunch? {
        get throws {
            guard case .ssh(let host, let executable, let directory, let identityFile) = self else { return nil }
            guard !host.isEmpty, !host.hasPrefix("-"),
                  host.unicodeScalars.allSatisfy({ !CharacterSet.whitespacesAndNewlines.contains($0) && $0.value >= 32 }),
                  executable.hasPrefix("/"), directory.hasPrefix("/"),
                  !executable.contains("\0"), !directory.contains("\0") else {
                throw ServerFailure("Use an SSH host or alias and absolute server executable and data directory paths.")
            }
            var identityArguments: [String] = []
            if let identityFile, !identityFile.isEmpty {
                guard identityFile.hasPrefix("/"), !identityFile.contains("\0") else { throw ServerFailure("Use an absolute SSH key path on this Mac.") }
                identityArguments = ["-o", "IdentityAgent=none", "-o", "IdentitiesOnly=yes", "-i", identityFile]
            }
            let command = [executable, "connect", "--data-dir", directory].map(Self.quote).joined(separator: " ")
            return AgentLaunch(
                executable: "/usr/bin/ssh",
                arguments: ["-T", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes",
                            "-o", "ConnectTimeout=10", "-o", "ServerAliveInterval=15",
                            "-o", "ServerAliveCountMax=3"] + identityArguments + [host, command],
                cwd: NSTemporaryDirectory(), environment: Shell.environment()
            )
        }
    }

    private static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    public func forwardLaunch(remotePort: Int, localPort: Int) throws -> AgentLaunch {
        guard (1...65_535).contains(remotePort), (1...65_535).contains(localPort),
              case .ssh(let host, _, _, _) = self, let relay = try launch else {
            throw ServerFailure("Choose a remote port between 1 and 65535.")
        }
        let arguments = Array(relay.arguments.dropLast(2)) + ["-N", "-v", "-o", "ExitOnForwardFailure=yes",
            "-L", "127.0.0.1:\(localPort):127.0.0.1:\(remotePort)", host]
        return AgentLaunch(executable: relay.executable, arguments: arguments, cwd: relay.cwd, environment: relay.environment)
    }

    public func terminalLaunch(_ terminal: ServerTerminal) throws -> AgentLaunch {
        guard terminal.executable.hasPrefix("/"), terminal.socket.hasPrefix("/"), !terminal.session.isEmpty else {
            throw ServerFailure("The server returned an invalid terminal.")
        }
        let attach = ["-S", terminal.socket, "attach-session", "-t", "=" + terminal.session]
        guard let relay = try launch else {
            return AgentLaunch(executable: terminal.executable, arguments: attach, cwd: NSTemporaryDirectory(), environment: Shell.environment())
        }
        var arguments = relay.arguments
        if let noTTY = arguments.firstIndex(of: "-T") { arguments[noTTY] = "-tt" }
        arguments[arguments.count - 1] = "exec " + ([terminal.executable] + attach).map(Self.quote).joined(separator: " ")
        return AgentLaunch(executable: relay.executable, arguments: arguments, cwd: relay.cwd, environment: relay.environment)
    }
}
