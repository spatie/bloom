import Foundation

/// The rules for what the transcript does with an address: which schemes may be opened at all,
/// how an address is shortened into a menu title, and which addresses a run of prose offers.
///
/// This sat in the app target beside the views that apply it, which put the one security gate a
/// transcript has (an agent's `[text](anything-at-all)` markdown reaches it) where no test could
/// hold it. The drawing stays with the views; the decisions live here, next to `LinkScan`, which
/// finds the addresses these rules judge.
public enum LinkPolicy {
    /// Whether Bloom will hand this address to the browser at all.
    ///
    /// Everything in a transcript was written either by the user or by an agent, and an agent's
    /// text is downstream of whatever it read: a web page, an issue, a file in someone else's
    /// repository. So an address is a thing that can be *pressed*, never a thing that happens.
    /// Nothing opens on hover, on render, or on selection.
    ///
    /// The scheme is checked even though `LinkScan` only ever produces http and https, because
    /// the markdown parser also produces `[text](anything-at-all)` and that target is whatever
    /// the agent typed. `file:///Applications/Something.app` and a private scheme registered by
    /// some other app both go through this door otherwise. `mailto:` is allowed because a
    /// written `[write to me](mailto:...)` is a reasonable thing for an answer to contain and
    /// opening a compose window is not an action with consequences.
    public static func opens(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "https" || scheme == "http" || scheme == "mailto"
    }

    /// An address short enough to be a menu item's title, when there is more than one of them and
    /// the menu has to say which is which.
    public static func shortened(_ url: String) -> String {
        var value = url
        for scheme in ["https://", "http://"] where value.hasPrefix(scheme) {
            value.removeFirst(scheme.count)
        }
        guard value.count > 48 else { return value }
        return value.prefix(47) + "\u{2026}"
    }

    /// Every address in a run of plain text, in order and without repeats.
    public static func addresses(in text: String) -> [String] {
        addresses(of: LinkScan.links(in: text))
    }

    public static func addresses(of links: [DetectedLink]) -> [String] {
        deduplicated(links.map(\.url))
    }

    /// The same, for prose that has already been parsed. A markdown answer's addresses are not
    /// only the bare ones: `[the settings page](https://...)` never appears as an address in the
    /// text at all, and it is the one a reader is most likely to want to copy.
    public static func addresses(in blocks: [MarkdownBlock]) -> [String] {
        var found: [String] = []
        for block in blocks { collect(block, into: &found) }
        return deduplicated(found)
    }

    private static func collect(_ block: MarkdownBlock, into found: inout [String]) {
        switch block {
        case let .paragraph(inline):
            collect(inline, into: &found)
        case let .heading(_, inline):
            collect(inline, into: &found)
        case let .bulletList(items, _), let .numberedList(_, items, _):
            for item in items { for child in item { collect(child, into: &found) } }
        case let .taskList(items):
            for item in items { collect(item.inline, into: &found) }
        case let .blockQuote(blocks):
            for child in blocks { collect(child, into: &found) }
        case let .table(headers, rows, _):
            for header in headers { collect(header, into: &found) }
            for row in rows { for cell in row { collect(cell, into: &found) } }
        // A fenced block is quoted text, and a rule has nothing in it.
        case .codeBlock, .thematicBreak:
            break
        }
    }

    private static func collect(_ inline: [MarkdownInline], into found: inout [String]) {
        for value in inline {
            switch value {
            case let .link(text, url):
                if let parsed = URL(string: url), opens(parsed) { found.append(url) }
                collect(text, into: &found)
            case let .emphasis(children), let .strong(children), let .strikethrough(children):
                collect(children, into: &found)
            // A span of code is being quoted, and neither of the others can hold an address.
            case .text, .code, .lineBreak:
                break
            }
        }
    }

    private static func deduplicated(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.filter { seen.insert($0).inserted }
    }
}
