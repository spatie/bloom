import Foundation

/// A page that lives in the worktree rather than on a server, and what Bloom's browser may do
/// with one.
///
/// The request was "when an HTML file is selected, offer to open it in a browser tab or pane",
/// and the awkward half of it is that **Bloom serves nothing**. A workspace's port block is a set
/// of numbers its own setup and run scripts are told to bind, and the `http://127.0.0.1:8791/…`
/// an agent's report is read at belongs to a server that agent started inside the worktree and
/// that goes away with it. There is no route by which Bloom could hand a file of its own to a
/// browser over http, so the only address it can offer is a `file://` one, and that is why this
/// sits beside `BrowserAddress` rather than inside it: everything that type answers is about an
/// address a server is behind, and every one of these is about a path on this Mac.
public enum LocalPage {
    /// The extensions a browser opening is offered for.
    ///
    /// `html` and `htm` are the request. `svg` is in because the review pane is the reason it
    /// would be wanted: `FileMediaView.isMedia` refuses an SVG on purpose, since it conforms to
    /// `.sourceCode` as well as to `.image`, so the pane draws its XML and a browser is the only
    /// place in this window that draws the picture.
    ///
    /// Not `md`, and not `markdown`: Bloom has a Markdown viewer of its own, and WebKit handed a
    /// `.md` file shows the asterisks. Not `pdf`, and none of the images or the video: the review
    /// pane already draws those through `FileMediaView`, and an item offering a second and worse
    /// viewer for the file somebody is looking at reads as a mistake rather than as a choice.
    ///
    /// Lowercase, because that is what `isPage` compares against.
    public static let extensions: Set<String> = ["html", "htm", "svg"]

    /// Whether the name says this is a page, which is asked of the extension rather than of the
    /// bytes so that nothing is read to find out. Same trade as `FileMediaView.isMedia`.
    public static func isPage(path: String) -> Bool {
        extensions.contains((path as NSString).pathExtension.lowercased())
    }

    /// Whether the item is offered for a row at all.
    ///
    /// Absent rather than present and refusing, for the reason `FolderTerminal.canOpen` gives:
    /// the changed file list is drawn from a diff, so it holds a row for a file the agent has
    /// deleted, and that row is a name with no bytes behind it. A browser pane opened on one is a
    /// tab saying the file could not be found, which the reader then has to close.
    ///
    /// - Parameter path: absolute, because that is what a `file://` address is built from.
    public static func canOpen(file path: String) -> Bool {
        guard isPage(path: path) else { return false }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
            return false
        }
        return !isDirectory.boolValue
    }

    /// The address a browser tab is opened on, or nothing for a row this is not offered for.
    ///
    /// Built by `URL(filePath:)` rather than by putting `file://` in front of the string. A
    /// worktree holds folders with spaces in them, and `#` and `?` besides, and each of those
    /// means something else once a string is read as a URL: `notes/draft #2/index.html` written
    /// out by hand is an address ending at the space with a fragment hanging off it.
    public static func address(forFile path: String) -> String? {
        guard canOpen(file: path) else { return nil }
        return URL(filePath: path).absoluteString
    }

    /// The file a browser pane may actually load, given the worktree it belongs to.
    ///
    /// **The containment test is the whole point of this function.**
    /// `loadFileURL(_:allowingReadAccessTo:)` is the only way WebKit will fetch a local page's
    /// stylesheet, its script and its images, and the read access it takes is a directory: the
    /// worktree root, so a report generated into `docs/` reaches `assets/app.css` exactly as the
    /// same page would over http. Granting a page a whole worktree is only defensible while the
    /// page itself came out of that worktree, so an address naming anything else is refused here
    /// rather than loaded, and the address field goes through this too.
    ///
    /// `BrowserAddress.shows` still refuses every `file://` there is, and must keep refusing
    /// them: it is what `BrowserTab.openWindow` asks before a page's own `window.open` is
    /// honoured, so widening it would let a page from the network name a path on this Mac and
    /// have Bloom open it.
    public static func fileURL(from address: String, root: String) -> URL? {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !root.isEmpty, trimmed.hasPrefix("file://"),
              let url = URL(string: trimmed), url.isFileURL
        else { return nil }

        // The separator goes on before the comparison, so a worktree at `/w/bloom` cannot claim
        // the file at `/w/bloom-old/index.html`. Standardised on both sides so that a `..` in the
        // middle of the address is resolved before it is compared rather than after it is loaded.
        let base = URL(filePath: root, directoryHint: .isDirectory).standardizedFileURL.path
        let prefix = base.hasSuffix("/") ? base : base + "/"
        guard url.standardizedFileURL.path.hasPrefix(prefix) else { return nil }
        return url
    }
}
