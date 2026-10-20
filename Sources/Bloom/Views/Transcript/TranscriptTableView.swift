import AppKit
import BloomCore

/// AppKit can retain realised row origins after a resize even though rect(ofRow:) and the
/// document height have already changed. In a live transcript the final cells were 92 points
/// below their reported rectangles, outside the scrollable document. Retiling and reporting
/// the heights again did not repair it. Reconcile the realised origins after layout instead;
/// this neither creates offscreen cells nor measures SwiftUI content.
@MainActor
final class TranscriptTableView: NSTableView {
    /// Puts a passage of this conversation into its own reply. Nil where the conversation has no
    /// composer to reply in, which is an archived workspace. See `SelectionToChat`.
    var quoteSelection: (@MainActor (String) -> Void)?

    /// The conversation drawn here, so a paste over its selection reaches its own composer rather
    /// than the focused chat's. See `TypeToComposer`.
    var session: SessionID?

    /// What Select All and a drag across rows select. While it holds anything the table has the
    /// keyboard, because the text view the selection began in is usually recycled before Copy is
    /// pressed. See `TranscriptConversationSelection`.
    var conversation: TranscriptConversationSelection? {
        didSet { conversation?.responder = self }
    }

    /// The table has been laid out at a new width, and the rows on screen are owed heights for it.
    /// See `TranscriptTable.Coordinator.widthChanged`.
    var didChangeWidth: (@MainActor () -> Void)?

    override func selectAll(_ sender: Any?) {
        guard let conversation else { super.selectAll(sender); return }
        conversation.selectAll()
    }

    @objc func copy(_ sender: Any?) {
        guard let text = conversation?.selectedText else { return }
        TranscriptLink.copy(text)
    }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        guard item.action == #selector(copy(_:)) else { return super.validateUserInterfaceItem(item) }
        return conversation?.selectedText?.isEmpty == false
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { conversation?.cancel() }
        return resigned
    }

    private var isAligningRows = false
    private var alignmentWork: Task<Void, Never>?
    /// The width `didChangeWidth` was last said at, so a width is said once however many layout
    /// passes a frame of a drag takes.
    private var laidOutWidth: CGFloat = 0

    /// **Said from the table's own layout, and not from the scroll view's frame notification.**
    /// That notification is posted from inside the scroll view's resize, and nothing promises the
    /// table has taken its new width by then. A row measured against the width the table is about
    /// to stop being wraps to the wrong number of lines. By the time the table lays itself out,
    /// its width is the column's width.
    ///
    /// The layout is asked for here as well, rather than trusting a frame change to ask for one.
    override func setFrameSize(_ newSize: NSSize) {
        let widthMoved = newSize.width != frame.width
        super.setFrameSize(newSize)
        if widthMoved { needsLayout = true }
    }

    override func layout() {
        super.layout()
        if bounds.width != laidOutWidth {
            laidOutWidth = bounds.width
            didChangeWidth?()
        }
        alignRowOrigins()
    }

    func alignRowOrigins() {
        guard !isAligningRows, alignmentWork == nil else { return }
        isAligningRows = true
        defer { isAligningRows = false }
        enumerateAvailableRowViews { row, index in
            guard index >= 0, index < self.numberOfRows else { return }
            let target = self.rect(ofRow: index).minY
            if abs(row.frame.minY - target) > 0.5 {
                row.setFrameOrigin(NSPoint(x: row.frame.minX, y: target))
            }
        }
    }

    /// A deliberate fold or insertion owns its intermediate positions until its animation
    /// finishes. Measurement corrections have zero duration and need no such grace period.
    func deferRowAlignment(for seconds: Double) {
        guard seconds > 0 else { return }
        alignmentWork?.cancel()
        alignmentWork = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self else { return }
            alignmentWork = nil
            needsLayout = true
            layoutSubtreeIfNeeded()
        }
    }
}
