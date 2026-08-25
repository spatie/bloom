import Foundation

/// Who is asking, said the way a browser says it.
///
/// A page can raise two things that look like they came from Bloom: a file panel, and (once the
/// dialogs land) an alert. Both are chrome the reader trusts, and a page that writes "Bloom needs
/// your password" into one of them is doing the oldest trick there is. Every browser answers this
/// the same way, by naming the origin on the panel itself, and that is what this is for: the
/// sentence the reader sees says which site asked, in Bloom's words, above whatever the page
/// wrote.
///
/// It takes the three parts rather than a `WKSecurityOrigin` because the core imports no UI
/// framework and WebKit is one. The app pulls `protocol`, `host` and `port` off the frame and
/// hands them over.
public enum BrowserPageOrigin {
    /// What to call the page asking, which is host and port and nothing else.
    ///
    /// **No scheme and no path.** A path is where a page can write anything it likes (a site can
    /// serve `/Bloom Support: enter your token/` and have it appear in the sentence), and the
    /// scheme is noise next to a dev server the reader started themselves. Host and port are the
    /// two parts a page cannot forge, and the port is what tells one worktree's server from
    /// another's, which is the distinction that matters most in this window.
    ///
    /// The port is dropped when it is the default for the scheme, because "example.com:443" is
    /// how nothing on the platform writes it. An origin with no host at all is not a site: it is
    /// a document loaded from a string or a file, and there is no name to give it.
    public static func name(scheme: String, host: String, port: Int) -> String? {
        let host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else { return nil }

        let scheme = scheme.lowercased()
        let isDefaultPort = (scheme == "https" && (port == 443 || port == 0))
            || (scheme == "http" && (port == 80 || port == 0))
        return isDefaultPort ? host : "\(host):\(port)"
    }

    /// The line above a file panel a page raised.
    ///
    /// It names the page, for the reason above, and it says what happens next rather than what to
    /// click: a file chosen here is a file handed to that site, and a reader who has forgotten
    /// which tab put the panel up should be able to read that off the panel.
    public static func uploadMessage(from name: String?, allowsMultiple: Bool) -> String {
        let what = allowsMultiple ? "the files" : "the file"
        guard let name else { return "Choose \(what) you want to give this page." }
        return "Choose \(what) you want to give \(name)."
    }
}
