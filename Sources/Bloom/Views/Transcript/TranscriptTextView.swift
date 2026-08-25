import AppKit
import SwiftUI
import BloomCore

/// What the transcript can do with an address, handed in rather than decided here.
///
/// **`Equatable` on `identity` and on nothing else, and that is the point of the type.** These go
/// into the environment for the whole transcript, `TranscriptListView` builds them in a computed
/// property, and a struct of closures cannot be compared, so SwiftUI counted the attribute as
/// changed on every single body pass and invalidated every reader. That reached straight through
/// the `.equatable()` the list wraps its rows in, which exists to stop exactly this, and for any
/// paragraph holding a link it re-entered `InlineNSAttributes.make`, the one attributed-string
/// builder in the transcript with no cache. The comments on the call site and on
/// `markdownLinkActions` both claimed the opposite was happening.
///
/// The closures do not need comparing. Every one of them is a pure function of the workspace model
/// and the pane `TranscriptLink.actions(for:pane:)` was handed, plus the one row that adds a file
/// door, so two values with the same identity do the same things.
struct TranscriptLinkActions: Sendable, Equatable {
    /// What these actions were built from. The whole of their equality.
    ///
    /// The pane is half of it because a split lands in the pane the transcript is drawn in, so two
    /// halves of a split tab showing the same conversation do two different things with the same
    /// link and must not compare equal.
    enum Identity: Hashable, Sendable {
        /// The default value, which does nothing at all.
        case inert
        case workspace(WorkspaceID?, pane: String?)
        /// The same, with a file chip's door added. Its own case because a value that can open a
        /// file must never compare equal to one that cannot.
        case workspaceOpeningFiles(WorkspaceID?, pane: String?)
    }

    var identity: Identity = .inert

    var open: @MainActor @Sendable (URL, TranscriptLinkTarget) -> Void = { _, _ in }
    /// What this address may be opened into, asked at the moment the menu is raised so that the
    /// answer is about the column as it is now. The rule is `TranscriptLinkMenu` in the core; this
    /// is only how the transcript reaches it with what the window can do.
    ///
    /// The default answers as a transcript with no column behind it, which is what a value nobody
    /// has filled in is: the external browser and nothing else.
    var items: @MainActor @Sendable (URL) -> [TranscriptLinkItem] = {
        TranscriptLinkMenu.items(for: $0, placement: .detached)
    }
    /// A file chip drawn inside the run was clicked. Empty by default, and set by the one row that
    /// draws chips, because opening a file needs a workspace and the list's shared actions have
    /// none: see `UserTurnRowView`.
    var openFile: @MainActor @Sendable (String) -> Void = { _ in }
    /// The pointer moved onto a file chip inside the run, or off one. Set by the same row and for
    /// the same reason: the card needs the workspace to know which worktree the path is under.
    var hoverFile: @MainActor @Sendable (FileChipHover?) -> Void = { _ in }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.identity == rhs.identity }
}

/// The file chip the pointer is on, and where it is.
///
/// **Reported the moment the pointer arrives, with no wait of its own**, which is the opposite of
/// how the composer's chips do it and is deliberate. `ComposerTextView` waits `Motion.hoverCardDelay`
/// inside AppKit because it has everything the card needs; a transcript's card is drawn over the
/// whole pane by `TranscriptHoverOverlay`, so the frame below has to be added to wherever this
/// text view sits in the window, and the row is the only half that can measure that. It starts
/// measuring on the arrival and waits the same delay before publishing, so the frame is settled by
/// the time it is used and nothing is measured behind a bubble nobody is pointing at.
struct FileChipHover: Equatable, Sendable {
    var path: String
    /// In the text view's own coordinates, which are top left origin because a text view is
    /// flipped. That is the space SwiftUI measures in too, so the row adds its own origin and
    /// nothing here has to reason about AppKit's y axis.
    var frame: CGRect
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
        // And no spell checker. Measured with `--scroll-probe` and `sample` over a 1,104 row
        // conversation, `NSTextCheckingOperation` was running on three worker threads at once at
        // USER_INTERACTIVE quality of service, 383 samples of a twelve second scroll, almost all
        // of it inside `NSSpellChecker.userReplacementsDictionary` doing a linear
        // `containsObject:` over the user's replacement list. Every text view the lazy stack
        // realises starts one.
        //
        // **Be clear about what this bought, because it is not smoothness.** Frame times either
        // side of the change are the same to within noise on an idle Mac with cores to spare:
        // p95 19.0ms and 19.4ms, p99 25.5ms and 26.6ms over four sweeps. What it removes is about
        // four tenths of a second of CPU per twelve seconds of scrolling, at the highest quality
        // of service the system has, on a laptop that is usually on battery. `TranscriptEventCache`
        // records the same shape of finding for the same reason.
        //
        // Nothing is lost either way. This view is `isEditable = false`: it draws an agent's
        // answer and a sentence the user has already sent, neither of which anybody can correct
        // here, so a red underline under the agent's spelling is an offer with nothing behind it.
        // `SourceEditor` turns the same four off for the same reason.
        view.isContinuousSpellCheckingEnabled = false
        view.isGrammarCheckingEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
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

    /// How big this run is, at whatever width the layout system is asking about.
    ///
    /// **Every proposal is answered.** This used to decline three of them, and what SwiftUI does
    /// with a declined answer is not what the name suggests: it fills the proposal's width and
    /// gives the view a single line of height, so a paragraph needing 592 by 35 was placed at 592
    /// by 16 with two thirds of it cut off. One of the three is asked constantly, because
    /// `.textSelection(.enabled)` around a markdown block measures every run inside it with no
    /// width at all. The rules for the other two, and the reasons, are `TranscriptTextMeasure`,
    /// which is in the core because arithmetic in a view is arithmetic nothing can test.
    ///
    /// The width reported is the width the text USED, not the width it was offered. `CappedWidth`
    /// measures the bubble against its cap and then takes the size that came back, which is what
    /// makes a one word turn a one word bubble. Returning the proposal here would report every
    /// turn as the full measure and put "yes" in a bubble seventy percent of the pane wide, which
    /// is the exact failure that layout was written to fix.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: LinkTextView, context: Context) -> CGSize? {
        guard let container = nsView.textContainer, let layout = nsView.layoutManager else {
            return nil
        }
        let proposed = proposal.width.map(Double.init)
        let width = TranscriptTextMeasure.layoutWidth(proposed: proposed)
        // Only when it has actually moved. Whether TextKit throws its layout away on being handed
        // the size it already has is not documented either way, and this is the resize path: every
        // frame of a divider drag asks every realised row for its size, several times, and the
        // proposals a `.textSelection(.enabled)` block generates repeat the same widths. Not
        // depending on the answer costs one comparison.
        let wanted = CGSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        if container.containerSize != wanted { container.containerSize = wanted }
        layout.ensureLayout(for: container)
        let used = layout.usedRect(for: container)
        let size = TranscriptTextMeasure.size(
            widestLine: Double(widestLine(layout, in: container)),
            usedHeight: Double(used.height),
            proposed: proposed,
            lineHeight: Double(lineHeight(nsView, layout)),
            hasGlyphs: (nsView.textStorage?.length ?? 0) > 0
        )
        return CGSize(width: size.width, height: size.height)
    }

    /// One line of whatever this run is set in, which is the height a run that measured nothing
    /// falls back on. The first font in the string rather than the view's, which for a string
    /// carrying a span of code in a second face answers nil.
    private func lineHeight(_ view: LinkTextView, _ layout: NSLayoutManager) -> CGFloat {
        let font = view.textStorage?.length ?? 0 > 0
            ? view.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
            : nil
        return layout.defaultLineHeight(for: font ?? .systemFont(ofSize: NSFont.systemFontSize))
    }

    /// How wide the widest line actually came out.
    ///
    /// **Not `usedRect(for:)`, which answers the container's width for every string there is.**
    /// That was the bug: "continue" reported the full cap and came out in a bubble several hundred
    /// points wide with one word at the left of it, and so did every other turn, so a measure that
    /// existed to make a short bubble short never made one. Measured on this exact stack: at a
    /// container of 456, "continue" and a four line paragraph both said 456.
    ///
    /// The rectangle a line fragment is ALLOTTED does span the container, because that is what a
    /// line fragment is, and `usedRect` is the union of those. The rectangle a line fragment USES
    /// is the ink in it, and the widest of those is the width the bubble should hug: 52 for
    /// "continue", 186 for the wider of two short lines, 452 for the paragraph that wraps.
    ///
    /// The height still comes from `usedRect`, which is right about it (16, 32, 64 for those
    /// three) and which counts the extra line fragment a trailing newline leaves behind.
    private func widestLine(_ layout: NSLayoutManager, in container: NSTextContainer) -> CGFloat {
        var widest: CGFloat = 0
        layout.enumerateLineFragments(forGlyphRange: layout.glyphRange(for: container)) { _, usedRect, _, _, _ in
            widest = max(widest, usedRect.maxX)
        }
        return widest
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

    /// The file chip the pointer is on, so the row is told once on arrival rather than on every
    /// move across the same pill.
    private var hoveredChip: FileChipHover?

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
        let point = convert(event.locationInWindow, from: nil)
        hover(linkRange(at: point))
        let chip = fileChip(at: point)
        // A chip is a door like a link is, and a text view left to itself shows an I-beam over
        // the whole run: the pointer is what says the difference before the click does. The link
        // ranges get theirs from `linkTextAttributes`, which AppKit merges over them; an
        // attachment is not a link and gets nothing, so it is set here.
        if chip != nil { NSCursor.pointingHand.set() }
        hoverChip(chip)
    }

    /// Opens the file under the pointer, and otherwise lets the text view do what it does.
    ///
    /// **Not `NSTextAttachmentCell.trackMouse`, which is how the composer's chips answer a
    /// click.** That path is the text system's, and the text system offers it to an editable view;
    /// this one is not editable, and a chip that silently did nothing in half the places it is
    /// drawn is worse than one drawn twice. Hit tested against the glyph rather than the nearest
    /// character, for the reason written on `linkRange(at:)`: the empty width to the right of a
    /// short line reports the last character on it, so without the bounds test a click in the
    /// white space beside a one-line turn would open its file.
    override func mouseDown(with event: NSEvent) {
        guard let chip = fileChip(at: convert(event.locationInWindow, from: nil)) else {
            super.mouseDown(with: event)
            return
        }
        actions.openFile(chip.path)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        hover(nil)
        hoverChip(nil)
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

    /// Tells the row which chip the pointer is on, once per arrival and once per departure.
    ///
    /// The whole value is compared rather than the path alone, so a sentence naming the same file
    /// twice moves its card from one pill to the other instead of leaving it on the first.
    private func hoverChip(_ chip: FileChipHover?) {
        guard chip != hoveredChip else { return }
        hoveredChip = chip
        actions.hoverFile(chip)
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

    /// The file chip under a point, and where that chip is, or nothing. See `linkRange(at:)`, whose
    /// two tests this shares: the character index, and the glyph rectangle that says the pointer is
    /// really on it.
    ///
    /// The rectangle is returned as well as the path because it is the same rectangle, already
    /// measured: the hit test cannot be done without it, and the card has to be anchored to
    /// something. It is put back into the view's coordinates with `textContainerOrigin`, which is
    /// zero here (the inset and the fragment padding are both set to nothing in `makeNSView`) and
    /// is added anyway, because a chip drawn a few points out of place would be a silent
    /// consequence of somebody changing one of those.
    private func fileChip(at point: CGPoint) -> FileChipHover? {
        guard let layout = layoutManager, let container = textContainer,
              let storage = textStorage, storage.length > 0 else { return nil }

        let index = layout.characterIndex(
            for: point, in: container, fractionOfDistanceBetweenInsertionPoints: nil
        )
        guard index < storage.length else { return nil }

        let glyph = layout.glyphIndexForCharacter(at: index)
        let bounds = layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
        guard bounds.contains(point) else { return nil }

        guard let path = storage.attribute(
            ComposerChipText.pathKey, at: index, effectiveRange: nil
        ) as? String else { return nil }

        let origin = textContainerOrigin
        return FileChipHover(path: path, frame: bounds.offsetBy(dx: origin.x, dy: origin.y))
    }

    private func link(at point: CGPoint) -> URL? {
        guard let range = linkRange(at: point), let storage = textStorage else { return nil }
        return TranscriptTextView.Coordinator.url(from: storage.attribute(.link, at: range.location, effectiveRange: nil) as Any)
    }

    /// Copying a selection that contains a file chip puts the path back in it.
    ///
    /// Without this the clipboard gets `NSTextAttachment`'s object replacement character, which is
    /// an invisible box in every other app, and the sentence the owner copied out of his own turn
    /// arrives with a hole where the file was. `ComposerChipText.draft` writes the path back
    /// inside its backticks, which is the text the agent was handed, so copying a bubble gives
    /// exactly the message that was sent. The composer carries the same override for the same
    /// reason; see `ComposerTextView.writeSelection`.
    override func writeSelection(
        to pasteboard: NSPasteboard, type: NSPasteboard.PasteboardType
    ) -> Bool {
        guard type == .string, let storage = textStorage else {
            return super.writeSelection(to: pasteboard, type: type)
        }
        let text = selectedRanges
            .map { ComposerChipText.draft(of: storage, in: $0.rangeValue) }
            .joined(separator: "\n")
        pasteboard.setString(text, forType: .string)
        return true
    }

    /// The menu over a link, and the ordinary text menu everywhere else.
    ///
    /// Extended rather than replaced: over prose this is whatever AppKit offers a selectable text
    /// view, which is where Copy and Look Up live, and losing that to gain four link items would
    /// be a poor trade. AppKit's own link items are dropped, because "Open Link" without saying
    /// where, next to items that do say, reads as one more destination.
    ///
    /// Which openings there are is `TranscriptLinkMenu` in the core rather than a chain of `if`s
    /// here. This draws them.
    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        guard let url = link(at: point) else { return super.menu(for: event) }

        let menu = NSMenu()
        for offered in actions.items(url) {
            menu.addItem(item(offered.title, url: url, target: offered.target))
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
