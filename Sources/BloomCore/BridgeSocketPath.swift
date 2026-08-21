import Foundation

/// Where the bridge socket lives, and the one arithmetic that has to be checked rather than
/// trusted.
///
/// Derived from the database path exactly the way the tmux socket name already is, and through
/// the same `TmuxSessions.fingerprint`, so Bloom and Bloom Dev can never land on one socket. That
/// pair is a documented permanent arrangement, not a test setup, and a shared socket would let a
/// child spawned by one instance be answered with rows out of the other's database.
///
/// **The landmine is `sockaddr_un.sun_path`, which is 104 bytes on macOS and truncates in
/// silence.** A path longer than that does not fail to bind: it binds to a shorter name, so two
/// instances whose paths agree for the first 103 bytes quietly share one socket, which is the
/// exact failure the fingerprint exists to prevent. The obvious home,
/// `~/Library/Application Support/Bloom/`, is already around 45 characters before the filename and
/// the Dev copy is longer, so it fits on this machine and would not fit for somebody with a long
/// user name. The per-user Darwin temp directory is around 49 and, unlike the support directory,
/// does not grow with the app's name. The length is asserted anyway, because "it fits" is a
/// statement about one machine.
public enum BridgeSocketPath {
    /// `sizeof(sockaddr_un.sun_path)` on Darwin, including the terminator the kernel wants.
    public static let limit = 104

    /// The socket for the instance holding `databasePath`.
    ///
    /// `directory` is a parameter so the derivation can be tested against a path long enough to
    /// trip the limit, which is not something to discover on a stranger's machine.
    public static func derive(
        databasePath: String,
        directory: String = NSTemporaryDirectory()
    ) throws -> String {
        let name = "bloom-bridge-" + TmuxSessions.fingerprint(databasePath) + ".sock"
        let path = (directory as NSString).appendingPathComponent(name)
        // The byte count, not the character count, because the kernel copies bytes. The same
        // distinction is spelled out in `Tools/guard.sh` about the fingerprint itself.
        guard path.utf8.count < limit else {
            throw BridgeSocketPathError.tooLong(path: path, limit: limit)
        }
        return path
    }
}

public enum BridgeSocketPathError: Error, CustomStringConvertible {
    case tooLong(path: String, limit: Int)

    public var description: String {
        switch self {
        case .tooLong(let path, let limit):
            """
            the bridge socket path \(path) is \(path.utf8.count) bytes, and a unix socket \
            name may be at most \(limit - 1). A longer one is truncated rather than refused, \
            so two copies of Bloom could quietly share one socket
            """
        }
    }
}
