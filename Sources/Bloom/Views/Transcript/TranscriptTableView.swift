import AppKit

/// AppKit can retain realised row origins after a resize even though rect(ofRow:) and the
/// document height have already changed. In a live transcript the final cells were 92 points
/// below their reported rectangles, outside the scrollable document. Retiling and reporting
/// the heights again did not repair it. Reconcile the realised origins after layout instead;
/// this neither creates offscreen cells nor measures SwiftUI content.
@MainActor
final class TranscriptTableView: NSTableView {
    private var isAligningRows = false
    private var alignmentWork: Task<Void, Never>?

    override func layout() {
        super.layout()
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
