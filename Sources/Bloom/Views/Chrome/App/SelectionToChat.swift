import AppKit

/// Add Selection to Chat, resolved against whatever holds the keyboard when it is pressed.
///
/// Two things in the window can answer it. A shell attaches what is selected in it to the
/// workspace's conversation, and a conversation quotes what is selected in an answer into its own
/// reply. Anything else, including a selection in the composer itself, is no answer and the menu
/// item beeps.
///
/// **It walks the responder chain for the same reason `FindInPlace` does.** A transcript's prose is
/// drawn two ways: a run with a link in it is a `LinkTextView`, and every other run is SwiftUI's
/// selectable `Text`, whose selection lives in the window's field editor. Neither says which
/// conversation it belongs to and SwiftUI offers no way to read the second at all, so the text is
/// read off whichever text view has the keyboard, and the conversation is found by walking up to
/// the `TranscriptTableView` the text view is drawn inside.
@MainActor
enum SelectionToChat {
    /// False when nothing in front had a selection to hand over.
    static func perform() -> Bool {
        guard let responder = NSApp.keyWindow?.firstResponder else { return false }

        var current: NSResponder? = responder
        while let each = current {
            if let terminal = each as? BloomTerminalView {
                return terminal.onCommand?(.addSelectionToChat) == true
            }
            current = each.nextResponder
        }

        guard let textView = responder as? NSTextView else { return false }
        return quote(from: textView)
    }

    /// Quotes a transcript text view's selection into the reply of the conversation it is in.
    static func quote(from textView: NSTextView) -> Bool {
        guard let table = transcript(containing: textView),
              let quoteSelection = table.quoteSelection,
              let text = selectedText(in: textView) else { return false }
        quoteSelection(text)
        return true
    }

    /// Whether `quote(from:)` would do anything, for a menu deciding whether to offer it.
    static func canQuote(from textView: NSTextView) -> Bool {
        textView.selectedRanges.contains { $0.rangeValue.length > 0 }
            && transcript(containing: textView)?.quoteSelection != nil
    }

    /// The selection as the text view would copy it. Through a private pasteboard rather than off
    /// `string`, because `LinkTextView.writeSelection` is where a file chip becomes its path again,
    /// and a quote with a hole where the file was is the bug that override exists to prevent.
    private static func selectedText(in textView: NSTextView) -> String? {
        guard textView.selectedRanges.contains(where: { $0.rangeValue.length > 0 }) else { return nil }
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.clearContents()
        guard textView.writeSelection(to: board, type: .string),
              let text = board.string(forType: .string),
              text.contains(where: { !$0.isWhitespace }) else { return nil }
        return text
    }

    /// The field editor is a subview of the text field it is editing while it has the keyboard, so
    /// walking superviews reaches the table from either kind of prose.
    private static func transcript(containing view: NSView) -> TranscriptTableView? {
        var current: NSView? = view
        while let each = current {
            if let table = each as? TranscriptTableView { return table }
            current = each.superview
        }
        return nil
    }
}
