import SwiftUI
import BloomClient

/// Replies share a subtle boundary and reading column, without an outgoing bubble or author label.
public struct BloomAssistantProse<Content: View>: View {
    private let maxWidth: CGFloat
    private let horizontalInset: CGFloat
    private let verticalInset: CGFloat
    private let showsSeparator: Bool
    private let separatorColor: Color?
    private let separatorHeight: CGFloat
    private let content: Content
    @Environment(\.colorScheme) private var scheme

    public init(
        maxWidth: CGFloat = 680,
        horizontalInset: CGFloat = 6,
        verticalInset: CGFloat = 8,
        showsSeparator: Bool = true,
        separatorColor: Color? = nil,
        separatorHeight: CGFloat = 1,
        @ViewBuilder content: () -> Content
    ) {
        self.maxWidth = maxWidth
        self.horizontalInset = horizontalInset
        self.verticalInset = verticalInset
        self.showsSeparator = showsSeparator
        self.separatorColor = separatorColor
        self.separatorHeight = separatorHeight
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: verticalInset) {
            if showsSeparator {
                Rectangle()
                    .fill(separatorColor ?? BloomColour.resolve(PaletteInk.border, scheme: scheme))
                    .frame(height: separatorHeight)
                    .accessibilityHidden(true)
            }
            content
                .textSelection(.enabled)
                .frame(maxWidth: maxWidth, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, horizontalInset)
        .padding(.vertical, verticalInset)
    }
}
