import Foundation

/// SSH owns authentication, host verification and encryption. A remote command is shell quoted
/// separately from SSH's argument vector because OpenSSH sends that command through a shell.
public enum ServerEndpoint: Sendable, Equatable {
    case local(directory: String)
    case ssh(host: String, executable: String, directory: String)

    public var launch: AgentLaunch? {
        get throws {
            guard case .ssh(let host, let executable, let directory) = self else { return nil }
            guard !host.isEmpty, !host.hasPrefix("-"),
                  host.unicodeScalars.allSatisfy({ !CharacterSet.whitespacesAndNewlines.contains($0) && $0.value >= 32 }),
                  executable.hasPrefix("/"), directory.hasPrefix("/"),
                  !executable.contains("\0"), !directory.contains("\0") else {
                throw ServerFailure("Use an SSH host or alias and absolute server executable and data directory paths.")
            }
            let command = [executable, "connect", "--data-dir", directory].map(Self.quote).joined(separator: " ")
            return AgentLaunch(
                executable: "/usr/bin/ssh",
                arguments: ["-T", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes",
                            "-o", "ConnectTimeout=10", "-o", "ServerAliveInterval=15",
                            "-o", "ServerAliveCountMax=3", host, command],
                cwd: NSTemporaryDirectory(), environment: Shell.environment()
            )
        }
    }

    private static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
