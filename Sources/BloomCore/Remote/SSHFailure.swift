import Foundation

/// Why `ssh` itself did not get anywhere, read out of what it printed.
///
/// This exists because the difference between "your server is off" and "your server's key
/// changed" is the difference between waiting and phoning somebody, and `ssh` reports both as
/// exit status 255. The status is the same, the stderr is not, so the stderr is what is read.
///
/// **Bloom never weakens host key checking, and it also cannot promise the refusal happens.**
/// Nothing here passes `-o StrictHostKeyChecking=no` or `accept-new`; whatever the user's own
/// config says is what happens, which is the same principle as inheriting their agent and their
/// jump hosts. Measured on the owner's machine, that config says `StrictHostKeyChecking
/// accept-new` globally, so a brand new host was added and connected to without a word and
/// `hostKeyUnknown` never fired. On an OpenSSH default (`ask`) the same connection under
/// `BatchMode=yes` answers "Host key verification failed." and exits 255, which is what the
/// unknown case below reads. So the sentence Bloom prints has to describe what SSH did, and Bloom
/// must not tell anybody it protected them from something their own config had already waved
/// through.
///
/// A key that has CHANGED is refused under `accept-new` too, and that one was measured against
/// the real server as well: the banner of at signs, then "Host key verification failed."
///
/// Every string matched below was taken from a real OpenSSH 10.3 run rather than from memory.
public enum SSHFailure: Sendable, Hashable {
    /// The server is not in `known_hosts` and `BatchMode` will not ask.
    case hostKeyUnknown
    /// It is in `known_hosts` and the key on the wire is a different one.
    case hostKeyChanged
    /// The key was offered and refused, or there was no key to offer.
    case authenticationRefused(String)
    case connectionRefused
    case hostNotFound
    case timedOut
    case networkUnreachable
    /// The TCP connection came up and the far end hung up during the handshake, which is what a
    /// server behind `sshd`'s own rate limit looks like.
    case closedByRemote
    /// `ssh` is not on this Mac at all, which is a thing that can happen to a stripped image.
    case clientMissing
    /// It exited 255 and said nothing at all on either stream.
    ///
    /// **This is what a multiplexing master being killed underneath a running command looks
    /// like**, measured: SIGKILL the master and the command in flight ends with status 255, empty
    /// stdout and empty stderr, while the very next command opens a fresh master and succeeds. It
    /// had no case of its own and came out as `other("")`, whose sentence was "ssh failed and
    /// said nothing", which is true and useless.
    case connectionDropped
    /// It failed and said something this does not recognise. The text is kept, whole, because a
    /// message nobody has classified yet is more use on the screen than "something went wrong".
    case other(String)

    /// What the row says.
    public var sentence: String {
        switch self {
        case .hostKeyUnknown:
            "This host is not in your known_hosts. Connect to it once in a terminal, check the fingerprint, and then add the server here."
        case .hostKeyChanged:
            "The host key has changed since you last connected. Bloom will not connect until you have worked out why."
        case .authenticationRefused(let detail):
            detail.isEmpty
                ? "The server refused your key."
                : "The server refused your key: \(detail)"
        case .connectionRefused:
            "Nothing is listening on that port."
        case .hostNotFound:
            "That host name does not resolve."
        case .timedOut:
            "No answer. The server is off, or a firewall is dropping the connection."
        case .networkUnreachable:
            "No route to that host from this Mac."
        case .closedByRemote:
            "The server closed the connection during the handshake."
        case .clientMissing:
            "There is no ssh on this Mac."
        case .connectionDropped:
            "The connection dropped. The next attempt will open a new one."
        case .other(let text):
            text.isEmpty ? "ssh failed and said nothing." : text
        }
    }

    /// Whether looking again in a moment could plausibly give a different answer. A key that has
    /// changed will not un-change, and re-probing it on a timer is noise.
    public var isWorthRetrying: Bool {
        switch self {
        case .hostKeyUnknown, .hostKeyChanged, .clientMissing: false
        case .authenticationRefused, .connectionRefused, .hostNotFound, .timedOut,
             .networkUnreachable, .closedByRemote, .connectionDropped, .other: true
        }
    }
}

public extension SSHFailure {
    /// Reads a finished `ssh` run, and answers nil when the connection worked.
    ///
    /// Nil is the important half. `ssh` exits with the REMOTE command's status, so a probe that
    /// finds no `claude` comes back non-zero and is not a connection failure at all. Only the
    /// phrases below are, and every one of them is a phrase OpenSSH actually printed when this was
    /// measured; the two spellings of a timeout and of a name lookup are there because macOS and
    /// Linux word them differently and Bloom sits on one of those talking to the other.
    ///
    /// **Nil is also what a multiplexing fallback has to produce, and that is not obvious.**
    /// Past `sshd`'s `MaxSessions`, the eleventh channel writes two lines to stderr
    /// ("mux_client_request_session: session request failed: Session open refused by peer" and
    /// "ControlSocket ... already exists, disabling multiplexing"), opens its own connection, and
    /// the command succeeds with status 0. Anything here that treated stderr as evidence of
    /// failure would report eleven working servers as broken. Nothing does, because the phrases
    /// are specific and the fallback's are not among them.
    static func classify(status: Int32, stderr: String) -> SSHFailure? {
        let text = stderr.lowercased()

        // Order matters once: a changed key prints the unknown key's phrase too, under a banner
        // of at signs, so the more specific one is looked for first.
        if text.contains("remote host identification has changed") { return .hostKeyChanged }
        if text.contains("host key verification failed")
            || text.contains("and you have requested strict checking") {
            return .hostKeyUnknown
        }
        if text.contains("permission denied") || text.contains("too many authentication failures") {
            return .authenticationRefused(deniedMethods(stderr))
        }
        if text.contains("connection refused") { return .connectionRefused }
        if text.contains("could not resolve hostname")
            || text.contains("name or service not known")
            || text.contains("nodename nor servname provided") {
            return .hostNotFound
        }
        if text.contains("operation timed out") || text.contains("connection timed out") {
            return .timedOut
        }
        if text.contains("network is unreachable") || text.contains("no route to host") {
            return .networkUnreachable
        }
        if text.contains("kex_exchange_identification")
            || text.contains("connection closed by remote host") {
            return .closedByRemote
        }

        // 255 is the status `ssh` reserves for its own failures. Anything else at this point is
        // the remote command's own answer and is not this type's business. A remote command CAN
        // exit 255 itself, which is why the phrases above are read before the status: by the time
        // this line is reached, nothing said connection.
        guard status == 255 else { return nil }
        let firstLine = stderr
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
        return firstLine.isEmpty ? .connectionDropped : .other(firstLine)
    }

    /// The bracketed method list out of "Permission denied (publickey,password)." Kept because it
    /// is the one fact that says whether the server would have taken a password if Bloom asked,
    /// and Bloom never asks, so the person reading has to know.
    private static func deniedMethods(_ stderr: String) -> String {
        guard let open = stderr.range(of: "Permission denied (", options: .caseInsensitive),
              let close = stderr.range(of: ")", range: open.upperBound..<stderr.endIndex) else {
            return ""
        }
        return String(stderr[open.upperBound..<close.lowerBound])
    }
}
