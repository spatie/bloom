import Foundation

/// How the address field draws an address nobody is typing into: the host in reading ink, the rest
/// a rung down, and a glyph for what the connection is.
///
/// **The host comes from the parser, never from a search through the string.**
/// `https://spatie.be@evil.com/login` is served by evil.com, and anything that emphasised the
/// first match for a familiar name would put the strong ink on what is really a username. Every
/// part below is taken from `URLComponents` and reassembled in order, so the three runs still
/// spell the address the page is at.
public struct BrowserAddressDisplay: Equatable, Sendable {
    /// The scheme, and any user and password, drawn a rung down.
    public var leading: String
    /// The host and port, in reading ink. Empty when the address has no host to speak of.
    public var host: String
    /// Path, query and fragment, a rung down.
    public var trailing: String
    public var security: Security

    /// Nothing to draw, so the field shows its placeholder.
    public var isEmpty: Bool { leading.isEmpty && host.isEmpty && trailing.isEmpty }

    /// What the glyph at the left end of the field says about the connection.
    public enum Security: Equatable, Sendable {
        /// No address yet.
        case none
        /// A server on this Mac, which is what this pane is mostly pointed at.
        case local
        /// Plain http somewhere else.
        case insecure
        case secure

        public var symbol: String? {
            switch self {
            case .none: nil
            case .local: "desktopcomputer"
            case .insecure: "globe"
            case .secure: "lock.fill"
            }
        }

        public var help: String? {
            switch self {
            case .none: nil
            case .local: "A server on this Mac"
            case .insecure: "This connection is not encrypted"
            case .secure: "This connection is encrypted"
            }
        }
    }

    /// The most of an address anybody draws. URLs of several kilobytes exist, and one of them
    /// would otherwise be laid out in full behind a field 300 points wide.
    public static let limit = 512

    public static func of(_ address: String) -> BrowserAddressDisplay {
        let text = sanitised(address)
        // `encodedHost` rather than the host itself, so a name written with percent escapes or in
        // punycode is drawn as the parser sees it. Decoding is how two different hosts come to
        // look like one.
        guard let parts = URLComponents(string: text),
              let host = parts.encodedHost, !host.isEmpty
        else {
            return BrowserAddressDisplay(leading: text, host: "", trailing: "", security: .none)
        }

        let scheme = parts.scheme?.lowercased()
        var leading = scheme.map { $0 + "://" } ?? ""
        if let user = parts.percentEncodedUser {
            let password = parts.percentEncodedPassword.map { ":" + $0 } ?? ""
            leading += user + password + "@"
        }

        var trailing = parts.percentEncodedPath
        if let query = parts.percentEncodedQuery { trailing += "?" + query }
        if let fragment = parts.percentEncodedFragment { trailing += "#" + fragment }

        return BrowserAddressDisplay(
            leading: leading,
            host: host + (parts.port.map { ":\($0)" } ?? ""),
            trailing: trailing,
            security: security(scheme: scheme, host: host)
        )
    }

    private static func security(scheme: String?, host: String) -> Security {
        switch scheme {
        case "https": .secure
        case "http": BrowserAddress.isLocal(host: host) ? .local : .insecure
        default: .none
        }
    }

    /// Control characters and the bidirectional overrides, out.
    ///
    /// A right-to-left override in a path reverses what is drawn after it, which is how a file
    /// ending `.exe` can be made to read as ending `.png`. The address is a string from the
    /// network on its way onto screen, so it gets the treatment `BrowserTabTitle.tidy` gives a
    /// title.
    private static func sanitised(_ raw: String) -> String {
        let kept = raw.unicodeScalars.filter { scalar in
            switch scalar.value {
            case 0..<0x20, 0x7F, 0x200E, 0x200F, 0x202A...0x202E, 0x2066...0x2069: false
            default: true
            }
        }
        let text = String(String.UnicodeScalarView(kept))
        return text.count > limit ? String(text.prefix(limit)) + "…" : text
    }
}
