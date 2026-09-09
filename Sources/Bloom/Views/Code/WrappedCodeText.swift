import AppKit
import SwiftUI
import BloomCore

/// Measures with the same text engine, font and paragraph settings used to draw wrapped code.
/// Cached per source line and width, so scrolling and hover never repeat text layout.
@MainActor
enum WrappedCodeLayout {
    private struct Key: Hashable {
        var text: String
        var width: CGFloat
    }
    private static var heights: [Key: CGFloat] = [:]

    static func paragraph(spacing: CGFloat = 0) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.minimumLineHeight = CodeMetrics.rowHeight
        style.maximumLineHeight = CodeMetrics.rowHeight
        style.lineBreakMode = .byWordWrapping
        style.paragraphSpacing = spacing
        style.tabStops = []
        style.defaultTabInterval = CodeMetrics.advance * 4
        return style
    }

    static func height(of text: String, width: CGFloat) -> CGFloat {
        let width = max(1, width)
        let key = Key(text: text, width: width)
        if let height = heights[key] { return height }
        let height: CGFloat
        if !text.contains("\t"), (text as NSString).size(withAttributes: [.font: CodeMetrics.font]).width <= width {
            height = CodeMetrics.rowHeight
        } else {
            let storage = NSTextStorage(string: text, attributes: [
                .font: CodeMetrics.font, .paragraphStyle: paragraph(),
            ])
            let manager = NSLayoutManager()
            manager.backgroundLayoutEnabled = false
            storage.addLayoutManager(manager)
            let container = NSTextContainer(size: NSSize(width: width, height: .greatestFiniteMagnitude))
            container.lineFragmentPadding = 0
            manager.addTextContainer(container)
            manager.ensureLayout(for: container)
            height = max(CodeMetrics.rowHeight, ceil(manager.usedRect(for: container).height))
        }
        if heights.count >= 8_192 { heights.removeAll(keepingCapacity: true) }
        heights[key] = height
        return height
    }
}

/// Native soft wrapping preserves the original newlines on the clipboard. Paragraph spacing
/// pads the shorter half of a side-by-side row without inserting characters into its text.
struct WrappedCodeText: NSViewRepresentable {
    var lines: [CodeRunLine]
    var language: Language
    var width: CGFloat
    var heights: [CGFloat]
    var onComment: (Int) -> Void
    var onEdit: (Int) -> Void
    var commentable: [Bool]
    var editable: [Bool]

    @Environment(\.colorScheme) private var colorScheme

    func makeCoordinator() -> Coordinator { Coordinator() }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: TextView, context: Context) -> CGSize? {
        CGSize(width: width, height: heights.reduce(0, +))
    }

    func makeNSView(context: Context) -> TextView {
        let storage = NSTextStorage()
        let manager = NSLayoutManager()
        manager.backgroundLayoutEnabled = false
        storage.addLayoutManager(manager)
        let container = NSTextContainer(size: NSSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        container.widthTracksTextView = true
        manager.addTextContainer(container)
        let view = TextView(frame: .zero, textContainer: container)
        view.isEditable = false
        view.isSelectable = true
        view.isRichText = true
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.isHorizontallyResizable = false
        view.isVerticallyResizable = false
        view.font = CodeMetrics.font
        view.defaultParagraphStyle = WrappedCodeLayout.paragraph()
        return view
    }

    func updateNSView(_ view: TextView, context: Context) {
        view.rowHeights = heights
        view.onComment = onComment
        view.onEdit = onEdit
        view.commentable = commentable
        view.editableRows = editable
        let previous = context.coordinator
        guard previous.lines != lines || previous.language != language || previous.width != width
                || previous.heights != heights || previous.scheme != colorScheme else { return }
        previous.lines = lines
        previous.language = language
        previous.width = width
        previous.heights = heights
        previous.scheme = colorScheme

        let value = NSMutableAttributedString(string: "")
        for (index, line) in lines.enumerated() {
            let highlighted = CodeText.attributed(
                line: line.text, language: language, carry: line.carry,
                emphasis: line.emphasis, emphasisColor: line.emphasisColor
            )
            let text = line.text + (index + 1 < lines.count ? "\n" : "")
            let spacing = max(0, heights[index] - WrappedCodeLayout.height(of: line.text, width: width))
            let paragraph = NSMutableAttributedString(string: text, attributes: [
                .font: CodeMetrics.font, .paragraphStyle: WrappedCodeLayout.paragraph(spacing: spacing),
                .foregroundColor: NSColor(Palette.textPrimary),
            ])
            var offset = 0
            for run in highlighted.runs {
                let length = String(highlighted[run.range].characters).utf16.count
                let range = NSRange(location: offset, length: length)
                if let color = run.foregroundColor {
                    paragraph.addAttribute(.foregroundColor, value: NSColor(color), range: range)
                }
                if let color = run.backgroundColor {
                    paragraph.addAttribute(.backgroundColor, value: NSColor(color), range: range)
                }
                offset += length
            }
            value.append(paragraph)
        }
        let selection = view.selectedRanges
        // Canonically equal text can be shorter in UTF-16, invalidating the old selection.
        let sameText = view.string.utf8.elementsEqual(value.string.utf8)
        view.textContainer?.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        view.textStorage?.setAttributedString(value)
        if sameText { view.selectedRanges = selection }
    }

    final class Coordinator {
        var lines: [CodeRunLine] = []
        var language: Language?
        var width: CGFloat = 0
        var heights: [CGFloat] = []
        var scheme: ColorScheme?
    }

    final class TextView: NSTextView {
        var rowHeights: [CGFloat] = []
        var commentable: [Bool] = []
        var editableRows: [Bool] = []
        var onComment: ((Int) -> Void)?
        var onEdit: ((Int) -> Void)?
        private var menuRow: Int?
        private var menuComment: (() -> Void)?
        private var menuEdit: (() -> Void)?

        override func menu(for event: NSEvent) -> NSMenu? {
            let point = convert(event.locationInWindow, from: nil)
            menuRow = DiffDragRange.row(at: point.y, heights: rowHeights)
            let row = menuRow
            menuComment = row.flatMap { row in onComment.map { callback in { callback(row) } } }
            menuEdit = row.flatMap { row in onEdit.map { callback in { callback(row) } } }
            let menu = NSMenu()
            menu.autoenablesItems = false
            if let row = menuRow {
                if commentable.indices.contains(row), commentable[row] {
                    let item = menu.addItem(withTitle: "Comment on This Line", action: #selector(comment), keyEquivalent: "")
                    item.target = self
                }
                if editableRows.indices.contains(row), editableRows[row] {
                    let item = menu.addItem(withTitle: "Edit These Lines", action: #selector(edit), keyEquivalent: "")
                    item.target = self
                }
            }
            if !menu.items.isEmpty { menu.addItem(.separator()) }
            let copy = menu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "")
            copy.target = self
            copy.isEnabled = selectedRange().length > 0
            return menu
        }

        @objc private func comment() { menuComment?() }
        @objc private func edit() { menuEdit?() }
    }
}
