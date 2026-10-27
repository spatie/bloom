import AppKit
import BloomCore
import SwiftUI

extension EnvironmentValues {
    @Entry var transcriptConversationSelection: TranscriptConversationSelection?
    /// Which table entry a text view is drawn in, so a selection can say which rows it spans.
    @Entry var transcriptEntryID: TranscriptEntryID?
}

/// A selection that spans rows: Select All, and a drag that leaves the answer it started in.
/// `TranscriptTextSelection` is an answer's and stops at its edge.
///
/// **It holds a description, never ranges kept in views.** The table recycles a cell as soon as
/// it scrolls away, and a selection kept in the text views of a recycled row is gone, so a drag
/// longer than one screen would copy a conversation with holes in it. What is kept instead is the
/// two rows the drag started and ended in, the words selected in each, and everything between
/// them. The text is composed from the stored rows (`ConversationText`), the highlight is painted
/// onto whichever views exist and onto any that appear (`adopt`).
///
/// The table, not a text view, is the first responder while this is active: the view the drag
/// started in is usually recycled before Copy is pressed.
@MainActor
final class TranscriptConversationSelection {
    private enum Mode {
        case none
        case everything
        case span(Span)
    }

    /// The highlight for a drag across rows, and the words it copies. A part of a long answer
    /// counts as a row of its own, so a drag through an answer survives its parts being recycled.
    private struct Span {
        var first: TranscriptSelection.Place
        var last: TranscriptSelection.Place
        /// Keyed by a block's text: the row's views come and go, their strings do not.
        var firstRanges: [String: NSRange]
        var lastRanges: [String: NSRange]
        var slice: ConversationText.Slice
    }

    /// One row's text views as they were when the pointer was over it, in reading order.
    private struct RowSnapshot {
        struct Block {
            let key: String
            let text: NSAttributedString
            let prefix: String
            let separator: String
        }

        let place: TranscriptSelection.Place
        let blocks: [Block]
        var lengths: [Int] { blocks.map { $0.text.length } }

        func ranges(from start: TranscriptSelection.Position, to end: TranscriptSelection.Position) -> [NSRange] {
            TranscriptSelection.ranges(lengths: lengths, anchor: start, end: end)
        }

        @MainActor
        func text(in ranges: [NSRange]) -> String {
            var output = ""
            for (block, range) in zip(blocks, ranges) where range.length > 0 {
                if !output.isEmpty { output += block.separator }
                if range.location == 0 { output += block.prefix }
                output += TranscriptLink.selectedText(in: block.text, range: range)
            }
            return output
        }

        func keyed(_ ranges: [NSRange]) -> [String: NSRange] {
            Dictionary(zip(blocks.map(\.key), ranges), uniquingKeysWith: { first, _ in first })
        }
    }

    private let members = NSHashTable<LinkTextView>.weakObjects()
    private var mode = Mode.none
    private weak var anchorView: LinkTextView?
    private var anchorRow: RowSnapshot?
    private var anchorPosition = TranscriptSelection.Position(block: 0, offset: 0)
    /// True while this object is writing ranges, so the text views' own change notifications are
    /// not mistaken for the reader starting a selection of their own.
    private(set) var isApplying = false
    /// The table, which takes the keyboard while a selection spans rows.
    weak var responder: NSView?
    /// The conversation as text, optionally only a drag's slice of it. Set by the list, which
    /// owns the rows.
    var text: (ConversationText.Slice?) -> String = { _ in "" }

    var isActive: Bool {
        if case .none = mode { false } else { true }
    }

    var selectedText: String? {
        switch mode {
        case .none: nil
        case .everything: text(nil)
        case .span(let span): text(span.slice)
        }
    }

    func register(_ view: LinkTextView) { members.add(view) }
    func unregister(_ view: LinkTextView) { members.remove(view) }

    /// Whether `responder` is something this selection keeps its highlight for.
    func owns(_ candidate: NSResponder?) -> Bool {
        guard let candidate else { return false }
        return candidate === responder || (candidate as? LinkTextView)?.conversationSelection === self
    }

    // MARK: Select All

    func selectAll() {
        mode = .everything
        takeKeyboard()
        paint()
    }

    func cancel() {
        guard isActive else { return }
        mode = .none
        paint(clearing: true)
    }

    // MARK: Dragging

    /// A press in `view`, which is where a drag across rows would start.
    func beginDrag(in view: LinkTextView, offset: Int) {
        guard let place = view.selectionPlace else {
            anchorView = nil
            anchorRow = nil
            return
        }
        let views = rowViews(place)
        anchorView = view
        anchorRow = Self.snapshot(of: views, at: place)
        anchorPosition = .init(block: views.firstIndex(of: view) ?? 0, offset: offset)
    }

    /// The pointer moved to `point`. True when that is in a different row from where the press
    /// was, and this selection has painted it; false when the answer's own selection should.
    func drag(to point: NSPoint) -> Bool {
        guard let anchorRow, let target = nearestView(to: point), let targetPlace = target.selectionPlace else {
            return false
        }
        guard targetPlace != anchorRow.place else {
            return leaveSpan()
        }
        let targetViews = rowViews(targetPlace)
        let endRow = Self.snapshot(of: targetViews, at: targetPlace)
        let end = TranscriptSelection.Position(
            block: targetViews.firstIndex(of: target) ?? 0,
            offset: target.selectionOffset(at: point)
        )
        mode = .span(span(from: anchorRow, to: endRow, anchoredAt: anchorPosition, endingAt: end))
        takeKeyboard()
        paint()
        return true
    }

    /// The pointer came back into the row the press was in. Handing control back to the answer
    /// is only possible while its view still exists; if it was recycled meanwhile the selection
    /// stays as it was rather than being lost.
    private func leaveSpan() -> Bool {
        guard case .span = mode else { return false }
        guard let anchorView, anchorView.window != nil else { return true }
        mode = .none
        paint(clearing: true)
        responder?.window?.makeFirstResponder(anchorView)
        return false
    }

    private func span(
        from anchorRow: RowSnapshot, to endRow: RowSnapshot,
        anchoredAt anchor: TranscriptSelection.Position, endingAt end: TranscriptSelection.Position
    ) -> Span {
        let anchorComesFirst = anchorRow.place < endRow.place
        let (firstRow, firstFrom) = anchorComesFirst ? (anchorRow, anchor) : (endRow, end)
        let (lastRow, lastTo) = anchorComesFirst ? (endRow, end) : (anchorRow, anchor)
        let firstRanges = firstRow.ranges(
            from: firstFrom, to: .init(block: max(firstRow.blocks.count - 1, 0), offset: .max)
        )
        let lastRanges = lastRow.ranges(from: .init(block: 0, offset: 0), to: lastTo)
        return Span(
            first: firstRow.place, last: lastRow.place,
            firstRanges: firstRow.keyed(firstRanges), lastRanges: lastRow.keyed(lastRanges),
            slice: ConversationText.Slice(
                first: firstRow.place, last: lastRow.place,
                firstText: firstRow.text(in: firstRanges), lastText: lastRow.text(in: lastRanges)
            )
        )
    }

    // MARK: Painting

    /// A text view that has just been built, or given new text, while something is selected.
    func adopt(_ view: LinkTextView) {
        guard isActive, let range = range(for: view) else { return }
        isApplying = true
        defer { isApplying = false }
        view.setSelectedRange(range)
    }

    private func paint(clearing: Bool = false) {
        isApplying = true
        defer { isApplying = false }
        for view in members.allObjects {
            let wanted = clearing ? NSRange(location: 0, length: 0) : range(for: view)
            guard let wanted else { continue }
            view.setSelectedRange(wanted)
            view.needsDisplay = true
        }
    }

    private func range(for view: LinkTextView) -> NSRange? {
        let nothing = NSRange(location: 0, length: 0)
        let everything = NSRange(location: 0, length: view.string.utf16.count)
        switch mode {
        case .none:
            return nil
        case .everything:
            return everything
        case .span(let span):
            guard let place = view.selectionPlace else { return nil }
            if place < span.first || place > span.last { return nothing }
            if place == span.first { return span.firstRanges[view.string] ?? nothing }
            if place == span.last { return span.lastRanges[view.string] ?? nothing }
            return everything
        }
    }

    /// The keyboard goes to the table, so Copy and Select All keep working after the view the
    /// selection started in has been recycled.
    private func takeKeyboard() {
        guard let responder, let window = responder.window, window.firstResponder !== responder else { return }
        window.makeFirstResponder(responder)
    }

    // MARK: Finding views

    /// The text views of one row, or of one part of a long answer, in reading order.
    private func rowViews(_ place: TranscriptSelection.Place) -> [LinkTextView] {
        Self.inReadingOrder(members.allObjects.filter { $0.window != nil && $0.selectionPlace == place })
    }

    private static func inReadingOrder(_ views: [LinkTextView]) -> [LinkTextView] {
        views.sorted { lhs, rhs in
            let left = lhs.convert(lhs.bounds, to: nil)
            let right = rhs.convert(rhs.bounds, to: nil)
            if abs(left.maxY - right.maxY) > 1 { return left.maxY > right.maxY }
            return left.minX < right.minX
        }
    }

    private static func snapshot(of views: [LinkTextView], at place: TranscriptSelection.Place) -> RowSnapshot {
        RowSnapshot(place: place, blocks: views.map { view in
            RowSnapshot.Block(
                key: view.string,
                text: NSAttributedString(attributedString: view.textStorage ?? NSTextStorage()),
                prefix: view.copyPrefix,
                separator: view.copySeparatorBefore
            )
        })
    }

    /// Among the views that belong to a row, the one whose rectangle is closest to the point.
    private func nearestView(to point: NSPoint) -> LinkTextView? {
        members.allObjects
            .filter { $0.window != nil && $0.selectionPlace != nil }
            .min { $0.squaredDistance(fromWindowPoint: point) < $1.squaredDistance(fromWindowPoint: point) }
    }
}
