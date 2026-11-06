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
        // Setting the text of a view not yet in a window resets its selection. Clearing every
        // member for each new view made building a long answer quadratic.
        guard !updating, view.window != nil else { return }
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
        guard let target = views.min(by: {
            $0.squaredDistance(fromWindowPoint: point) < $1.squaredDistance(fromWindowPoint: point)
        }) else { return }
        extend(to: target, offset: target.selectionOffset(at: point))
    }
}

extension NSView {
    /// How far a window point is from this view's rectangle, squared, and nought inside it.
    func squaredDistance(fromWindowPoint point: NSPoint) -> CGFloat {
        let rect = convert(bounds, to: nil)
        let horizontal = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let vertical = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return horizontal * horizontal + vertical * vertical
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
    /// A drag that leaves the answer altogether is handed to the conversation's selection, which
    /// is also what tracks a bubble, since a bubble belongs to no answer.
    func trackAnswerSelection(with event: NSEvent, selection: TranscriptTextSelection?) -> Bool {
        guard let window else { return false }
        window.makeFirstResponder(self)
        let offset = selectionOffset(at: event.locationInWindow)
        let granularity: NSSelectionGranularity = event.clickCount >= 3 ? .selectByParagraph
            : event.clickCount == 2 ? .selectByWord : .selectByCharacter
        let initial = selectionRange(forProposedRange: NSRange(location: offset, length: 0), granularity: granularity)
        if let selection {
            selection.begin(in: self, offset: initial.location, extending: event.modifierFlags.contains(.shift))
            selection.extend(to: self, offset: NSMaxRange(initial))
        } else {
            setSelectedRange(initial)
        }
        conversationSelection?.beginDrag(in: self, offset: initial.location)
        var latest = event
        var dragged = false
        // Found once, before the drag moves anything. The view the press landed in is recycled by
        // the table as soon as it scrolls away, and a loop that asked this view for its window or
        // its scroll view on every pass ended the drag the moment that happened: the selection
        // scrolled for a screen and then stopped, with the button still held.
        let scrollView = enclosingVerticalScrollView
        while window.isVisible && window.isKeyWindow {
            let next = window.nextEvent(
                matching: [.leftMouseDragged, .leftMouseUp],
                until: Date(timeIntervalSinceNow: 0.05), inMode: .eventTracking, dequeue: true
            )
            if let next {
                if next.type == .leftMouseUp { break }
                latest = next
            } else if NSEvent.pressedMouseButtons & 1 == 0 {
                // A mouse-up can be lost when the gesture is interrupted. Without this escape,
                // the tracking loop keeps requesting only drag and mouse-up events, leaving every
                // later click in the window unhandled until Bloom quits.
                break
            }
            // A press on a link that shifts by a point is still a click, and must still open it.
            guard latest.type == .leftMouseDragged,
                  dragged || TranscriptDrag.text.leavesClick(
                      dx: latest.locationInWindow.x - event.locationInWindow.x,
                      dy: latest.locationInWindow.y - event.locationInWindow.y
                  ) else { continue }
            dragged = true
            // The transcript's vertical scroll view, including when this text is inside a
            // horizontally scrolling code fence. Repeating at the edge also scrolls a held drag.
            _ = scrollView?.contentView.autoscroll(with: latest)
            let point = latest.locationInWindow
            if conversationSelection?.drag(to: point) == true { continue }
            if let selection {
                selection.extend(at: point)
            } else {
                extendSelection(from: initial, to: point)
            }
        }
        return dragged
    }

    private var enclosingVerticalScrollView: NSScrollView? {
        var ancestor: NSView? = self
        while let current = ancestor {
            if let scroll = current as? NSScrollView, scroll.hasVerticalScroller { return scroll }
            ancestor = current.superview
        }
        return nil
    }

    /// A bubble is one text view, so dragging inside it only has to join the press to the pointer.
    private func extendSelection(from initial: NSRange, to windowPoint: NSPoint) {
        let offset = selectionOffset(at: windowPoint)
        let start = min(initial.location, offset)
        setSelectedRange(NSRange(location: start, length: max(NSMaxRange(initial), offset) - start))
    }
}
