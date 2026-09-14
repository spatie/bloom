import SwiftUI

/// Reserves a run's exact height without laying out its selectable text offscreen.
/// A horizontal scroller gives its contents unlimited vertical room, so a lazy stack
/// inside it cannot virtualise against the all-files review's vertical viewport.
struct ReviewDiffBlock<Content: View>: View {
    var height: CGFloat
    var viewportHeight: CGFloat
    @ViewBuilder var content: () -> Content

    @State private var isNearViewport = false
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled

    var body: some View {
        Color.clear
            .frame(height: height)
            .overlay(alignment: .topLeading) {
                // VoiceOver must be able to move to lines beyond the visual viewport.
                if isNearViewport || voiceOverEnabled { content() }
            }
            .onGeometryChange(for: Bool.self) { [viewportHeight] proxy in
                let frame = proxy.frame(in: .scrollView(axis: .vertical))
                // Prepare half a screen ahead without publishing every scroll offset.
                return frame.maxY > -viewportHeight / 2 && frame.minY < viewportHeight * 1.5
            } action: {
                isNearViewport = $0
            }
    }
}
