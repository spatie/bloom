import Foundation

/// The argv Bloom hands to `/usr/bin/ssh`, as a value.
///
/// Every option here is load bearing and every one of them is explained, because the next reader's
/// first instinct will be to delete half of them.
///
/// **`ControlMaster=auto` with `ControlPath` and `ControlPersist`: one connection per server, and
/// every command after the first is a channel on it.** This is not a tuning knob, and the number
/// was measured against a real VPS rather than estimated: six sequential `ssh host true` calls
/// took **3.617 seconds** with multiplexing off and **0.369 seconds** on an existing master. That
/// is 603ms against 61ms per command, and the diff loop alone is 104 processes per pass.
///
/// **`ControlPath` is a hash under a short directory, and the shortness is the whole point.** A
/// unix domain socket path is capped by `sun_path`, which is 104 bytes on macOS and 108 on Linux.
/// Measured: `ssh` refuses outright with `ControlPath too long ('...' >= 104 bytes)` and exits 1.
/// It does not fall back and it does not connect, so an overflow here is a server that cannot be
/// reached at all rather than a slow one. The obvious spelling, `~/.ssh/cm-%h-%p-%r`, spends the
/// budget on a home directory, a full domain name, a port and a username, and a long host name
/// alone can overflow it. `%C` is a SHA1 of exactly those four facts, so it is 40 characters
/// whatever they are: `/Users/freek/.bloom/ssh/` plus 40 is 64 bytes, with 40 to spare for a
/// longer account name. It goes under `~/.bloom/ssh` rather than `~/.ssh` so that Bloom never
/// writes into the directory holding the user's keys.
///
/// **There is a ceiling on how many channels one master will carry, and going past it is silent.**
/// See `maxConcurrentChannels`.
///
/// **`ControlPersist` is what makes the master outlive the command that started it.** Without it
/// the master exits with the first command and every later one pays for a new handshake, which is
/// the thing this whole arrangement exists to avoid.
///
/// **`ServerAliveInterval` with `ServerAliveCountMax` is the only thing that ever notices a
/// vanished server.** A laptop that changes network, or a VPS that is power cycled, leaves a TCP
/// connection that is open as far as this end is concerned and will never carry another byte. A
/// persistent master makes that worse rather than better, because the dead connection is the one
/// every later command is told to reuse. Keepalives at the SSH layer, not `TCPKeepAlive`, because
/// the SSH ones are sent inside the encrypted channel and are not defeated by a middlebox that
/// answers TCP on the server's behalf.
///
/// **`BatchMode=yes` is what turns a hang into an answer.** Without it, an unknown host key or a
/// passphrase-protected key with no agent makes `ssh` sit at a prompt on a stdin nobody is
/// typing into, and Bloom's timeout eventually kills it with nothing to report but silence. With
/// it, `ssh` refuses immediately and says why, which is what `SSHFailure` reads.
///
/// **`ConnectTimeout` bounds the TCP connect specifically.** The launch's own timeout kills the
/// process eventually, but it cannot tell "the server is off" from "the command is slow", and the
/// first of those has a different sentence on the screen.
///
/// **There is deliberately no `StrictHostKeyChecking` here.** Whatever the user's own
/// `~/.ssh/config` says is what happens. Passing `no`, or `accept-new`, would make Bloom accept a
/// key nobody has looked at, which removes the only defence against a machine in the middle
/// pretending to be the server, and it would do it silently on the user's behalf. An unknown host
/// is refused and said out loud instead. See `SSHFailure.hostKeyUnknown`.
///
/// **And there is no `-i`, no `IdentityFile`, and nothing anywhere in Bloom that reads a key.**
/// Shelling out to the real client means `~/.ssh/config`, `ssh-agent`, `IdentityAgent`,
/// `ProxyJump` and a hardware key all work exactly as the user already set them up, with Bloom
/// holding no credential of its own. That is the feature, not a gap in it.
public struct SSHInvocation: Sendable, Hashable {
    public var destination: SSHDestination
    /// The directory the master's socket lives in. Kept short, and kept out of `~/.ssh`.
    public var controlDirectory: String
    public var connectTimeout: Duration
    /// How long a master with no channels on it hangs around. Long enough that a person clicking
    /// through a settings pane keeps reusing one, short enough that a laptop closed for an hour is
    /// not holding a socket to a server it can no longer see.
    public var controlPersist: Duration
    public var keepAliveInterval: Duration
    /// How many unanswered keepalives it takes to call the connection dead. Three at fifteen
    /// seconds is forty five, which is longer than any hiccup and shorter than anybody's patience.
    public var keepAliveCount: Int

    /// How many commands Bloom may have in flight on one server at once.
    ///
    /// **`sshd`'s `MaxSessions` defaults to 10, a multiplexed channel is a session, and the
    /// eleventh does not fail.** Measured, fourteen concurrent commands on one master: the first
    /// ten ran on the master, and each of the other four wrote two lines to stderr
    /// ("mux_client_request_session: session request failed: Session open refused by peer", then
    /// "ControlSocket ... already exists, disabling multiplexing"), opened a connection of its
    /// own, ran the command correctly and exited 0.
    ///
    /// So the failure is not a failure. It is the whole benefit of this file quietly switching
    /// itself off: past ten in flight, every extra command pays the full 603ms handshake that the
    /// master exists to avoid, and nothing anywhere reports a problem. A diff pass fanning out
    /// over a window full of workspaces is exactly the shape that crosses ten.
    ///
    /// Eight rather than ten, because the ceiling is the server's and a server may lower it, and
    /// because Bloom is not necessarily the only thing on that connection. A caller that fans out
    /// gates itself on this.
    public static let maxConcurrentChannels = 8

    /// Under the home directory rather than under `TMPDIR`, because a master socket that survives
    /// the periodic cleaning of the temporary directory is a master that is still there in the
    /// morning. `.bloom` rather than `.ssh` so nothing Bloom does can write next to a private key.
    public static var defaultControlDirectory: String {
        (NSHomeDirectory() as NSString).appendingPathComponent(".bloom/ssh")
    }

    public init(
        destination: SSHDestination,
        controlDirectory: String = SSHInvocation.defaultControlDirectory,
        connectTimeout: Duration = .seconds(8),
        controlPersist: Duration = .seconds(120),
        keepAliveInterval: Duration = .seconds(15),
        keepAliveCount: Int = 3
    ) {
        self.destination = destination
        self.controlDirectory = controlDirectory
        self.connectTimeout = connectTimeout
        self.controlPersist = controlPersist
        self.keepAliveInterval = keepAliveInterval
        self.keepAliveCount = keepAliveCount
    }

    /// Where the master socket for this destination will be, once `ssh` has expanded `%C`.
    public var controlPath: String {
        (controlDirectory as NSString).appendingPathComponent("%C")
    }

    public var options: [String] {
        [
            "BatchMode=yes",
            "ConnectTimeout=\(connectTimeout.wholeSeconds)",
            "ControlMaster=auto",
            "ControlPath=\(controlPath)",
            "ControlPersist=\(controlPersist.wholeSeconds)",
            "ServerAliveInterval=\(keepAliveInterval.wholeSeconds)",
            "ServerAliveCountMax=\(keepAliveCount)",
        ].flatMap { ["-o", $0] }
    }

    /// The whole argv, ready for `Shell.run("/usr/bin/ssh", ...)`.
    ///
    /// `--` before the destination, verified against OpenSSH 10.3 rather than assumed: `ssh`
    /// parses with `getopt`, which stops at `--`, so a destination is a destination even if
    /// somebody found a way past `SSHDestination.parse`. Belt and braces, and the braces are that
    /// parse refusing a leading dash in the first place.
    ///
    /// **The command words are quoted for the remote shell here and nowhere else.** `ssh` does
    /// not pass argv through: it joins everything after the destination with single spaces and
    /// hands the result to the user's login shell on the far end, which splits it again. So a
    /// path with a space in it, which is what a worktree cut from a workspace called "fix the
    /// login page" is, arrives as several arguments unless it is quoted, and a path with a `$` or
    /// a backtick in it arrives as something else entirely. Every word gets exactly one pass of
    /// POSIX single quoting, which has no escapes inside it and therefore nothing that a second
    /// reading could interpret.
    public func arguments(for launch: CommandLaunch) -> [String] {
        var argv = options
        if let port = destination.port {
            argv += ["-p", String(port)]
        }
        argv += ["--", destination.argument]
        argv += ([launch.executable] + launch.arguments).map(Self.singleQuoted)
        return argv
    }

    /// One word, quoted so a POSIX shell reads it back as exactly these bytes.
    ///
    /// Single quotes rather than backslashes or double quotes, because inside single quotes a
    /// shell interprets nothing at all: no `$`, no backtick, no backslash, no newline splitting.
    /// The single quote itself is the one character that cannot appear, so it is spelled by
    /// closing the quoting, escaping one quote, and opening it again, which is the standard
    /// `'\''` and is what makes this total rather than nearly total.
    public static func singleQuoted(_ word: String) -> String {
        "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
