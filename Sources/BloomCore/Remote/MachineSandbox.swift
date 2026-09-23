import Foundation
#if canImport(Glibc)
import Glibc
#endif

/// Running a machine's untrusted processes as a second Unix user that cannot manage the machine.
///
/// **Two things are wrong with one user, and this fixes both.** The agent had passwordless sudo and
/// could read `/etc/bloom/workspace.json`, so a prompt injection reached every workspace its person
/// could open; that is H1 in the security review of 19 September 2026. And on a Sprite,
/// `/.sprite/api.sock` is world-writable on a read-only mount, so **a user with no sudo at all can
/// still create a service that runs as the Runner's own user**, which was measured on 19 September
/// 2026 and is why a second user by itself isolates nothing.
///
/// So a sandboxed command is:
///
///     sudo -E unshare --mount --propagation private -- /bin/sh -c \
///       'mount --bind /dev/null /.sprite/api.sock && exec setpriv --reuid=agent --regid=agent --init-groups <command>'
///
/// The mount is private, so the mask is this process tree's alone and the Runner keeps its own
/// access. Inside, `umount` needs superuser and `unshare` is refused, both measured, so the process
/// cannot take the mask off. `setpriv` drops to the sandbox user for good: there is no setuid step
/// back. `sudo -E` keeps the environment, because a turn's keys travel in it and must never be in
/// the arguments, which `ps` shows to everybody.
public struct MachineSandbox: Sendable, Hashable {
    /// The user with no sudo that agents, terminals, scripts and services run as.
    public var user: String
    /// That user's home, which is not the Runner's: `/home/sprite` is 0750, and the Runner's secret
    /// and database are under it.
    public var home: String
    /// Paths masked with `/dev/null` before the command runs. Anything a local process could manage
    /// the machine through belongs here.
    public var maskedPaths: [String]
    public var sudo: String
    public var unshare: String
    public var setpriv: String
    public var shell: String

    public init(user: String = "bloom-agent", home: String? = nil,
                maskedPaths: [String] = ["/.sprite/api.sock"],
                sudo: String = "/usr/bin/sudo", unshare: String = "/usr/bin/unshare",
                setpriv: String = "/usr/bin/setpriv", shell: String = "/bin/sh") {
        self.user = user
        self.home = home ?? "/home/" + user
        self.maskedPaths = maskedPaths
        self.sudo = sudo
        self.unshare = unshare
        self.setpriv = setpriv
        self.shell = shell
    }

    /// The command to run instead of `executable`, so that it runs as the sandbox's user.
    ///
    /// **`path` is set inside the script, because sudo throws the one in the environment away.**
    /// `secure_path` replaces PATH even under `-E`, so a service started this way looked for its
    /// tools in the system directories only: There There's Vite service died with "bun: not found"
    /// on a machine where the sandbox user could run bun perfectly well by its full path.
    public func wrap(
        executable: String, arguments: [String], path: String? = nil
    ) -> (executable: String, arguments: [String]) {
        let masks = maskedPaths.map { "mount --bind /dev/null \(Self.quoted($0))" }
        let exports = path.map { ["export PATH=" + Self.quoted($0)] } ?? []
        let dropping = [setpriv, "--reuid=" + user, "--regid=" + user, "--init-groups", executable] + arguments
        let script = (masks + exports + ["exec " + dropping.map(Self.quoted).joined(separator: " ")]).joined(separator: " && ")
        return (sudo, ["-E", unshare, "--mount", "--propagation", "private", "--", shell, "-c", script])
    }

    /// The environment for a sandboxed process: its own home, and its own name, because a CLI that
    /// writes its state into `$HOME` would otherwise write into the Runner's, which it cannot read.
    public func environment(_ base: [String: String]) -> [String: String] {
        var environment = base
        environment["HOME"] = home
        environment["USER"] = user
        environment["LOGNAME"] = user
        return environment
    }

    /// The same command, as the launch every runner spawns through.
    public func wrap(_ launch: AgentLaunch) -> AgentLaunch {
        let command = wrap(executable: launch.executable, arguments: launch.arguments, path: launch.environment["PATH"])
        return AgentLaunch(executable: command.executable, arguments: command.arguments, cwd: launch.cwd,
                           environment: environment(launch.environment))
    }

    /// Single quotes, with any quote inside closed and reopened, which is the only quoting `sh`
    /// gives no other meaning to.
    static func quoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// The sandbox this machine can actually use, or nil where it cannot: no such user, or one of
    /// the three tools missing. **Nil is not a failure to report; it is a Mac, or a machine built
    /// before the sandbox existed**, and the caller runs the command as it always did.
    /// The uid every sandboxed process on this machine runs as, or nil on a host that has no
    /// agent user, which is a Mac or a test host. Looked up rather than assumed, because the image
    /// and provisioning decide the number and nothing here should.
    public static func agentUID(user: String = "bloom-agent") -> UInt32? {
        guard let entry = getpwnam(user) else { return nil }

        return UInt32(entry.pointee.pw_uid)
    }

    public static func available(user: String = "bloom-agent", home: String? = nil,
                                 maskedPaths: [String] = ["/.sprite/api.sock"],
                                 hasUser: (String) -> Bool = MachineSandbox.userExists,
                                 isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }) -> MachineSandbox? {
        let sandbox = MachineSandbox(user: user, home: home, maskedPaths: maskedPaths)
        guard hasUser(user), isExecutable(sandbox.sudo), isExecutable(sandbox.unshare), isExecutable(sandbox.setpriv) else {
            return nil
        }
        return sandbox
    }

    /// Where a machine keeps what both users read: the tmux configuration, and anything else the
    /// Runner writes for the sandbox user. Made by `Tools/provision-sandbox.sh`, root-owned, group
    /// `bloom-work` and setgid, because the Runner's own data directory stays 0700.
    public static let sharedDirectory = "/var/lib/bloom/shared"

    /// Credential endpoints and wrappers live below a Runner-owned directory. Person-bound processes may
    /// traverse it and connect to its sockets, but cannot replace a socket or another turn's tool.
    public static let personBoundSharedDirectory = "/var/lib/bloom/person-bound-shared"
    public static let credentialV2SocketPath = personBoundSharedDirectory + "/git-credentials-v2.sock"
    public static let launchGateSocketPath = personBoundSharedDirectory + "/person-bound-launch.sock"
    /// Git and gh receive this as HOME, XDG_CONFIG_HOME and GH_CONFIG_DIR for network operations.
    /// Provisioning owns it as root and makes it read-only, so neither a turn nor the Runner user
    /// can install a proxy, CA, Unix socket, helper or URL rewrite there.
    public static let personBoundCleanConfigDirectory = "/var/lib/bloom/person-bound-config"
    public static let personBoundHomeRoot = "/var/lib/bloom/person-bound"
    /// Root-only execution history written by the privileged supervisor at ptrace exec stops.
    public static let personBoundProvenanceRoot = "/var/lib/bloom/person-bound-provenance"
    public static let personBoundCredentialShield = "/usr/local/lib/bloom-credential-shield.so"
    /// The group that shares the worktree and the credential socket. See `Tools/provision-sandbox.sh`.
    public static let sharedGroup = "bloom-work"

    public static func userExists(_ name: String) -> Bool {
        #if canImport(Glibc)
        return name.withCString { getpwnam($0) != nil }
        #else
        return false
        #endif
    }
}
