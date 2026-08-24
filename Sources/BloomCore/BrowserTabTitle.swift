import Foundation

/// What a browser tab is called, given what the page says about itself.
///
/// Safari's tab reads "Spatie" when the page at `https://spatie.be/` says so, and Bloom's read
/// "Browser" whatever was in it. A strip of three of them was three tabs with the same name.
///
/// ## The chain
///
/// In order, first one that answers:
///
/// 1. **A name the user typed.** Renaming a tab is a statement about what it is for, and a page
///    that navigates must not wipe it out. This is the whole reason `CenterTab.isNamed` exists:
///    "Browser" is not a name, and neither is "Browser 2", but a tab called those cannot be told
///    from one somebody deliberately called "Browser" by looking at the string.
/// 2. **The page's own title**, tidied and capped by `tidy`.
/// 3. **The host**, with `www.` off and the port kept, so a dev server reads `localhost:3000` and
///    not `localhost`, which is what three of them at once would each say.
/// 4. **The tab's own name**, which is `Browser` or `Browser 2`. Reached by `about:blank`, by a
///    tab split open on nothing, and by a `file:` url, none of which have a host.
///
/// ## Loading
///
/// The title arrives well after the navigation starts, and WebKit clears `title` in between, so
/// something has to be shown for a second or so. The three candidates are the previous title, the
/// host, and the word "Loading", and the rule here is **the previous title, unless the host has
/// changed**. Not "Loading": that is a third string, and a tab that reads Spatie, then Loading,
/// then GitHub in one second flickers, which is exactly what a label you navigate by must not do.
///
/// The host is what makes it honest. Following a link inside `spatie.be` keeps "Spatie" up while
/// the next page loads, which is right, because it is still that site. Typing a different address
/// drops it at once and shows the new host, so the tab never claims to be a page you have left.
/// `survives(navigationFrom:to:)` is that rule and it is the only thing that ever clears a title.
///
/// ## What the page is not trusted about
///
/// A `<title>` is a string from the network and it goes on screen, so `tidy` takes it apart:
/// control characters and newlines out, so a title cannot draw a second line or reorder the row;
/// runs of space collapsed; and a hard character cap, because titles of several kilobytes exist
/// and one of them would otherwise reach the tooltip, the accessibility label and the rename
/// field intact. The cap is well past what the tab's own 200 points can show, so the ellipsis it
/// adds is not normally the one the reader sees: the tab truncates to its width first, at the
/// tail, which is where a page title's boilerplate suffix lives and Safari cuts in the same
/// place.
public enum BrowserTabTitle {
    /// The most of a page title anybody keeps.
    ///
    /// Generous on purpose. A tab is 200 points and shows perhaps thirty characters of it, so this
    /// is not the truncation the reader sees; it is the one that stops a page from putting four
    /// kilobytes into a tooltip. Cutting nearer the visible width would throw away the end of
    /// titles that the strip can show in full when the window is wide.
    public static let limit = 80

    /// One line of plain text, or empty.
    public static func tidy(_ raw: String?) -> String {
        guard let raw else { return "" }

        // Control characters become spaces rather than being dropped: a tab between two words is
        // a word break, and deleting it outright joins them. The same reasoning, and the same
        // treatment, as `WorkspaceNaming.cleanName`.
        let flattened = String(String.UnicodeScalarView(raw.unicodeScalars.map {
            $0.value < 0x20 || $0.value == 0x7F ? " " : $0
        }))

        let collapsed = flattened
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        guard collapsed.count > limit else { return collapsed }

        // At a word boundary when there is one near the end, so the cut does not land in the
        // middle of a word. Half the limit is the furthest back it will reach for one, past which
        // a title with no spaces in it is simply cut.
        let cut = collapsed.prefix(limit)
        if let space = cut.lastIndex(of: " "), cut.distance(from: cut.startIndex, to: space) > limit / 2 {
            return String(cut[..<space]) + "…"
        }
        return String(cut) + "…"
    }

    /// The host a tab shows when the page has no title of its own: `spatie.be`, `localhost:3000`.
    ///
    /// `www.` comes off, because it is four characters of nothing in a label this narrow and no
    /// browser has shown it for fifteen years. The port stays: a workspace's dev server IS its
    /// port, and it is the only thing telling two of them apart.
    ///
    /// Nil for anything with no host to speak of, which is `about:blank`, a `file:` url, and the
    /// empty string a pane split open on nothing carries.
    public static func host(of address: String) -> String? {
        guard let url = URL(string: address.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = url.host(), !host.isEmpty
        else { return nil }

        let bare = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        guard !bare.isEmpty else { return nil }
        guard let port = url.port else { return bare }
        return "\(bare):\(port)"
    }

    /// Whether the title a tab is showing still describes where the page is going.
    ///
    /// Same host, same title. That is the whole rule: a link followed inside a site is the same
    /// site, and holding its name up for the second the next page takes is what stops the strip
    /// flickering. A different host is a different place and the tab says so at once.
    ///
    /// A move to an address with no host at all, which is `about:blank`, does not survive either:
    /// a blank page is not the page you were reading.
    public static func survives(navigationFrom old: String, to new: String) -> Bool {
        guard let from = host(of: old), let to = host(of: new) else { return false }
        return from == to
    }

    /// Where a browser tab is and what the page there says it is called: the pair, because
    /// neither of them means anything without the other.
    public struct BrowserPage: Equatable, Sendable {
        public var address: String
        public var title: String

        public init(address: String = "", title: String = "") {
            self.address = address
            self.title = title
        }
    }

    /// What a tab remembers once the page has moved, renamed itself, or both.
    ///
    /// **One function for both events, because they arrive together and the order they arrive in
    /// is not something a view can promise.** Written as two writes, a title landing a frame
    /// before the navigation that brought it was stored and then cleared by that navigation, and
    /// the tab sat on the host until the reader clicked something else. Here there is one answer
    /// and no window between two of them.
    ///
    /// - Parameter tab: what the tab is showing now.
    /// - Parameter page: what the web view says. An empty title is WebKit between two documents
    ///   and means "no news", never "no title".
    public static func advance(from tab: BrowserPage, to page: BrowserPage) -> BrowserPage {
        // An empty address is the web view not having moved rather than having moved to nowhere,
        // so it is resolved before anything is asked about where the tab has got to. Taken the
        // other way round, a title arriving with no navigation beside it looked like a move off
        // the host and cleared the name it had come to set.
        let address = page.address.isEmpty ? tab.address : page.address
        let kept = survives(navigationFrom: tab.address, to: address) ? tab.title : ""
        let arrived = tidy(page.title)
        return BrowserPage(address: address, title: arrived.isEmpty ? kept : arrived)
    }

    /// What the strip draws on a browser tab.
    ///
    /// - Parameter page: the last title the page reported, already through `tidy` and already
    ///   cleared if the tab has since left that host. Empty while a first page loads.
    /// - Parameter address: where the page is.
    /// - Parameter fallback: the tab's own name, which is `Browser` or `Browser 2`.
    /// - Parameter isNamed: the user renamed this tab, in which case nothing else is consulted.
    public static func title(
        page: String, address: String, fallback: String, isNamed: Bool = false
    ) -> String {
        if isNamed { return fallback }

        let page = tidy(page)
        // A page with no `<title>` gets one from WebKit anyway, and it is the address or the last
        // path component of it. That is not a name, it is the thing in the address bar directly
        // above, so the host below reads better and is shorter.
        if !page.isEmpty, page != address, host(of: address).map({ page != $0 }) ?? true {
            return page
        }
        return host(of: address) ?? fallback
    }
}
