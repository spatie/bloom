import SwiftUI
import BloomClient

/// The platform supplies selectable text and attachment controls; the bubble remains shared.
public struct BloomUserBubble<Content: View>: View {
    private let maxWidth: CGFloat
    private let fill: Color
    private let content: Content

    public init(
        maxWidth: CGFloat = BloomBubbleMetrics.maximumWidth,
        fill: Color = Color(red: Double((PaletteInk.accentFill.light >> 16) & 255) / 255,
                            green: Double((PaletteInk.accentFill.light >> 8) & 255) / 255,
                            blue: Double(PaletteInk.accentFill.light & 255) / 255),
        @ViewBuilder content: () -> Content
    ) {
        self.maxWidth = maxWidth
        self.fill = fill
        self.content = content()
    }

    public var body: some View {
        HStack(spacing: 0) {
            Spacer(minLength: BloomBubbleMetrics.leadingSpace)
            CappedWidth(width: maxWidth) {
                content.padding(BloomBubbleMetrics.padding)
            }
            .padding(.bottom, OutgoingBubbleShape.tailDrop)
            .background(fill, in: OutgoingBubbleShape(cornerRadius: BloomBubbleMetrics.corner))
            .foregroundStyle(.white)
            // This is a dark surface in either appearance, including its selection colours.
            .environment(\.colorScheme, .dark)
        }
    }
}
