import Foundation

/// The seam's far end: a command run on a server, through the `ssh` the user already has.
///
/// It builds argv (see `SSHInvocation`) and hands it to `Shell`, so Bloom still has exactly one
/// place that starts a process and the whole of the layer above this can be tested against a
/// runner that starts none.
///
/// **Nothing here reads a key, asks for a password, or stores a credential.** The user's own
/// `ssh` does all of that, out of the configuration they already have, which is why this type has
/// no fields for any of it.
public struct SSHCommandRunner: CommandRunning {
    /// Absolute, rather than looked up on PATH. `Shell.which` would find whichever `ssh` a
    /// Homebrew install put in front of the system one, and the connection multiplexing, the
    /// config parsing and the agent socket are all things Bloom is relying on the system client's
    /// behaviour for.
    public static let executable = "/usr/bin/ssh"

    public let invocation: SSHInvocation

    public var place: RunPlace { .ssh(invocation.destination) }

    public init(_ invocation: SSHInvocation) {
        self.invocation = invocation
    }

    public init(destination: SSHDestination) {
        self.init(SSHInvocation(destination: destination))
    }

    public func run(_ launch: CommandLaunch) async throws -> ShellResult {
        try prepareControlDirectory()

        let result: ShellResult
        do {
            result = try await Shell.run(
                Self.executable,
                invocation.arguments(for: launch),
                stdin: launch.stdin,
                // A shade over the launch's own budget. `Shell.run` sends SIGTERM when the timeout
                // fires, and a killed `ssh` reports status 15 with an empty stderr, which reads as
                // a mystery. Giving `ConnectTimeout` and the keepalives room to produce their own
                // message first means the common failures arrive as sentences rather than as a
                // signal.
                timeout: launch.timeout + .seconds(2)
            )
        } catch let error as ShellError where error.status == 127 {
            throw RunTrouble.unreachable(.clientMissing)
        }

        if let failure = SSHFailure.classify(status: result.status, stderr: result.stderr) {
            throw RunTrouble.unreachable(failure)
        }
        // SIGTERM, which is what `Shell.run`'s own timeout sends. Measured: an `ssh` killed
        // mid-command leaves BOTH streams empty, so all three conditions are required rather than
        // the status alone. A remote command that genuinely exits 15 having printed something is
        // therefore not mistaken for a timeout; one that exits 15 having printed nothing is, and
        // the cost of that is a better sentence on a result that was empty either way.
        if result.status == 15, result.stdout.isEmpty, result.stderr.isEmpty {
            throw RunTrouble.timedOut(launch.timeout)
        }
        return result
    }

    public func put(
        _ contents: String,
        at path: String,
        executable: Bool,
        timeout: Duration
    ) async throws {
        // One round trip, and no `scp`. `scp` and `sftp` are separate binaries with their own
        // option spellings and their own subsystem on the far end, and both would open a second
        // connection unless separately taught about the control socket; `cat` on the connection
        // that is already up is a channel.
        //
        // Written to a neighbour and renamed over the destination, because a copy interrupted
        // half way through leaves a Python file that still parses and still prints a version, and
        // the version it prints is the new one. `mv` within a directory is atomic, so the file at
        // `path` is either the whole of the old one or the whole of the new one.
        let quoted = SSHInvocation.singleQuoted(path)
        let temporary = SSHInvocation.singleQuoted(path + ".incoming")
        let directory = SSHInvocation.singleQuoted((path as NSString).deletingLastPathComponent)
        let mode = executable ? "755" : "644"
        let script = """
            set -e
            mkdir -p \(directory)
            cat > \(temporary)
            chmod \(mode) \(temporary)
            mv \(temporary) \(quoted)
            """

        let result = try await run(CommandLaunch(
            executable: "sh",
            arguments: ["-c", script],
            stdin: contents,
            timeout: timeout
        ))
        guard result.ok else {
            throw RunTrouble.couldNotWrite(
                path: path,
                detail: result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
    }

    /// `ssh` does not create the directory its `ControlPath` sits in, and a missing one is not an
    /// error it reports in a way anybody reads: it falls back to no multiplexing and every command
    /// pays for a fresh handshake, quietly, for ever. So the first-run case is handled here.
    ///
    /// 0700, because the socket inside it is a live authenticated connection to the user's server
    /// and anybody who can open it is on that server.
    private func prepareControlDirectory() throws {
        let directory = invocation.controlDirectory
        guard !FileManager.default.fileExists(atPath: directory) else { return }
        do {
            try FileManager.default.createDirectory(
                atPath: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw RunTrouble.couldNotWrite(path: directory, detail: "\(error)")
        }
    }
}
