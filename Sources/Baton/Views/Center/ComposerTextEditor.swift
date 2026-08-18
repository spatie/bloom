import SwiftUI
import AppKit

/// The composer's editor, as an `NSTextView` rather than `TextField(axis: .vertical)`.
///
/// This was re-evaluated against the native control, and three requirements rule it out. Each one
/// alone is enough; together there is nothing left to build on.
///
/// 1. **The caret offset.** An `@mention` is completed by replacing the range around the insertion
///    point, so the composer has to know where the insertion point is, in UTF-16 units. SwiftUI's
///    `TextField` exposes no selection or caret at all, at any deployment target.
/// 2. **Keys before the text system.** Return sends while Shift+Return inserts a newline, and the
///    arrow keys drive whichever completion menu is open while the field keeps first responder.
///    A focused `TextField` swallows Return and both arrows, so `onSubmit` and `onKeyPress` never
///    see the shape of the event, only that something happened.
/// 3. **Measured growth.** The box grows from one line to twelve and only then scrolls, which
///    needs the height the wrapped text actually occupies. `lineLimit(1...12)` grows, but nothing
///    above AppKit reports the used rect, and the twelfth line is where a scroller has to appear.
///
/// Everything else is deliberately kept off the AppKit side: no state lives here that SwiftUI does
/// not own, and the height is reported outwards rather than imposed on the layout, so this cannot
/// start a layout feedback loop the way an intrinsic-size representable can.
struct ComposerTextEditor: NSViewRepresentable {
    @Binding var text: String
    /// Caret offset in UTF-16 units, so the composer can find the `@token` around it.
    @Binding var caret: Int
    @Binding var isFocused: Bool
    var minLines: Int = 1
    var maxLines: Int = 12
    var onHeightChange: @MainActor (CGFloat) -> Void
    var onKey: @MainActor (ComposerKey) -> Bool

    static var font: NSFont { NSFont.preferredFont(forTextStyle: .body) }
    static var lineHeight: CGFloat { NSLayoutManager().defaultLineHeight(for: font) }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        // Built out of an explicit TextKit 1 stack. A text view made the modern way answers with a
        // TextKit 2 layout, and `usedRect(for:)` is the only measurement that reports the exact
        // height wrapped text occupies.
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layout.addTextContainer(container)

        let textView = ComposerTextView(frame: .zero, textContainer: container)
        textView.delegate = context.coordinator
        textView.keyHandler = { [weak coordinator = context.coordinator] event in
            coordinator?.handle(event) ?? false
        }
        // Wrapping depends on the width, so the measurement is only valid until the window is
        // resized. Re-measuring on the frame change is cheaper than laying out speculatively.
        textView.onWidthChange = { [weak coordinator = context.coordinator, weak textView] in
            guard let coordinator, let textView else { return }
            coordinator.reportHeight(of: textView)
        }
        // Clicking straight into the text makes it first responder without SwiftUI asking, so the
        // flag has to follow AppKit rather than the other way round.
        textView.onFocusChange = { [weak coordinator = context.coordinator] focused in
            coordinator?.focusChanged(to: focused)
        }
        textView.font = Self.font
        textView.textColor = .labelColor
        textView.insertionPointColor = .controlAccentColor
        textView.drawsBackground = false
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainerInset = .zero
        textView.autoresizingMask = [.width]
        textView.minSize = CGSize(width: 0, height: 0)
        textView.maxSize = CGSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.string = text
        textView.setAccessibilityLabel("Message")

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.horizontalScrollElasticity = .none
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? ComposerTextView else { return }
        context.coordinator.parent = self

        if textView.string != text {
            textView.string = text
            textView.font = Self.font
            textView.textColor = .labelColor
            let location = min(max(caret, 0), (text as NSString).length)
            textView.setSelectedRange(NSRange(location: location, length: 0))
        }

        if isFocused, textView.window?.firstResponder !== textView {
            textView.window?.makeFirstResponder(textView)
        } else if !isFocused, textView.window?.firstResponder === textView {
            textView.window?.makeFirstResponder(nil)
        }

        context.coordinator.reportHeight(of: textView)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposerTextEditor
        private var lastReportedHeight: CGFloat = 0

        init(_ parent: ComposerTextEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? ComposerTextView else { return }
            parent.text = textView.string
            parent.caret = textView.selectedRange().location
            reportHeight(of: textView)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? ComposerTextView else { return }
            let location = textView.selectedRange().location
            if parent.caret != location { parent.caret = location }
        }

        /// Deferred by one turn of the main actor: the responder change can land in the middle of a
        /// SwiftUI update, and writing state there is how a view ends up fighting itself.
        func focusChanged(to focused: Bool) {
            guard parent.isFocused != focused else { return }
            Task { [weak self] in
                guard let self, self.parent.isFocused != focused else { return }
                self.parent.isFocused = focused
            }
        }

        /// Maps a raw key event to composer intent. Shift+Return is deliberately not mapped: it
        /// falls through to AppKit, which inserts the newline for us.
        func handle(_ event: NSEvent) -> Bool {
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            switch event.keyCode {
            case 36, 76: // Return, Enter
                if flags.contains(.shift) { return false }
                return parent.onKey(flags.contains(.command) ? .commandReturn : .returnKey)
            case 53: // Escape
                return parent.onKey(.escape)
            case 125: // Down
                return parent.onKey(.down)
            case 126: // Up
                return parent.onKey(.up)
            case 48: // Tab
                return parent.onKey(.tab)
            default:
                return false
            }
        }

        /// Measures what the text actually occupies and clamps it to the growth window. Reported
        /// asynchronously because this runs inside a SwiftUI update and must not write state back
        /// into the same pass.
        func reportHeight(of textView: ComposerTextView) {
            guard let layout = textView.layoutManager, let container = textView.textContainer else { return }
            // Before the first layout pass the view has no width, and text wrapped to nothing
            // measures as one line per word. Measuring then would open the box at full height.
            guard textView.bounds.width > 1 else { return }

            layout.ensureLayout(for: container)

            let line = layout.defaultLineHeight(for: textView.font ?? ComposerTextEditor.font)
            let used = layout.usedRect(for: container).height
            let minimum = CGFloat(parent.minLines) * line
            let maximum = CGFloat(parent.maxLines) * line
            let height = min(max(used, minimum), maximum).rounded(.up)

            guard abs(height - lastReportedHeight) > 0.5 else { return }
            lastReportedHeight = height
            let report = parent.onHeightChange
            Task { report(height) }
        }
    }
}
