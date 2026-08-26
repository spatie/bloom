import SwiftUI
import AppKit
import BloomCore

/// An editable, syntax highlighted, line numbered view of one source file.
///
/// A real `NSTextView` rather than SwiftUI's `TextEditor`, because everything that makes editing
/// code bearable is AppKit's and not SwiftUI's: undo that coalesces the way a text system's does,
/// a find bar, a ruler that can hold line numbers, and horizontal scrolling instead of wrapped
/// lines. TextKit 1 specifically, built by hand rather than taken from `NSTextView`'s convenience
/// initialiser, because the line number ruler is placed from `NSLayoutManager` line fragments and
/// TextKit 2 does not vend one.
///
/// The highlighting is the app's own: `SyntaxHighlighter` produces the tokens and `CodeText` maps
/// a token kind to a colour, so the editor and the diff can never drift into two colour schemes.
/// Only the destination differs, an `NSTextStorage` rather than an `AttributedString`.
struct SourceEditor: NSViewRepresentable {
    @Binding var text: String
    var language: Language
    /// Read only to notice that the appearance flipped, which is when the token colours have
    /// to be resolved again.
    var colorScheme: ColorScheme
    /// Off for a value that is being shown rather than edited, such as the resolved settings the
    /// preferences window mirrors. The caret and the find bar go with it.
    var isEditable = true
    /// The ground the code and the gutter are drawn on.
    ///
    /// `nil` keeps `NSColor.textBackgroundColor`, which is what a full pane editor wants. A field
    /// inside a form passes the form's own sunken surface instead, because the app's dark
    /// appearance is a deep blue and the system's text background is very nearly black next to it.
    var ground: Color?
    /// Drawn in place of the text while the buffer is empty. A script nobody has written yet is
    /// otherwise an unexplained empty box.
    var placeholder = ""

    /// Past this the colour pass costs more than it is worth on every keystroke, and a file this
    /// long is not one anybody is hand editing in a review pane. It still opens, in plain
    /// monospace.
    private static let highlightLimit = 400_000

    /// The ground as an `NSColor`, resolved on the main actor where the SwiftUI environment is
    /// available, so no draw pass ever has to do the conversion.
    private var resolvedGround: NSColor {
        guard let ground else { return .textBackgroundColor }
        return NSColor(ground)
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeNSView(context: Context) -> NSScrollView {
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)

        // An unbounded container with tracking off is what turns wrapping into horizontal
        // scrolling, which is the only way indented code stays readable.
        let container = NSTextContainer(
            size: NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        )
        container.widthTracksTextView = false
        layoutManager.addTextContainer(container)

        let textView = CodeTextView(frame: .zero, textContainer: container)
        textView.isEditable = isEditable
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isHorizontallyResizable = true
        textView.isVerticallyResizable = true
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude
        )
        textView.minSize = NSSize(width: 0, height: 0)
        textView.textContainerInset = NSSize(width: CodeMetrics.textInset, height: 6)
        textView.font = CodeMetrics.font
        textView.backgroundColor = resolvedGround
        textView.drawsBackground = true
        textView.placeholder = placeholder
        textView.usesFindBar = isEditable
        textView.isIncrementalSearchingEnabled = isEditable
        // Every one of these turns a helpful editing feature into a source code corruption:
        // smart quotes in a string literal, an en dash in an operator, a "corrected" identifier.
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.delegate = context.coordinator

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = resolvedGround

        // The ruler has to be in place before the document view is, and the scroll view has to be
        // re-tiled afterwards. Without both, the clip view keeps the full width it was laid out
        // with and the gutter is drawn on top of the first few characters of every line.
        let ruler = LineNumberRuler(scrollView: scrollView, textView: textView)
        ruler.fill = resolvedGround
        ruler.numberColor = NSColor(Palette.textTertiary)
        scrollView.verticalRulerView = ruler
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true
        scrollView.documentView = textView
        scrollView.tile()

        context.coordinator.attach(textView: textView, ruler: ruler)
        context.coordinator.replace(text: text, language: language, appearance: colorScheme)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.text = $text
        guard let textView = scrollView.documentView as? CodeTextView else { return }

        // Resolved here rather than inside a draw pass, and re-resolved on every update because
        // an appearance flip is exactly what this view is handed `colorScheme` to notice.
        let ground = resolvedGround
        textView.backgroundColor = ground
        textView.isEditable = isEditable
        textView.placeholder = placeholder
        scrollView.backgroundColor = ground
        if let ruler = scrollView.verticalRulerView as? LineNumberRuler {
            ruler.fill = ground
            ruler.numberColor = NSColor(Palette.textTertiary)
            ruler.needsDisplay = true
        }

        // Only when the buffer genuinely differs, because assigning `string` throws away the
        // selection and the undo stack, and SwiftUI re-runs this on every unrelated update.
        // Language and appearance both change what the colour pass produces, so either one moving
        // has to re-run it even when the buffer is untouched.
        if textView.string != text
            || context.coordinator.language != language
            || context.coordinator.appearance != colorScheme {
            context.coordinator.replace(text: text, language: language, appearance: colorScheme)
        }
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        coordinator.detach()
    }

    /// One coloured span, in UTF-16 offsets over the whole file, computed off the main thread.
    struct ColorRun: Sendable {
        var start: Int
        var length: Int
        var kind: TokenKind
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        private(set) var language: Language = .plainText
        private(set) var appearance: ColorScheme = .light

        private weak var textView: NSTextView?
        private weak var ruler: LineNumberRuler?
        private var highlightTask: Task<Void, Never>?

        /// The editor's own undo stack, kept off the window's.
        ///
        /// An `NSTextView` with no manager of its own asks the responder chain, which ends at the
        /// window, so this editor was typing into the same stack that holds `Undo Archive
        /// Workspace`. `removeAllActions()` below then threw that stack away wholesale, and simply
        /// opening a file in Edit mode took the only way back from an archive with it.
        private let editorUndo = UndoManager()

        func undoManager(for view: NSTextView) -> UndoManager? { editorUndo }

        init(text: Binding<String>) {
            self.text = text
        }

        func attach(textView: NSTextView, ruler: LineNumberRuler) {
            self.textView = textView
            self.ruler = ruler
        }

        func detach() {
            highlightTask?.cancel()
        }

        /// Load a whole buffer. Distinct from an edit: the undo stack is meaningless across a
        /// different file, and the colour pass has to run before the first frame rather than
        /// after a debounce, or the file flashes up unhighlighted.
        func replace(
            text value: String, language newLanguage: Language, appearance scheme: ColorScheme
        ) {
            guard let textView else { return }
            language = newLanguage
            appearance = scheme
            if textView.string != value {
                textView.string = value
                // Only this editor's stack, which is what `editorUndo` exists to make true.
                editorUndo.removeAllActions()
            }
            ruler?.refresh()
            highlight(immediately: true)
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            text.wrappedValue = textView.string
            ruler?.refresh()
            highlight(immediately: false)
        }

        /// Re-colour the buffer.
        ///
        /// The whole file rather than the edited line: the lexer carries block comments, heredocs
        /// and multiline strings forward, so typing `/*` changes the colour of everything below
        /// it. Doing that on a background task and applying the result only if the buffer has not
        /// moved on keeps a keystroke off the tokenizer's critical path.
        private func highlight(immediately: Bool) {
            highlightTask?.cancel()
            let source = textView?.string ?? ""
            let language = self.language

            guard source.utf16.count <= SourceEditor.highlightLimit, language != .plainText else {
                applyPlain()
                return
            }

            highlightTask = Task { [weak self] in
                if !immediately {
                    try? await Task.sleep(for: .milliseconds(150))
                    guard !Task.isCancelled else { return }
                }
                let runs = await Task.detached(priority: .userInitiated) {
                    SourceEditor.runs(in: source, language: language)
                }.value
                guard !Task.isCancelled else { return }
                self?.apply(runs, matching: source)
            }
        }

        private func applyPlain() {
            guard let storage = textView?.textStorage else { return }
            storage.beginEditing()
            storage.setAttributes(Self.base, range: NSRange(location: 0, length: storage.length))
            storage.endEditing()
        }

        private func apply(_ runs: [ColorRun], matching source: String) {
            guard let storage = textView?.textStorage, storage.string == source else { return }

            var colors: [TokenKind: NSColor] = [:]
            for kind in TokenKind.allCases { colors[kind] = NSColor(CodeText.color(for: kind)) }

            storage.beginEditing()
            storage.setAttributes(Self.base, range: NSRange(location: 0, length: storage.length))
            for run in runs {
                let range = NSRange(location: run.start, length: run.length)
                guard NSMaxRange(range) <= storage.length, let color = colors[run.kind] else { continue }
                storage.addAttribute(.foregroundColor, value: color, range: range)
            }
            storage.endEditing()
        }

        private static let base: [NSAttributedString.Key: Any] = [
            .font: CodeMetrics.font,
            .foregroundColor: NSColor.labelColor,
        ]
    }

    /// The one place tokens become spans. Pure and off the main actor, so it can run detached.
    nonisolated static func runs(in source: String, language: Language) -> [ColorRun] {
        var result: [ColorRun] = []
        var state = LexState()
        var offset = 0

        for line in source.components(separatedBy: "\n") {
            let tokens = SyntaxHighlighter.tokenize(line: line, language: language, carry: &state)
            for token in tokens where token.kind != .plain {
                result.append(
                    ColorRun(
                        start: offset + token.range.lowerBound,
                        length: token.range.count,
                        kind: token.kind
                    )
                )
            }
            // The newline the split consumed still occupies a UTF-16 unit in the storage.
            offset += line.utf16.count + 1
        }
        return result
    }
}

/// An `NSTextView` that says so when it is empty.
///
/// A placeholder is drawn rather than inserted, so an empty script stays genuinely empty: the
/// binding never sees the prompt text, and saving a field nobody touched cannot write it to a
/// settings file.
///
/// It is drawn where the first character will be, and that point is asked of the text system
/// rather than assembled from parts. `textContainerOrigin` is what the layout manager lays the
/// container out at, so it already carries the inset the gutter is holding open, and
/// `lineFragmentPadding` is the five points the container then takes off the front of every line.
/// The prompt was drawn from the inset alone and sat five points to the left of the text it was
/// standing in for, which is small enough to read as a rendering quirk and is not one.
final class CodeTextView: NSTextView {
    var placeholder = "" {
        didSet { if placeholder != oldValue { needsDisplay = true } }
    }

    /// The prompt is painted from the inset, so a change to the inset has to repaint it.
    ///
    /// Text does not need this: moving the container relays out the glyphs, and a relayout redraws
    /// itself. An empty view has no glyphs to relay out, so without this the prompt could stay
    /// where it was last painted while the caret beside it had already moved. See
    /// `LineNumberRuler.viewWillDraw`, which is what moves it.
    override var textContainerInset: NSSize {
        didSet {
            if textContainerInset != oldValue, string.isEmpty, !placeholder.isEmpty {
                needsDisplay = true
            }
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        guard string.isEmpty, !placeholder.isEmpty else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: CodeMetrics.font,
            .foregroundColor: NSColor.tertiaryLabelColor,
        ]
        let origin = textContainerOrigin
        let padding = textContainer?.lineFragmentPadding ?? 0
        (placeholder as NSString).draw(
            at: NSPoint(x: origin.x + padding, y: origin.y),
            withAttributes: attributes
        )
    }
}
