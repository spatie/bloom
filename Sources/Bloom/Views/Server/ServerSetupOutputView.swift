import AppKit
import BloomCore
import SwiftUI

/// A single native text surface keeps streamed installation output selectable and searchable.
struct ServerSetupOutputView: NSViewRepresentable {
    let lines: [ServerSetupActivity.Line]
    let followsOutput: Bool

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.borderType = .bezelBorder
        scroll.backgroundColor = .textBackgroundColor
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        storage.addLayoutManager(layout)
        layout.addTextContainer(container)
        let text = NSTextView(frame: .zero, textContainer: container)
        text.isEditable = false
        text.isSelectable = true
        text.isRichText = false
        text.allowsUndo = false
        text.usesFindBar = true
        text.isIncrementalSearchingEnabled = true
        text.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        text.textColor = .labelColor
        text.backgroundColor = .textBackgroundColor
        text.textContainerInset = NSSize(width: 8, height: 8)
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        text.minSize = .zero
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        text.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        text.setAccessibilityLabel("Server installation output")
        scroll.documentView = text
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let text = scroll.documentView as? NSTextView else { return }
        context.coordinator.update(lines, followsOutput: followsOutput, text: text, scroll: scroll)
    }

    @MainActor final class Coordinator {
        private var previous: [ServerSetupActivity.Line] = []
        private var wasFollowing = false

        func update(_ lines: [ServerSetupActivity.Line], followsOutput: Bool, text: NSTextView, scroll: NSScrollView) {
            let samePrefix = previous.count <= lines.count && zip(previous, lines).allSatisfy {
                $0.id == $1.id && $0.text == $1.text
            }
            let changed = !samePrefix || previous.count != lines.count
            defer { wasFollowing = followsOutput }
            guard changed else {
                if followsOutput && !wasFollowing { text.scrollToEndOfDocument(nil) }
                return
            }
            let selection = text.selectedRanges.map(\.rangeValue)
            let visible = visibleAnchor(text: text, scroll: scroll)
            let removedLength: Int
            if samePrefix {
                removedLength = 0
                let addition = lines.dropFirst(previous.count).map { $0.text + "\n" }.joined()
                text.textStorage?.append(NSAttributedString(string: addition, attributes: attributes(text)))
            } else {
                // The model evicts old lines at its limit. Keep the surviving characters selected,
                // rather than moving a reader to the newest output whenever eviction occurs.
                if let first = lines.first, let index = previous.firstIndex(where: { $0.id == first.id }) {
                    removedLength = previous.prefix(index).reduce(0) { $0 + $1.text.utf16.count + 1 }
                } else {
                    removedLength = (text.string as NSString).length
                }
                text.textStorage?.setAttributedString(NSAttributedString(
                    string: lines.map { $0.text + "\n" }.joined(), attributes: attributes(text)
                ))
            }
            previous = lines
            let length = (text.string as NSString).length
            text.selectedRanges = selection.map { range in
                let start = min(length, max(0, range.location - removedLength))
                let end = min(length, max(start, NSMaxRange(range) - removedLength))
                return NSValue(range: NSRange(location: start, length: end - start))
            }
            if followsOutput {
                text.scrollToEndOfDocument(nil)
            } else if let visible {
                restoreAnchor(visible, removing: removedLength, text: text, scroll: scroll)
            }
        }

        private func attributes(_ text: NSTextView) -> [NSAttributedString.Key: Any] {
            [.font: text.font ?? NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
             .foregroundColor: NSColor.labelColor]
        }

        private struct Anchor {
            let character: Int
            let verticalOffset: CGFloat
        }

        private func visibleAnchor(text: NSTextView, scroll: NSScrollView) -> Anchor? {
            guard let layout = text.layoutManager, let container = text.textContainer else { return nil }
            layout.ensureLayout(for: container)
            guard layout.numberOfGlyphs > 0 else { return nil }
            let origin = scroll.contentView.bounds.origin
            let point = NSPoint(x: 0, y: max(0, origin.y - text.textContainerInset.height))
            let glyph = min(layout.numberOfGlyphs - 1, layout.glyphIndex(for: point, in: container))
            let rect = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            return Anchor(character: layout.characterIndexForGlyph(at: glyph),
                          verticalOffset: origin.y - rect.minY - text.textContainerInset.height)
        }

        private func restoreAnchor(_ anchor: Anchor, removing: Int, text: NSTextView, scroll: NSScrollView) {
            guard let layout = text.layoutManager, let container = text.textContainer else { return }
            layout.ensureLayout(for: container)
            let length = (text.string as NSString).length
            var position = NSPoint.zero
            if length > 0 {
                let character = min(length - 1, max(0, anchor.character - removing))
                let glyph = layout.glyphIndexForCharacter(at: character)
                let rect = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
                position.y = max(0, rect.minY + text.textContainerInset.height + anchor.verticalOffset)
            }
            let clip = scroll.contentView
            let proposed = NSRect(origin: position, size: clip.bounds.size)
            clip.scroll(to: clip.constrainBoundsRect(proposed).origin)
            scroll.reflectScrolledClipView(clip)
        }
    }
}
