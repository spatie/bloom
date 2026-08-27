import Foundation

/// Everything needed to run one command, as a value, so argv can be asserted on without a process
/// ever existing.
///
/// The same shape and the same reason as `AgentLaunch`, which is already this seam for the agent:
/// a struct the caller builds, a protocol that consumes it, and a test that can read the argv
/// without a binary being on the machine. A third shape here would be a third thing to learn.
///
/// **`arguments` is an array and there is no string form of it.** A command assembled by joining
/// words with spaces is a command that breaks on the first path with a space in it, and Bloom's
/// paths are worktree paths built out of workspace names people type. `LocalCommandRunner` hands
/// the array to `exec`, and `SSHCommandRunner` quotes each element for the remote shell exactly
/// once. Neither ever concatenates.
public struct CommandLaunch: Sendable, Hashable {
    public var executable: String
    public var arguments: [String]
    /// Written to the command's stdin and then closed. This is how a whole script, or a whole
    /// file, crosses in one round trip without anything having to be quoted.
    public var stdin: String?
    /// **Not optional, and that is the point.** A server that has gone away does not refuse a
    /// connection, it accepts nothing and says nothing, and a call with no deadline behind it is
    /// a spinner that never stops. Every call site names a number.
    public var timeout: Duration

    public init(
        executable: String,
        arguments: [String] = [],
        stdin: String? = nil,
        timeout: Duration
    ) {
        self.executable = executable
        self.arguments = arguments
        self.stdin = stdin
        self.timeout = timeout
    }

    /// A `/bin/sh` script, delivered on stdin.
    ///
    /// `sh -s` rather than `sh -c <script>` because a script on stdin needs no quoting at all: it
    /// crosses as bytes rather than as an argv word that the remote login shell would re-read.
    /// The probe script is fifty lines of shell and would otherwise have to survive two rounds of
    /// quoting to reach the far end unchanged.
    public static func script(_ source: String, timeout: Duration) -> CommandLaunch {
        CommandLaunch(executable: "sh", arguments: ["-s"], stdin: source, timeout: timeout)
    }
}

/// Where a command ran, for the sentence that reports what happened.
public enum RunPlace: Sendable, Hashable {
    case thisMac
    case ssh(SSHDestination)

    public var description: String {
        switch self {
        case .thisMac: "this Mac"
        case .ssh(let destination): destination.display
        }
    }
}

/// Running a command somewhere, and putting a file somewhere.
///
/// Two conformances: `LocalCommandRunner`, which is what `Shell` already does, and
/// `SSHCommandRunner`, which builds argv for `/usr/bin/ssh` and hands it to the same `Shell`. So
/// there is still exactly one place in Bloom that starts a process, and everything above this
/// line can be tested by handing it a runner that starts none.
///
/// It is deliberately two calls and not more. `put` could have been expressed as `run` with the
/// file on stdin, and over SSH that is precisely what it is, but locally it is a file write with
/// no process in it at all, and making the local case fork a shell to copy a file would be paying
/// for a symmetry nobody reads.
public protocol CommandRunning: Sendable {
    var place: RunPlace { get }

    /// Runs it and hands back what it said, whatever its exit status. A non-zero status is an
    /// answer here rather than an error, because "not installed" comes back as 127 and is the
    /// thing the probe is asking about.
    func run(_ launch: CommandLaunch) async throws -> ShellResult

    /// Writes `contents` at `path`, creating the directory above it, and makes it executable when
    /// asked.
    ///
    /// **Never partially.** It writes a neighbouring temporary file and renames it over the
    /// destination, because a copy interrupted half way through leaves a file that still parses,
    /// still prints a version, and prints the wrong one. Rename within a directory is atomic on
    /// every filesystem this will meet.
    func put(
        _ contents: String,
        at path: String,
        executable: Bool,
        timeout: Duration
    ) async throws
}

/// The failures a runner raises, as opposed to a command that ran and said no.
public enum RunTrouble: Error, Sendable, Hashable, CustomStringConvertible {
    /// The connection itself did not happen. See `SSHFailure`, which is what read the stderr.
    case unreachable(SSHFailure)
    /// It ran and took longer than the launch allowed.
    case timedOut(Duration)
    /// A file could not be put where it was asked for.
    case couldNotWrite(path: String, detail: String)

    public var description: String {
        switch self {
        case .unreachable(let failure): failure.sentence
        case .timedOut(let budget): "No answer within \(budget.wholeSeconds) seconds."
        case .couldNotWrite(let path, let detail): "Could not write \(path): \(detail)"
        }
    }
}

public extension Duration {
    /// Seconds, rounded down, for a sentence and for an `ssh -o` value. `Duration` prints as
    /// "8.0 seconds" and neither a sentence nor `ConnectTimeout` wants that.
    var wholeSeconds: Int { Int(components.seconds) }
}

// MARK: - Local

/// The seam's local end, which is exactly what `Shell` already did.
///
/// It exists so that everything above the seam (the probe, the daemon install, the whole checkup)
/// can be run against this Mac with no server anywhere. That is not only a convenience for tests:
/// it is the only honest way to prove the probe script parses on a machine that words things
/// differently, because macOS has no `/etc/os-release` and a `df` of its own.
public struct LocalCommandRunner: CommandRunning {
    public let place = RunPlace.thisMac

    public init() {}

    public func run(_ launch: CommandLaunch) async throws -> ShellResult {
        try await Shell.run(
            launch.executable,
            launch.arguments,
            stdin: launch.stdin,
            timeout: launch.timeout
        )
    }

    public func put(
        _ contents: String,
        at path: String,
        executable: Bool,
        timeout: Duration
    ) async throws {
        let directory = (path as NSString).deletingLastPathComponent
        let temporary = path + ".bloom-\(UUID().uuidString.prefix(8))"
        do {
            try FileManager.default.createDirectory(
                atPath: directory,
                withIntermediateDirectories: true
            )
            try contents.write(toFile: temporary, atomically: false, encoding: .utf8)
            if executable {
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o755],
                    ofItemAtPath: temporary
                )
            }
            // Two calls, because neither one covers both cases: `moveItem` refuses when the
            // destination exists, which is every update, and `replaceItemAt` refuses when it does
            // not, which is every first install. The first install is the one a fresh server
            // takes, so getting this wrong fails on exactly the path nobody exercises twice.
            if FileManager.default.fileExists(atPath: path) {
                _ = try FileManager.default.replaceItemAt(
                    URL(fileURLWithPath: path),
                    withItemAt: URL(fileURLWithPath: temporary)
                )
            } else {
                try FileManager.default.moveItem(atPath: temporary, toPath: path)
            }
        } catch {
            try? FileManager.default.removeItem(atPath: temporary)
            throw RunTrouble.couldNotWrite(path: path, detail: "\(error)")
        }
    }
}
