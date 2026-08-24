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
            guard let url = URL(string: found.url), LinkPolicy.opens(url) else { continue }
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

    /// A sent turn as an `NSAttributedString`, for `TranscriptTextView`: the words with their
    /// addresses marked, and the files in them drawn as the chip the composer drew a moment before
    /// the message went.
    ///
    /// **The files are `NSTextAttachment`s rather than a second view laid beside the text**, and
    /// that is not a drawing preference. TextKit 1 has no way to put a view inside a line, and a
    /// bubble that laid its sentence out as a row of text views and chips would lose the wrap, the
    /// selection across the join, and the one measure `CappedWidth` takes. As one character in the
    /// storage a chip wraps with the sentence, is selected with it, and copies out as its path.
    /// `ComposerChipText` already had all of that for the box; this is the same object on the
    /// other ground.
    ///
    /// Only the `.link` attribute is set on an address here. Its colour and its underline are the
    /// text view's business, because they are not properties of the text: the colour comes from
    /// `linkTextAttributes` and the underline appears only while the pointer is on it. Putting
    /// either in the string would make a link underlined at rest again, and would put an
    /// underline into anything that copied it out.
    ///
    /// The addresses are scanned per run of words rather than over the whole turn, because a range
    /// found in the turn would name the wrong characters once the paths in front of it had each
    /// collapsed to a single character.
    @MainActor
    static func attributedString(
        _ segments: [AttachmentDraft.Segment],
        font: NSFont,
        color: NSColor,
        lineSpacing: CGFloat,
        chipGround: AttachmentChipCell.Ground
    ) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = lineSpacing
        paragraph.alignment = .left
        // A long address has no spaces to break at, so without this it lays out as one line and
        // takes the bubble off the pane. Character wrapping is only reached when a word cannot
        // fit, which for prose is never.
        paragraph.lineBreakMode = .byWordWrapping

        let output = NSMutableAttributedString()

        for segment in segments {
            switch segment {
            case .text(let words):
                output.append(attributedRun(words, font: font, color: color))
            case .attachment(let path):
                output.append(ComposerChipText.chip(for: path, font: font, ground: chipGround))
            }
        }

        // Said once over the whole turn, so the line a chip sits on is led like every other line.
        output.addAttribute(
            .paragraphStyle, value: paragraph, range: NSRange(location: 0, length: output.length)
        )
        return output
    }

    @MainActor
    private static func attributedRun(
        _ text: String, font: NSFont, color: NSColor
    ) -> NSAttributedString {
        let run = NSMutableAttributedString(
            string: text, attributes: [.font: font, .foregroundColor: color]
        )
        for found in LinkScan.links(in: text) {
            guard let url = URL(string: found.url), LinkPolicy.opens(url) else { continue }
            run.addAttribute(.link, value: url, range: NSRange(found.range, in: text))
        }
        return run
    }

    /// What a transcript row does with an address, in one place so every row does the same.
    ///
    /// A plain click goes to the system's browser. The in-app tab is only ever reached by
    /// choosing it from the menu, which is the difference the owner asked for: opening a page is
    /// an action, and the quieter of the two destinations is the one that has to be asked for.
    @MainActor
    static func actions(for model: WorkspaceModel?) -> TranscriptLinkActions {
        TranscriptLinkActions(
            identity: .workspace(model?.workspace.id),
            open: { url, target in
                switch target {
                case .externalBrowser:
                    guard LinkPolicy.opens(url) else { return }
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
    //
    // Which addresses may be opened at all is `LinkPolicy.opens`, in the core where the rule is
    // tested: an agent's markdown can name any scheme it likes, and the gate on that is not a
    // drawing decision.

    // MARK: Copying

    static func copy(_ url: String) {
        Clipboard.copy(url)
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
            guard LinkPolicy.opens(url) else { return .discarded }
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
                    Button(addresses.count == 1 ? "Copy Link" : "Copy \(LinkPolicy.shortened(address))") {
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
                    Button(addresses.count == 1 ? "Open Link" : "Open \(LinkPolicy.shortened(address))") {
                        guard let url = URL(string: address), LinkPolicy.opens(url) else { return }
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }
    }
}
