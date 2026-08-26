import Foundation

/// What the browser tab's address field accepts, and what it turns the text into.
///
/// This sat on `BrowserSession` in the app target, which put the one rule about what counts as
/// an address where no test could hold it, and `BrowserTab.canOpen` leans on the same rule for
/// which links offer an in-app tab at all: two surfaces, one policy, so it lives here.
public enum BrowserAddress {
    /// Localhost first, because that is what a workspace's dev server is and what the tab opens
    /// on. A bare host gets `http`, since a development server rarely has a certificate, and
    /// anything with no dot and no scheme is not an address at all.
    public static func url(from text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(" ") else { return nil }

        if trimmed.contains("://") { return URL(string: trimmed) }

        let host = trimmed.split(separator: "/", maxSplits: 1).first.map(String.init) ?? trimmed
        let local = isLocal(host: host)
        guard local || host.contains(".") else { return nil }
        return URL(string: (local ? "http://" : "https://") + trimmed)
    }

    /// A server on this Mac, with or without a port on the end.
    ///
    /// Read twice: here, to decide that a bare host gets `http` rather than `https`, and by
    /// `BrowserAddressDisplay`, to decide that plain http is a dev server rather than something to
    /// warn about. One policy, so the field cannot call an address local and the parser not.
    public static func isLocal(host: String) -> Bool {
        host.hasPrefix("localhost") || host.hasPrefix("127.0.0.1")
            || host.hasPrefix("0.0.0.0") || host.hasSuffix(".localhost")
    }

    /// Whether a browser of Bloom's own could show this address at all.
    ///
    /// A `WKWebView` speaks http and https. A `mailto:` is a perfectly good link for a plain click
    /// and is not something to open a blank pane onto, so the items that would do that are absent
    /// rather than present and useless. The rest is asked of `url(from:)` above, because that is
    /// what will actually be handed the string a moment later.
    ///
    /// This was `BrowserTab.canOpen`, in the app target, which is where the transcript's menu could
    /// reach it and `TranscriptLinkMenu` could not. `BrowserTab` still carries the one door onto a
    /// browser tab; the question of what counts as an address it could show is asked here, next to
    /// the parser that answers it.
    public static func shows(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return false
        }
        return self.url(from: url.absoluteString) != nil
    }
}
