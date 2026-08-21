import AppKit
import SwiftUI
import BloomCore

/// Where a link the reader chose should be opened.
enum TranscriptLinkTarget {
    /// The system's default browser, which is what a plain click does.
    case externalBrowser
    /// A browser tab in Bloom's own centre column.
    case browserTab
}

/// What the transcript can do with an address, handed in rather than decided here.
struct TranscriptLinkActions: Sendable {
    var open: @MainActor @Sendable (URL, TranscriptLinkTarget) -> Void = { _, _ in }
    /// Whether Bloom's own browser could show this address at all. A menu item that opens a blank
    /// tab is worse than a menu item that is not there.
    var canOpenInTab: @MainActor @Sendable (URL) -> Bool = { _ in false }
}

/// Prose in the transcript, drawn by AppKit so that a link in it behaves like a link.
///
/// ## Why this is not a `Text`
///
/// It was a `Text`, and the links in it were decoration. Measured on a real window with the
/// pointer: the cursor over a link was an I-beam at three different heights, and a press routed
/// nothing. `.textSelection(.enabled)` is why. SwiftUI draws selectable text with a private
/// `NSTextField` subclass laid over the run, and that field owns the mouse: it claims the I-beam,
/// it swallows the click before SwiftUI's own link handling sees it, and its `menu(for:)` answers
/// nothing, so there was no context menu to extend either. Selection and working links are not
/// both available from `Text` on this system, and selection is not negotiable in a transcript.
///
/// An `NSTextView` gives all of it by construction: the pointing hand over a link range, a click
/// routed to the delegate, a drag that selects because that is what a selectable text view does,
/// and a contextual menu that can be extended rather than invented.
///
/// ## What it deliberately does not do
///
/// It is not editable, it detects nothing of its own (`LinkScan` in the core decides what an
/// address is, and the caller has already applied it), and it draws no background. It is a way of
/// laying out an attributed string that someone else composed.
struct TranscriptTextView: NSViewRepresentable {
    var text: NSAttributedString
    /// The ink a link is drawn in when the pointer is elsewhere. The underline is not part of it:
    /// see `LinkTextView.hovered`.
    var linkColor: NSColor
    /// What paints behind a selection. Handed in because the bubble is a dark surface whatever
    /// the page around it is doing, and AppKit cannot read the SwiftUI environment that says so.
    var selectionColor: NSColor
    var actions = TranscriptLinkActions()

    func makeCoordinator() -> Coordinator { Coordinator(actions: actions) }

    func makeNSView(context: Context) -> LinkTextView {
        // A TextKit 1 stack, built by hand and on purpose. `addTemporaryAttribute` is what draws
        // the hover underline without touching the text storage, and it belongs to
        // `NSLayoutManager`, which a text view created the ordinary way on this macOS does not
        // have: it comes up on TextKit 2 and answers nil.
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.lineFragmentPadding = 0
        storage.addLayoutManager(layout)
        layout.addTextContainer(container)

        let view = LinkTextView(frame: .zero, textContainer: container)
        view.delegate = context.coordinator
        view.actions = actions
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        view.backgroundColor = NSColor.clear
        view.textContainerInset = NSSize.zero
        // Bloom decides what an address is, in the core, where it is tested. AppKit's own detector
        // would find a second, different set, and it runs on the text as it is laid out.
        view.isAutomaticLinkDetectionEnabled = false
        view.isAutomaticDataDetectionEnabled = false
        view.usesFontPanel = false
        view.usesFindBar = false
        // A text view inside a scroll view of SwiftUI's making must never scroll itself.
        view.isVerticallyResizable = false
        view.isHorizontallyResizable = false
        apply(to: view)
        return view
    }

    func updateNSView(_ view: LinkTextView, context: Context) {
        context.coordinator.actions = actions
        view.actions = actions
        apply(to: view)
    }

    private func apply(to view: LinkTextView) {
        if view.textStorage?.isEqual(to: text) != true {
            view.textStorage?.setAttributedString(text)
        }
        view.linkColor = linkColor
        // No underline at rest, and the pointing hand is set here rather than left to chance:
        // this dictionary is what AppKit merges over every link range it lays out.
        view.linkTextAttributes = [
            .foregroundColor: linkColor,
            .cursor: NSCursor.pointingHand,
        ]
        view.selectedTextAttributes = [.backgroundColor: selectionColor]
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: LinkTextView, context: Context) -> CGSize? {
        guard let container = nsView.textContainer, let layout = nsView.layoutManager else {
            return nil
        }
        let width = proposal.width ?? nsView.bounds.width
        guard width > 0, width.isFinite else { return nil }
        container.containerSize = CGSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        let used = layout.usedRect(for: container)
        // The width the text USED, not the width it was offered.
        //
        // `CappedWidth` measures the bubble against its cap and then takes the size that came
        // back, which is what makes a one word turn a one word bubble. Returning the proposal
        // here would report every turn as the full measure and put "yes" in a bubble seventy
        // percent of the pane wide, which is the exact failure that layout was written to fix.
        return CGSize(width: min(ceil(used.width), width), height: ceil(used.height))
    }

    /// Only the link click. Everything else a text view does is its own.
    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var actions: TranscriptLinkActions

        init(actions: TranscriptLinkActions) { self.actions = actions }

        func textView(_ view: NSTextView, clickedOnLink link: Any, at index: Int) -> Bool {
            guard let url = Self.url(from: link) else { return false }
            // A plain click goes to the system's browser, which is what the owner asked for. The
            // in-app tab is a deliberate choice made from the menu.
            actions.open(url, .externalBrowser)
            return true
        }

        static func url(from link: Any) -> URL? {
            if let url = link as? URL { return url }
            if let text = link as? String { return URL(string: text) }
            return nil
        }
    }
}

/// The text view itself: hover, and the menu over a link.
final class LinkTextView: NSTextView {
    var actions = TranscriptLinkActions()
    var linkColor: NSColor = .linkColor

    /// The link range the pointer is currently inside, underlined for as long as it is.
    ///
    /// Drawn with a temporary attribute rather than by editing the text storage. A temporary
    /// attribute is presentation only: it never reaches the string, so nothing that reads the
    /// text back, copies it or measures it can see the underline, and putting one on and taking
    /// it off does not invalidate the layout.
    private var hovered: NSRange?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self {
            removeTrackingArea(area)
        }
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self
        ))
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        hover(linkRange(at: convert(event.locationInWindow, from: nil)))
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        hover(nil)
    }

    private func hover(_ range: NSRange?) {
        guard range != hovered, let layout = layoutManager else { return }
        if let hovered {
            layout.removeTemporaryAttribute(.underlineStyle, forCharacterRange: hovered)
        }
        if let range {
            layout.addTemporaryAttributes(
                [.underlineStyle: NSUnderlineStyle.single.rawValue], forCharacterRange: range
            )
        }
        hovered = range
    }

    /// The link under a point, or nothing.
    ///
    /// The glyph rectangle is checked as well as the index, because `characterIndex(for:in:)`
    /// answers with the NEAREST character however far away the point is: without this, the whole
    /// empty width to the right of a short line reports the link that ends it, and the pointer
    /// would underline a link it is nowhere near.
    private func linkRange(at point: CGPoint) -> NSRange? {
        guard let layout = layoutManager, let container = textContainer,
              let storage = textStorage, storage.length > 0 else { return nil }

        let index = layout.characterIndex(
            for: point, in: container, fractionOfDistanceBetweenInsertionPoints: nil
        )
        guard index < storage.length else { return nil }

        let glyph = layout.glyphIndexForCharacter(at: index)
        let bounds = layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
        guard bounds.insetBy(dx: -1, dy: 0).contains(point) else { return nil }

        var range = NSRange()
        guard storage.attribute(.link, at: index, effectiveRange: &range) != nil else { return nil }
        return range
    }

    private func link(at point: CGPoint) -> URL? {
        guard let range = linkRange(at: point), let storage = textStorage else { return nil }
        return TranscriptTextView.Coordinator.url(from: storage.attribute(.link, at: range.location, effectiveRange: nil) as Any)
    }

    /// The menu over a link, and the ordinary text menu everywhere else.
    ///
    /// Extended rather than replaced: over prose this is whatever AppKit offers a selectable text
    /// view, which is where Copy and Look Up live, and losing that to gain three link items would
    /// be a poor trade. AppKit's own link items are dropped, because "Open Link" without saying
    /// where, next to two items that do say, reads as a third destination.
    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        guard let url = link(at: point) else { return super.menu(for: event) }

        let menu = NSMenu()
        menu.addItem(item("Open in External Browser", url: url, target: .externalBrowser))
        if actions.canOpenInTab(url) {
            menu.addItem(item("Open in Browser Tab", url: url, target: .browserTab))
        }
        menu.addItem(.separator())
        let copy = NSMenuItem(title: "Copy Link", action: #selector(copyLink(_:)), keyEquivalent: "")
        copy.target = self
        copy.represent(url)
        menu.addItem(copy)
        return menu
    }

    private func item(_ title: String, url: URL, target: TranscriptLinkTarget) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(openLink(_:)), keyEquivalent: "")
        item.target = self
        item.represent(LinkChoice(url: url, target: target))
        return item
    }

    private struct LinkChoice {
        let url: URL
        let target: TranscriptLinkTarget
    }

    @objc private func openLink(_ sender: NSMenuItem) {
        guard let choice = sender.represented(LinkChoice.self) else { return }
        actions.open(choice.url, choice.target)
    }

    @objc private func copyLink(_ sender: NSMenuItem) {
        guard let url = sender.represented(URL.self) else { return }
        TranscriptLink.copy(url.absoluteString)
    }
}
