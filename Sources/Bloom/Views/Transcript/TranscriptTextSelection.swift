import AppKit
import SwiftUI
import BloomCore

extension EnvironmentValues {
    @Entry var transcriptTextSelection: TranscriptTextSelection?
}

/// One answer owns a selection even though its tables and code fences need separate layouts.
/// Weak members let SwiftUI discard rows without keeping the transcript's text views alive.
@MainActor
final class TranscriptTextSelection {
    private let members = NSHashTable<LinkTextView>.weakObjects()
    private weak var anchorView: LinkTextView?
    private var anchorOffset = 0
    private var selectsWholeAnswer = false
    private var updating = false
    var source = ""

    func register(_ view: LinkTextView) { members.add(view) }
    func unregister(_ view: LinkTextView) { members.remove(view) }

    var orderedViews: [LinkTextView] {
        members.allObjects.filter { $0.window != nil }.sorted { lhs, rhs in
            let left = lhs.convert(lhs.bounds, to: nil)
            let right = rhs.convert(rhs.bounds, to: nil)
            if abs(left.maxY - right.maxY) > 1 { return left.maxY > right.maxY }
            return left.minX < right.minX
        }
    }

    func clear() {
        updating = true
        defer { updating = false }
        selectsWholeAnswer = false
        anchorView = nil
        for view in orderedViews { view.setSelectedRange(NSRange(location: 0, length: 0)) }
    }

    func selectAll() {
        selectsWholeAnswer = true
        anchorView = orderedViews.first
        anchorOffset = 0
        updating = true
        defer { updating = false }
        for view in orderedViews {
            view.setSelectedRange(NSRange(location: 0, length: view.string.utf16.count))
        }
    }

    var selectedText: String {
        if selectsWholeAnswer { return source }
        var output = ""
        for view in orderedViews {
            let range = view.selectedRange()
            guard let storage = view.textStorage, range.length > 0 else { continue }
            if !output.isEmpty { output += view.copySeparatorBefore }
            if range.location == 0 { output += view.copyPrefix }
            output += TranscriptLink.selectedText(in: storage, range: range)
        }
        return output
    }

    func begin(in view: LinkTextView, offset: Int, extending: Bool) {
        selectsWholeAnswer = false
        if !extending || anchorView == nil {
            anchorView = view
            anchorOffset = offset
        }
        extend(to: view, offset: offset)
    }

    func extend(to view: LinkTextView, offset: Int) {
        let views = orderedViews
        guard let anchorView, let start = views.firstIndex(of: anchorView),
              let end = views.firstIndex(of: view) else { return }
        let ranges = TranscriptSelection.ranges(
            lengths: views.map { $0.string.utf16.count },
            anchor: .init(block: start, offset: anchorOffset), end: .init(block: end, offset: offset)
        )
        updating = true
        defer { updating = false }
        for (member, range) in zip(views, ranges) { member.setSelectedRange(range) }
    }

    /// Keyboard movement and AppKit's contextual selection start a new selection in one block.
    func nativeSelectionChanged(in view: LinkTextView) {
        guard !updating else { return }
        selectsWholeAnswer = false
        anchorView = view
        anchorOffset = view.selectedRange().location
        updating = true
        defer { updating = false }
        for member in orderedViews where member !== view {
            member.setSelectedRange(NSRange(location: 0, length: 0))
        }
    }

    func extend(at point: NSPoint) {
        let views = orderedViews
        // A table has neighbours on the same line, so choose the nearest rectangle in both axes.
        guard let target = views.min(by: { distance(point, from: $0) < distance(point, from: $1) }) else { return }
        extend(to: target, offset: target.selectionOffset(at: point))
    }

    private func distance(_ point: NSPoint, from view: NSView) -> CGFloat {
        let rect = view.convert(view.bounds, to: nil)
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return dx * dx + dy * dy
    }
}

extension LinkTextView {
    func selectionOffset(at windowPoint: NSPoint) -> Int {
        let point = convert(windowPoint, from: nil)
        if point.y < bounds.minY { return 0 }
        if point.y > bounds.maxY { return string.utf16.count }
        return min(characterIndexForInsertion(at: point), string.utf16.count)
    }

    /// Native text selection tracks inside one text container. Track this answer's containers
    /// together so a drag can leave a paragraph, pass a code toolbar, and continue into a table.
    func trackAnswerSelection(with event: NSEvent, selection: TranscriptTextSelection) -> Bool {
        guard let window else { return false }
        window.makeFirstResponder(self)
        let offset = selectionOffset(at: event.locationInWindow)
        let granularity: NSSelectionGranularity = event.clickCount >= 3 ? .selectByParagraph
            : event.clickCount == 2 ? .selectByWord : .selectByCharacter
        let initial = selectionRange(forProposedRange: NSRange(location: offset, length: 0), granularity: granularity)
        selection.begin(in: self, offset: initial.location, extending: event.modifierFlags.contains(.shift))
        selection.extend(to: self, offset: NSMaxRange(initial))
        var latest = event
        var dragged = false
        while self.window === window {
            let next = window.nextEvent(
                matching: [.leftMouseDragged, .leftMouseUp],
                until: Date(timeIntervalSinceNow: 0.05), inMode: .eventTracking, dequeue: true
            )
            if let next {
                if next.type == .leftMouseUp { break }
                latest = next
            }
            guard latest.type == .leftMouseDragged else { continue }
            dragged = true
            // Use the transcript's vertical scroll view, including when this text is inside a
            // horizontally scrolling code fence. Repeating at the edge also scrolls a held drag.
            var ancestor: NSView? = self
            while let current = ancestor {
                if let scroll = current as? NSScrollView, scroll.hasVerticalScroller {
                    _ = scroll.contentView.autoscroll(with: latest)
                    break
                }
                ancestor = current.superview
            }
            selection.extend(at: latest.locationInWindow)
        }
        return dragged
    }
}
