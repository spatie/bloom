import AppKit
import SwiftUI
import BloomCore

/// A single drawing surface for the washes and gutters. A wrapped run can span hundreds
/// of visual rows; none of those needs a separate SwiftUI layout graph during scrolling.
struct WrappedDiffChrome: NSViewRepresentable {
    var lines: [DiffRunLine]
    var heights: [CGFloat]
    var numbers: DiffGutter.Numbers
    var onComment: (Int) -> Void
    var onEdit: (Int) -> Void
    var commentable: [Bool]
    var editable: [Bool]
    @Environment(\.colorScheme) private var colorScheme

    func makeNSView(context: Context) -> ChromeView {
        let view = ChromeView()
        view.toolTip = "Use Up and Down to choose a line, then Return to comment."
        return view
    }

    func updateNSView(_ view: ChromeView, context: Context) {
        view.onComment = onComment
        view.onEdit = onEdit
        view.commentable = commentable
        view.editableRows = editable
        guard view.lines != lines || view.heights != heights || view.numbers != numbers
                || view.scheme != colorScheme else { return }
        view.lines = lines
        view.heights = heights
        view.numbers = numbers
        view.scheme = colorScheme
        view.accessibleRows = nil
        view.needsDisplay = true
    }

    final class ChromeView: NSView {
        var lines: [DiffRunLine] = []
        var heights: [CGFloat] = []
        var numbers = DiffGutter.Numbers.both
        var scheme: ColorScheme?
        var onComment: ((Int) -> Void)?
        var onEdit: ((Int) -> Void)?
        var commentable: [Bool] = []
        var editableRows: [Bool] = []
        var accessibleRows: [NSAccessibilityElement]?
        private var keyboardRow: Int?
        private var menuRow: Int?
        private var menuComment: (() -> Void)?
        private var menuEdit: (() -> Void)?

        override var isFlipped: Bool { true }
        override var acceptsFirstResponder: Bool { commentable.contains(true) }
        override var canBecomeKeyView: Bool { acceptsFirstResponder }

        override func becomeFirstResponder() -> Bool {
            keyboardRow = commentable.firstIndex(of: true)
            needsDisplay = true
            return true
        }

        override func resignFirstResponder() -> Bool {
            keyboardRow = nil
            needsDisplay = true
            return true
        }

        override func keyDown(with event: NSEvent) {
            if let row = keyboardRow, !commentable.indices.contains(row) || !commentable[row] {
                keyboardRow = commentable.firstIndex(of: true)
                needsDisplay = true
            }
            guard let row = keyboardRow else { super.keyDown(with: event); return }
            switch event.keyCode {
            case 125, 126:
                let candidates = commentable.indices.filter { commentable[$0] }
                let next = event.keyCode == 125
                    ? candidates.first(where: { $0 > row }) : candidates.last(where: { $0 < row })
                if let next {
                    keyboardRow = next
                    scrollToVisible(NSRect(x: 0, y: heights.prefix(next).reduce(0, +),
                                           width: bounds.width, height: heights[next]))
                    needsDisplay = true
                }
            case 36, 49: onComment?(row)
            case 48:
                if event.modifierFlags.contains(.shift) {
                    window?.selectPreviousKeyView(self)
                } else {
                    window?.selectNextKeyView(self)
                }
            default: super.keyDown(with: event)
            }
        }

        override func setFrameSize(_ newSize: NSSize) {
            let changed = newSize != frame.size
            super.setFrameSize(newSize)
            if changed { accessibleRows = nil; needsDisplay = true }
        }

        override func draw(_ dirtyRect: NSRect) {
            var y: CGFloat = 0
            let gutter = DiffGutter.width(for: numbers)
            for (index, entry) in lines.enumerated() {
                let rect = NSRect(x: 0, y: y, width: bounds.width, height: heights[index])
                defer { y += heights[index] }
                guard rect.intersects(dirtyRect) else { continue }
                NSColor(DiffWash.background(of: entry.line)).setFill()
                rect.fill()
                if entry.isCommented { NSColor(Palette.reviewLine).setFill(); rect.fill() }
                if keyboardRow == index, window?.firstResponder === self {
                    NSColor.keyboardFocusIndicatorColor.setStroke()
                    NSBezierPath(rect: rect.insetBy(dx: 1, dy: 1)).stroke()
                }
                if entry.line == nil {
                    NSColor(Palette.surfaceSunken).setFill()
                    NSRect(x: gutter, y: y, width: max(0, bounds.width - gutter), height: rect.height).fill()
                }
                let cell = CodeMetrics.numberWidth + CodeMetrics.gutterPadding
                if numbers == .both {
                    drawNumber(entry.line?.oldNumber, x: 0, y: y)
                    drawNumber(entry.line?.newNumber, x: cell, y: y)
                } else {
                    drawNumber(numbers == .old ? entry.line?.oldNumber : entry.line?.newNumber, x: 0, y: y)
                }
                let marker = entry.line?.kind == .addition ? "+" : entry.line?.kind == .deletion ? "−" : ""
                drawText(marker, x: gutter, y: y, width: CodeMetrics.markerWidth, rightAligned: false)
            }
        }

        private func drawNumber(_ number: Int?, x: CGFloat, y: CGFloat) {
            guard let number else { return }
            drawText(String(number), x: x, y: y, width: CodeMetrics.numberWidth, rightAligned: true)
        }

        private func drawText(_ text: String, x: CGFloat, y: CGFloat, width: CGFloat, rightAligned: Bool) {
            let value = NSAttributedString(string: text, attributes: [
                .font: CodeMetrics.numberFont, .foregroundColor: NSColor(Palette.textTertiary),
            ])
            let size = value.size()
            value.draw(at: NSPoint(x: x + (rightAligned ? width - size.width : (width - size.width) / 2),
                                   y: y + (CodeMetrics.rowHeight - size.height) / 2))
        }

        override func accessibilityChildren() -> [Any]? {
            if let accessibleRows { return accessibleRows }
            var elements: [NSAccessibilityElement] = []
            var y: CGFloat = 0
            for (index, entry) in lines.enumerated() {
                defer { y += heights[index] }
                guard entry.line != nil else { continue }
                let element = NSAccessibilityElement()
                element.setAccessibilityRole(.row)
                element.setAccessibilityLabel(DiffGutter.speech(for: entry.line))
                element.setAccessibilityParent(self)
                element.setAccessibilityFrameInParentSpace(NSRect(x: 0, y: y, width: bounds.width, height: heights[index]))
                var actions: [NSAccessibilityCustomAction] = []
                if commentable[index] {
                    actions.append(NSAccessibilityCustomAction(name: "Comment on This Line") { [onComment] in
                        onComment?(index)
                        return true
                    })
                }
                if editableRows[index] {
                    actions.append(NSAccessibilityCustomAction(name: "Edit These Lines") { [onEdit] in
                        onEdit?(index)
                        return true
                    })
                }
                element.setAccessibilityCustomActions(actions)
                elements.append(element)
            }
            accessibleRows = elements
            return elements
        }

        override func menu(for event: NSEvent) -> NSMenu? {
            menuRow = DiffDragRange.row(at: convert(event.locationInWindow, from: nil).y, heights: heights)
            guard let row = menuRow else { return nil }
            menuComment = onComment.map { callback in { callback(row) } }
            menuEdit = onEdit.map { callback in { callback(row) } }
            let menu = NSMenu()
            if commentable[row] {
                menu.addItem(withTitle: "Comment on This Line", action: #selector(comment), keyEquivalent: "").target = self
            }
            if editableRows[row] {
                menu.addItem(withTitle: "Edit These Lines", action: #selector(edit), keyEquivalent: "").target = self
            }
            return menu.items.isEmpty ? nil : menu
        }

        @objc private func comment() { menuComment?() }
        @objc private func edit() { menuEdit?() }
    }
}
