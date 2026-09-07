import SwiftUI
import BloomCore

extension TranscriptTableEntry {
    /// Part of the document, not an overlay or a smaller viewport: the final row can scroll
    /// fully clear of the composer, while scrolling through history keeps the whole pane usable.
    /// A stable entry after the queue also avoids re-keying the previous last row on each arrival.
    static var bottomSpacing: Self {
        Self(
            id: .bottomSpacing,
            contentKey: TranscriptContentKey {
                $0.combine("bottomSpacing")
                $0.combine(TranscriptLayout.block)
            },
            content: {
                AnyView(Color.clear.frame(height: TranscriptLayout.block).accessibilityHidden(true))
            }
        )
    }
}
