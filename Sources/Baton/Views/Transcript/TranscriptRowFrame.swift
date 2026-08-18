import SwiftUI

/// The frame every single line row shares.
///
/// A transcript only scans if each row is exactly one line tall and starts on the same column, and
/// the surest way to lose that is eight views each repeating the same padding and the same height
/// until one of them drifts. The height scales with the user's text size, because a row pinned to
/// 28 points clips its own label the moment someone raises it. The columns themselves stay fixed,
/// so an expanded body still lands under the label it belongs to at any text size.
struct TranscriptRowFrame: ViewModifier {
    @ScaledMetric(relativeTo: .callout) private var height = Metrics.rowHeight

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, TranscriptLayout.inset)
            .frame(height: height)
    }
}

extension View {
    func transcriptRowFrame() -> some View {
        modifier(TranscriptRowFrame())
    }
}
