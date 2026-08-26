import CryptoKit
import Foundation

/// One `<link>` a page declares that might be its icon, as the document reported it.
///
/// `href` is `link.href`, which the document has already resolved against its own base. It is
/// still a string from the network, so nothing here believes it until `URL` has parsed it.
public struct BrowserFaviconLink: Equatable, Sendable {
    public var rel: String
    public var sizes: String
    public var type: String
    public var href: String

    public init(rel: String, sizes: String = "", type: String = "", href: String) {
        self.rel = rel
        self.sizes = sizes
        self.type = type
        self.href = href
    }
}

/// Which icon a browser tab wears, and what Bloom will accept as one.
///
/// **`WKWebView` has no favicon.** All of WebKit's public icon surface is on `WebView`, the
/// framework it replaced: `mainFrameIcon` and `webView:didReceiveIcon:forFrame:`, both deprecated
/// and neither reachable from a `WKWebView`. Measured rather than assumed, the only match for
/// "favicon" under the macOS 26 SDK's `WebKit.framework/Headers` is a comment in
/// `WebFrameLoadDelegate.h`. Safari uses `_WKIconLoadingDelegate`, which is in no public header.
/// So the page is asked instead, and `BrowserFaviconScript` is what it is asked.
///
/// **There is no guess at `/favicon.ico`.** Most sites of the last decade declare their icon and
/// serve something stale or nothing at that path, so the guess is wrong exactly where it matters,
/// and it is Bloom opening a connection to whichever host a page happens to be on for a file
/// nobody asked for. An icon a page does not declare is one Bloom does not go looking for.
///
/// **What comes back is never the page's own bytes.** The page rasterises its icon into a canvas
/// Bloom sized and hands back a PNG of that, so no ICO parser, no SVG renderer and no image of a
/// page's choosing runs in this process. `read` is the gate on the way in.
public enum BrowserFavicon {
    /// The square the page draws into, in device pixels. The strip draws the result at 14 points,
    /// so 28 is what a two times display asks for and this is the next power of two up.
    public static let pixels = 32

    /// How many declarations are considered. A page with more than this many is not a page with a
    /// better icon further down.
    public static let linkLimit = 16

    /// The most of any one attribute that crosses back. A `sizes` attribute is normally five
    /// characters and a page is free to make it five megabytes.
    public static let textLimit = 2_048

    /// How long the page may spend loading its own icon, in milliseconds. An image element that
    /// fires neither event otherwise leaves the call outstanding for as long as the tab is open.
    public static let loadTimeout = 5_000

    /// When the page is asked, in milliseconds after it finishes loading, and then again.
    ///
    /// Twice, because a framework that writes its `<link rel=icon>` from script has not written it
    /// by `didFinish`. The alternative is a `MutationObserver` living in the page for as long as
    /// the tab is open, and this pane deliberately has no injected script.
    public static let attempts = [250, 1_500]

    /// The most bytes a decoded icon may be. Well past anything the canvas can produce.
    public static let byteLimit = 24 * 1_024

    /// The only thing `read` will look at.
    public static let dataPrefix = "data:image/png;base64,"

    /// The longest data URL worth reading: the byte cap through base64, plus the prefix.
    public static let dataLimit = dataPrefix.count + ((byteLimit + 2) / 3) * 4

    /// How many origins are kept on disk. Losing the file costs one globe per site until each is
    /// next visited.
    public static let cacheLimit = 128

    /// The eight bytes every PNG starts with.
    private static let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]

    /// How many strings the script sends per declaration.
    private static let fields = 4

    // MARK: - Which page an icon belongs to

    /// What an icon is filed under: scheme, host and port, with the port filled in.
    ///
    /// **The origin rather than the page**, because a site has one icon and a tab walking twenty
    /// of its pages should ask once. It is also what stops the strip flickering, for free: a link
    /// followed inside a host keeps the key, so the lookup keeps hitting and the icon stays up
    /// while the next page loads. That is the rule `BrowserTabTitle.survives` applies to the name
    /// beside it.
    ///
    /// Nil for anything that is not http or https, which is `about:blank`, a `file:` page and the
    /// empty address a pane split open on nothing carries. All three are the globe, decided here
    /// rather than in three places.
    public static func origin(of address: String) -> String? {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host()?.lowercased(),
              !host.isEmpty
        else { return nil }

        let port = url.port ?? (scheme == "https" ? 443 : 80)
        return "\(scheme)://\(host):\(port)"
    }

    /// The file one origin's icon is cached in.
    ///
    /// A digest rather than the origin, so nothing a host is called can become a path: a host may
    /// hold a dot, a colon and, through percent escapes, a slash.
    public static func fileName(for origin: String) -> String {
        let digest = SHA256.hash(data: Data(origin.utf8))
        return digest.map { String(format: "%02x", $0) }.joined() + ".png"
    }

    // MARK: - Which declaration is asked for

    /// What the page said, read back out of the flat list the script sends.
    ///
    /// Flat because `callAsyncJavaScript` marshals arrays of strings and not objects worth
    /// trusting the shape of. A length that is not a multiple of four is not an answer to this
    /// question, and is dropped whole rather than read as far as it goes.
    public static func links(from values: [String]) -> [BrowserFaviconLink] {
        guard !values.isEmpty, values.count % fields == 0 else { return [] }
        return stride(from: 0, to: values.count, by: fields).map { start in
            BrowserFaviconLink(
                rel: values[start],
                sizes: values[start + 1],
                type: values[start + 2],
                href: values[start + 3]
            )
        }
    }

    /// The one declaration worth asking for, and where it is in the list.
    ///
    /// **The index is the answer, not a detail of it.** The bytes are fetched by a second call
    /// naming the declaration by position rather than by address, so no string from the network
    /// travels back into a script. See `BrowserFaviconScript`.
    ///
    /// The order is what a browser picks by. An icon at least as big as the square it will be
    /// drawn in comes first, smallest such first, because it needs the least resampling. An icon
    /// declaring no size comes next: `<link rel=icon href=/favicon.ico>` on its own is the most
    /// common declaration there is, and ranking it under a declared 16x16 would pick the blurry
    /// one on most of the web. A size too small comes last, largest first. Within a tier, `icon`
    /// beats `apple-touch-icon`, which is a home screen tile with its own padding rather than a
    /// mark for a 14 point row, and after that the page's own order decides.
    public static func choose(from links: [BrowserFaviconLink]) -> Choice? {
        let ranked = links.prefix(linkLimit).enumerated().compactMap { index, link in
            Ranked(index: index, link: link)
        }
        guard let best = ranked.min(by: Ranked.precedes) else { return nil }
        return Choice(index: best.index, url: best.url)
    }

    /// Which declaration the page is asked for, and what it said that was.
    public struct Choice: Equatable, Sendable {
        /// Its position in the list the page reported, which is how the page is asked for it.
        public var index: Int
        /// Where it says the icon is. Only http and https get this far.
        public var url: URL

        public init(index: Int, url: URL) {
            self.index = index
            self.url = url
        }
    }

    /// One declaration with everything the ordering needs read out of it.
    private struct Ranked {
        var index: Int
        var url: URL
        var kind: Kind
        /// The largest square it claims, or nil for one that claims nothing and for `sizes="any"`,
        /// which is a vector saying it will draw at whatever size is asked.
        var size: Int?

        enum Kind: Int {
            case icon
            case appleTouch
        }

        /// Nil for a declaration Bloom will not ask for: a `rel` naming no icon, an href that will
        /// not parse, and any scheme but http and https. That last is what keeps `data:` and
        /// `javascript:` out, and it is a filter rather than an oversight.
        init?(index: Int, link: BrowserFaviconLink) {
            let tokens = Set(
                link.rel.lowercased().components(separatedBy: .whitespacesAndNewlines)
                    .filter { !$0.isEmpty }
            )
            if tokens.contains("icon") {
                kind = .icon
            } else if tokens.contains("apple-touch-icon")
                || tokens.contains("apple-touch-icon-precomposed") {
                kind = .appleTouch
            } else {
                return nil
            }

            guard let url = URL(string: link.href.trimmingCharacters(in: .whitespacesAndNewlines)),
                  let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https",
                  url.host()?.isEmpty == false
            else { return nil }

            self.index = index
            self.url = url
            size = BrowserFavicon.square(in: link.sizes)
        }

        /// Which tier the ordering puts it in. See `choose` for the argument.
        var tier: Int {
            guard let size else { return 1 }
            return size >= BrowserFavicon.pixels ? 0 : 2
        }

        static func precedes(_ one: Ranked, _ other: Ranked) -> Bool {
            if one.tier != other.tier { return one.tier < other.tier }
            if let mine = one.size, let theirs = other.size, mine != theirs {
                // Above the square, the smallest that still covers it. Below it, the largest there
                // is.
                return one.tier == 0 ? mine < theirs : mine > theirs
            }
            if one.kind != other.kind { return one.kind.rawValue < other.kind.rawValue }
            return one.index < other.index
        }
    }

    /// The largest square a `sizes` attribute claims.
    ///
    /// `any` is a vector and claims nothing, which is not the same as claiming zero. Anything
    /// unparseable is read the same way: a page writing nonsense here has told us nothing, not
    /// told us it is small.
    private static func square(in sizes: String) -> Int? {
        let tokens = sizes.lowercased().components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
        guard !tokens.isEmpty, !tokens.contains("any") else { return nil }

        let squares = tokens.compactMap { token -> Int? in
            let parts = token.components(separatedBy: "x")
            guard parts.count == 2,
                  let width = Int(parts[0]), let height = Int(parts[1]),
                  width > 0, height > 0
            else { return nil }
            // The short side, because that is what has to cover the square it is drawn in.
            return min(width, height)
        }
        return squares.max()
    }

    // MARK: - What is accepted as an icon

    /// The bytes of an icon, out of the data URL the page's canvas produced.
    ///
    /// Four things have to be true. The prefix is compared whole, so `data:image/svg+xml,` and a
    /// `;charset=` slipped into the middle are refused rather than parsed leniently. The length is
    /// capped before any decoding, so a page cannot make Bloom allocate its way through a
    /// megabyte. And the decoded bytes have to open with the PNG signature, because the label on a
    /// data URL is written by whoever wrote the URL.
    public static func read(_ dataURL: String) -> Data? {
        guard dataURL.count <= dataLimit, dataURL.hasPrefix(dataPrefix) else { return nil }

        let encoded = String(dataURL.dropFirst(dataPrefix.count))
        guard !encoded.isEmpty, let data = Data(base64Encoded: encoded) else { return nil }
        guard data.count <= byteLimit, data.starts(with: signature) else { return nil }
        return data
    }
}
