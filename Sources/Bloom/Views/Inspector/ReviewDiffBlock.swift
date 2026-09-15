import SwiftUI
import BloomCore

/// Reserves a run's exact height without laying out its selectable text offscreen.
/// A horizontal scroller gives its contents unlimited vertical room, so a lazy stack
/// inside it cannot virtualise against the all-files review's vertical viewport.
///
/// Not `frame(in: .scrollView)`: a programmatic jump left that frame where the block last
/// reported it, and a block covering the whole viewport drew nothing. See `ReviewViewport`.
struct ReviewDiffBlock<Content: View>: View {
    var height: CGFloat
    @ViewBuilder var content: () -> Content

    @State private var frame: CGRect?
    @Environment(\.reviewVisibleRect) private var visibleRect
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled

    var body: some View {
        Color.clear
            .frame(height: height)
            .overlay(alignment: .topLeading) {
                // VoiceOver must be able to move to lines beyond the visual viewport.
                if isNearViewport || voiceOverEnabled { content() }
            }
            .onGeometryChange(for: CGRect.self) { proxy in
                proxy.frame(in: .named(ReviewDocument.space))
            } action: {
                frame = $0
            }
    }

    private var isNearViewport: Bool {
        guard let frame, let visibleRect else { return false }
        return ReviewViewport.isNear(top: frame.minY, bottom: frame.maxY,
                                     visibleTop: visibleRect.minY, visibleHeight: visibleRect.height)
    }
}
