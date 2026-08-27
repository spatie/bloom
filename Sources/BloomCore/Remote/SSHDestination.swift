import Foundation

/// Where an SSH command is going, as a value.
///
/// A destination is the one piece of a server that the user types, so it is the one piece that
/// can be hostile. It ends up as an argv word handed to `/usr/bin/ssh`, and the only thing argv
/// cannot defend itself against is a word that looks like an option: `-oProxyCommand=...` in the
/// host field is a local command execution, and it is spelled exactly like a host name. So a
/// leading dash is refused here, at the one place a destination can be made, rather than checked
/// at each of the places one is used.
///
/// A bare name with no dots is deliberately allowed. `ssh vps` is the whole feature: Bloom shells
/// out to the real client, so a `Host vps` block in `~/.ssh/config` carrying a jump host, an
/// identity file and a port already works, and refusing anything that does not look like a domain
/// would throw that away to catch nothing.
public struct SSHDestination: Sendable, Hashable, Codable {
    /// The user, when the destination named one. Nil leaves the answer to `~/.ssh/config` and to
    /// the local username, which is what `ssh` does on its own.
    public let user: String?
    public let host: String
    /// Only when the destination named one, because a port written here would override the port
    /// a `Host` block in `~/.ssh/config` chose.
    public let port: Int?

    /// What goes in argv, which is `user@host` or `host`. The port never rides along here: `ssh`
    /// takes it with `-p`, and `user@host:22` is read by `ssh` as a host called `host:22`.
    public var argument: String {
        guard let user else { return host }
        return "\(user)@\(host)"
    }

    /// What the screen shows, which is the destination as it was typed, port and all.
    public var display: String {
        guard let port else { return argument }
        return "\(argument):\(port)"
    }

    /// What a row is called before anybody renames it. The host without its domain, because
    /// "vps" reads better in a list than "vps.example.com" and the full destination is on the row
    /// underneath anyway.
    ///
    /// An address is left whole. `94.237.125.23` has dots in it and none of them separate a name
    /// from a domain, so the first-component rule would have called that server "94".
    public var suggestedLabel: String {
        let parts = host.components(separatedBy: ".")
        let looksNumeric = parts.count == 4 && parts.allSatisfy { UInt8($0) != nil }
        guard !looksNumeric, !host.contains(":"), let first = parts.first, !first.isEmpty else {
            return host
        }
        return first
    }

    public init(user: String?, host: String, port: Int? = nil) {
        self.user = user
        self.host = host
        self.port = port
    }
}

/// Why a typed destination was refused, in words the field under it can print.
public enum SSHDestinationProblem: Error, Sendable, Hashable, CustomStringConvertible {
    case empty
    case looksLikeAnOption
    case containsWhitespace
    case missingHost
    case missingUser
    case badPort(String)

    public var description: String {
        switch self {
        case .empty:
            "Type a destination, such as deploy@vps.example.com."
        case .looksLikeAnOption:
            "A destination cannot start with a dash. That is how an option is spelled, and ssh would read it as one."
        case .containsWhitespace:
            "A destination has no spaces in it."
        case .missingHost:
            "There is no host here. A destination is host or user@host."
        case .missingUser:
            "There is nothing in front of the @. Either name a user or leave the @ off."
        case .badPort(let text):
            "\(text) is not a port number."
        }
    }
}

public extension SSHDestination {
    /// Reads what somebody typed into the Add field.
    ///
    /// Deliberately strict about the three things that are a mistake every time (a dash at the
    /// front, a space in the middle, an empty half around the @) and deliberately quiet about
    /// everything else, because the set of things that is a valid host to `ssh` includes every
    /// alias in a config file this never reads.
    static func parse(_ text: String) throws -> SSHDestination {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SSHDestinationProblem.empty }
        guard !trimmed.hasPrefix("-") else { throw SSHDestinationProblem.looksLikeAnOption }
        guard trimmed.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else {
            throw SSHDestinationProblem.containsWhitespace
        }

        var user: String?
        var remainder = Substring(trimmed)
        // The FIRST @, not the last: a username cannot contain one, and a host certainly cannot,
        // so anything after a second @ is part of the host and is left for `ssh` to reject.
        if let at = remainder.firstIndex(of: "@") {
            let name = remainder[remainder.startIndex..<at]
            guard !name.isEmpty else { throw SSHDestinationProblem.missingUser }
            user = String(name)
            remainder = remainder[remainder.index(after: at)...]
        }

        // A bracketed literal is how IPv6 is written when a port follows it, and the brackets are
        // the only way to tell `[::1]:22` from an address whose last group is 22.
        var host = String(remainder)
        var port: Int?
        if host.hasPrefix("["), let close = host.firstIndex(of: "]") {
            let inside = host[host.index(after: host.startIndex)..<close]
            let tail = host[host.index(after: close)...]
            if tail.hasPrefix(":") {
                port = try readPort(String(tail.dropFirst()))
            }
            host = String(inside)
        } else if let colon = host.lastIndex(of: ":"), !host.contains("::") {
            // One colon and no `::` is host:port. An unbracketed address with several colons is
            // an IPv6 literal with no port, and splitting it would eat its last group.
            let after = host[host.index(after: colon)...]
            if host.firstIndex(of: ":") == colon {
                port = try readPort(String(after))
                host = String(host[host.startIndex..<colon])
            }
        }

        guard !host.isEmpty else { throw SSHDestinationProblem.missingHost }
        guard !host.hasPrefix("-") else { throw SSHDestinationProblem.looksLikeAnOption }
        return SSHDestination(user: user, host: host, port: port)
    }

    private static func readPort(_ text: String) throws -> Int {
        guard let value = Int(text), value > 0, value <= 65_535 else {
            throw SSHDestinationProblem.badPort(text.isEmpty ? "An empty port" : text)
        }
        return value
    }
}
