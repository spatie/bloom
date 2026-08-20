import SwiftUI
import AppKit
import BloomCore

/// Everything the transcript does with an address written in the text it draws.
///
/// Three call sites share this: the user's own bubble, which is plain text and never sees the
/// markdown parser; an agent's answer, which does; and the appearance sample in settings. They
/// share it so that one line of text reads the same way whoever wrote it, and so that the rule
/// about what may be opened is written down once.
enum TranscriptLink {
    // MARK: Drawing

    /// Plain text with every address in it underlined, tinted and pressable.
    ///
    /// The user's turn is the only prose in this window drawn exactly as it was typed. It goes
    /// nowhere near `MarkdownParser` on purpose, because a question with a `*` in it is a question
    /// with a `*` in it and not a request for italics. So it needs its own pass over the same
    /// detection, which is `LinkScan` in the core: tested there, and shared with the parser so
    /// both halves of a conversation agree about what an address is and what a file path is.
    ///
    /// Only the link runs carry a colour. Everything else is left without one so it inherits
    /// whatever `foregroundStyle` the caller set, which inside the bubble is white and outside it
    /// is the page's ink.
    static func attributed(_ text: String, tint: Color) -> AttributedString {
        attributed(text, links: LinkScan.links(in: text), tint: tint)
    }

    /// The same, for a caller that has already scanned the text and wants the addresses as well.
    /// One pass, because the bubble needs both the styled string and the list for its menu.
    static func attributed(_ text: String, links: [DetectedLink], tint: Color) -> AttributedString {
        var output = AttributedString()
        var cursor = text.startIndex

        for found in links {
            guard let url = URL(string: found.url), opens(url) else { continue }
            if cursor < found.range.lowerBound {
                output += AttributedString(String(text[cursor..<found.range.lowerBound]))
            }
            var span = AttributedString(found.text)
            span.foregroundColor = tint
            // Not decoration. It is what makes the link findable without colour vision, and on the
            // filled bubble, where the tint has to clear a saturated ground and ends up close to
            // the white around it, it is most of what says this word is a door.
            span.underlineStyle = .single
            span.link = url
            output += span
            cursor = found.range.upperBound
        }

        if cursor < text.endIndex {
            output += AttributedString(String(text[cursor...]))
        }
        return output
    }

    /// The same text as an `NSAttributedString`, for `TranscriptTextView`.
    ///
    /// Only the `.link` attribute is set on an address here. Its colour and its underline are the
    /// text view's business, because they are not properties of the text: the colour comes from
    /// `linkTextAttributes` and the underline appears only while the pointer is on it. Putting
    /// either in the string would make a link underlined at rest again, and would put an
    /// underline into anything that copied it out.
    static func attributedString(
        _ text: String,
        links: [DetectedLink],
        font: NSFont,
        color: NSColor,
        lineSpacing: CGFloat
    ) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = lineSpacing
        paragraph.alignment = .left
        // A long address has no spaces to break at, so without this it lays out as one line and
        // takes the bubble off the pane. Character wrapping is only reached when a word cannot
        // fit, which for prose is never.
        paragraph.lineBreakMode = .byWordWrapping

        let output = NSMutableAttributedString(
            string: text,
            attributes: [
                .font: font,
                .foregroundColor: color,
                .paragraphStyle: paragraph,
            ]
        )

        for found in links {
            guard let url = URL(string: found.url), opens(url) else { continue }
            let range = NSRange(found.range, in: text)
            output.addAttribute(.link, value: url, range: range)
        }
        return output
    }

    /// What a transcript row does with an address, in one place so every row does the same.
    ///
    /// A plain click goes to the system's browser. The in-app tab is only ever reached by
    /// choosing it from the menu, which is the difference the owner asked for: opening a page is
    /// an action, and the quieter of the two destinations is the one that has to be asked for.
    @MainActor
    static func actions(for model: WorkspaceModel?) -> TranscriptLinkActions {
        TranscriptLinkActions(
            open: { url, target in
                switch target {
                case .externalBrowser:
                    guard opens(url) else { return }
                    NSWorkspace.shared.open(url)
                case .browserTab:
                    guard let model else { return }
                    BrowserTab.open(url, in: model)
                }
            },
            canOpenInTab: { url in
                model != nil && BrowserTab.canOpen(url)
            }
        )
    }

    // MARK: Opening

    /// Whether Bloom will hand this address to the browser at all.
    ///
    /// Everything in a transcript was written either by the user or by an agent, and an agent's
    /// text is downstream of whatever it read: a web page, an issue, a file in someone else's
    /// repository. So an address is a thing that can be *pressed*, never a thing that happens.
    /// Nothing here opens on hover, on render, or on selection.
    ///
    /// The scheme is checked a second time even though `LinkScan` only ever produces http and
    /// https, because the markdown parser also produces `[text](anything-at-all)` and that target
    /// is whatever the agent typed. `file:///Applications/Something.app` and a private scheme
    /// registered by some other app both go through this door otherwise. `mailto:` is allowed
    /// because a written `[write to me](mailto:...)` is a reasonable thing for an answer to
    /// contain and opening a compose window is not an action with consequences.
    static func opens(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "https" || scheme == "http" || scheme == "mailto"
    }

    // MARK: Copying

    static func copy(_ url: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(url, forType: .string)
    }

    /// An address short enough to be a menu item's title, when there is more than one of them and
    /// the menu has to say which is which.
    static func shortened(_ url: String) -> String {
        var value = url
        for scheme in ["https://", "http://"] where value.hasPrefix(scheme) {
            value.removeFirst(scheme.count)
        }
        guard value.count > 48 else { return value }
        return value.prefix(47) + "\u{2026}"
    }

    // MARK: Finding

    /// Every address in a run of plain text, in order and without repeats.
    static func addresses(in text: String) -> [String] {
        addresses(of: LinkScan.links(in: text))
    }

    static func addresses(of links: [DetectedLink]) -> [String] {
        deduplicated(links.map(\.url))
    }

    /// The same, for prose that has already been parsed. A markdown answer's addresses are not
    /// only the bare ones: `[the settings page](https://...)` never appears as an address in the
    /// text at all, and it is the one a reader is most likely to want to copy.
    static func addresses(in blocks: [MarkdownBlock]) -> [String] {
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

extension View {
    /// Sends a pressed address to the default browser, and refuses everything else.
    ///
    /// An environment value rather than a gesture, because the press itself belongs to `Text`:
    /// this is the only way a link inside a run of selectable text can be handled without taking
    /// the selection away from it. Dragging across a link still selects the words, because a drag
    /// is not a click.
    func opensTranscriptLinks() -> some View {
        environment(\.openURL, OpenURLAction { url in
            guard TranscriptLink.opens(url) else { return .discarded }
            NSWorkspace.shared.open(url)
            return .handled
        })
    }

    /// A right click on prose that has addresses in it offers to copy them.
    ///
    /// SwiftUI's selectable text has no contextual menu of its own on macOS. It is drawn by a
    /// private `NSTextField` subclass whose `menu(for:)` answers nothing, so this adds a menu
    /// where there was none rather than replacing the system's.
    ///
    /// It cannot know which address was under the pointer, so it names them when there is more
    /// than one. There is deliberately no Open Link item: a plain click already opens, and a
    /// second door to the one action in this window that leaves the app is not worth the row.
    @ViewBuilder
    func transcriptLinkMenu(_ addresses: [String]) -> some View {
        if addresses.isEmpty {
            self
        } else {
            contextMenu {
                ForEach(Array(addresses.enumerated()), id: \.offset) { _, address in
                    Button(addresses.count == 1 ? "Copy Link" : "Copy \(TranscriptLink.shortened(address))") {
                        TranscriptLink.copy(address)
                    }
                }
            }
        }
    }

    /// Reaches the same addresses from the keyboard and from VoiceOver's actions.
    ///
    /// A link inside an `AttributedString` is already announced as a link and can be found by
    /// navigating the text, but activating one that way means landing the VoiceOver cursor on the
    /// exact run. An action on the whole paragraph is a shorter road to the same place.
    @ViewBuilder
    func transcriptLinkActions(_ addresses: [String]) -> some View {
        if addresses.isEmpty {
            self
        } else {
            accessibilityActions {
                ForEach(Array(addresses.enumerated()), id: \.offset) { _, address in
                    Button(addresses.count == 1 ? "Open Link" : "Open \(TranscriptLink.shortened(address))") {
                        guard let url = URL(string: address), TranscriptLink.opens(url) else { return }
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }
    }
}
