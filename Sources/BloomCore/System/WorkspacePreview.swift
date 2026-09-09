import Foundation

/// One-shot navigation belongs only to the untouched browser a workspace was created with.
public enum WorkspacePreview {
    public enum Opening: Equatable, Sendable {
        case wait
        case discard
        case open(String)
    }

    public static func address(port: Int) -> String? {
        guard (1...65_535).contains(port) else { return nil }
        return "http://localhost:\(port)"
    }

    public static func opening(
        pending: Bool, setup: SetupState, port: Int, address: String,
        storedAddress: String, hasNavigated: Bool
    ) -> Opening {
        guard pending, address.isEmpty, storedAddress.isEmpty, !hasNavigated else { return .discard }
        switch setup {
        case .pending, .running, .failed: return .wait
        case .succeeded, .skipped:
            guard let url = self.address(port: port) else { return .wait }
            return .open(url)
        }
    }
}

/// Keeps a workspace URL stable while the SSH port or HTTPS preview origin changes underneath it.
public struct BrowserPreviewAddress: Equatable, Sendable {
    public let original: URL
    public let resolved: URL

    public init?(original: String, resolved: String) {
        guard let source = BrowserAddress.url(from: original), BrowserAddress.shows(source), ServerPreview.isLoopback(source),
              let target = BrowserAddress.url(from: resolved), BrowserAddress.shows(target),
              source.user == nil, source.password == nil, target.user == nil, target.password == nil,
              source.path == target.path, source.query == target.query, source.fragment == target.fragment else { return nil }
        self.original = source
        self.resolved = target
    }

    public func display(_ address: String) -> String? {
        guard let current = URL(string: address),
              current.scheme?.lowercased() == resolved.scheme?.lowercased(),
              current.host?.lowercased() == resolved.host?.lowercased(),
              Self.port(current) == Self.port(resolved), current.user == nil, current.password == nil,
              var parts = URLComponents(url: current, resolvingAgainstBaseURL: false) else { return nil }
        parts.scheme = original.scheme
        parts.host = original.host
        parts.port = original.port
        return parts.string
    }

    private static func port(_ url: URL) -> Int {
        url.port ?? (url.scheme?.lowercased() == "https" ? 443 : 80)
    }
}
