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
    /// Rendering and opening both check this policy. The opening check must use the current
    /// allowlist, because settings may have changed since a cached transcript was drawn.
    public static func opens(_ url: URL, allowedSchemes: Set<String> = []) -> Bool {
        guard let scheme = url.scheme?.lowercased(),
              TranscriptLinkPreferences.additionalScheme(scheme) != nil else { return false }
        return scheme == "https" || scheme == "http" || scheme == "mailto"
            || allowedSchemes.contains { TranscriptLinkPreferences.additionalScheme($0) == scheme }
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
    public static func addresses(in text: String, allowedSchemes: Set<String> = []) -> [String] {
        addresses(of: LinkScan.links(in: text, allowedSchemes: allowedSchemes))
    }

    public static func addresses(of links: [DetectedLink]) -> [String] {
        deduplicated(links.map(\.url))
    }

    /// The same, for prose that has already been parsed. A markdown answer's addresses are not
    /// only the bare ones: `[the settings page](https://...)` never appears as an address in the
    /// text at all, and it is the one a reader is most likely to want to copy.
    public static func addresses(in blocks: [MarkdownBlock], allowedSchemes: Set<String> = []) -> [String] {
        var found: [String] = []
        for block in blocks { collect(block, allowedSchemes: allowedSchemes, into: &found) }
        return deduplicated(found)
    }

    private static func collect(_ block: MarkdownBlock, allowedSchemes: Set<String>, into found: inout [String]) {
        switch block {
        case let .paragraph(inline):
            collect(inline, allowedSchemes: allowedSchemes, into: &found)
        case let .heading(_, inline):
            collect(inline, allowedSchemes: allowedSchemes, into: &found)
        case let .bulletList(items, _), let .numberedList(_, items, _):
            for item in items { for child in item { collect(child, allowedSchemes: allowedSchemes, into: &found) } }
        case let .taskList(items):
            for item in items { collect(item.inline, allowedSchemes: allowedSchemes, into: &found) }
        case let .blockQuote(blocks):
            for child in blocks { collect(child, allowedSchemes: allowedSchemes, into: &found) }
        case let .table(headers, rows, _):
            for header in headers { collect(header, allowedSchemes: allowedSchemes, into: &found) }
            for row in rows { for cell in row { collect(cell, allowedSchemes: allowedSchemes, into: &found) } }
        // A fenced block is quoted text, and a rule has nothing in it.
        case .codeBlock, .thematicBreak:
            break
        }
    }

    private static func collect(_ inline: [MarkdownInline], allowedSchemes: Set<String>, into found: inout [String]) {
        for value in inline {
            switch value {
            case let .link(text, url):
                if let parsed = URL(string: url), opens(parsed, allowedSchemes: allowedSchemes) { found.append(url) }
                collect(text, allowedSchemes: allowedSchemes, into: &found)
            case let .emphasis(children), let .strong(children), let .strikethrough(children):
                collect(children, allowedSchemes: allowedSchemes, into: &found)
            // A span of code is being quoted, and neither of the others can hold an address.
            case .text, .code, .lineBreak, .image:
                break
            }
        }
    }

    private static func deduplicated(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.filter { seen.insert($0).inserted }
    }
}
