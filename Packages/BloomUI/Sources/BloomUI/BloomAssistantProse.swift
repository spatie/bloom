import SwiftUI

/// Replies are a reading column, without the outgoing message's bubble or a repeated author label.
public struct BloomAssistantProse<Content: View>: View {
    private let maxWidth: CGFloat
    private let horizontalInset: CGFloat
    private let verticalInset: CGFloat
    private let content: Content

    public init(
        maxWidth: CGFloat = 680,
        horizontalInset: CGFloat = 6,
        verticalInset: CGFloat = 8,
        @ViewBuilder content: () -> Content
    ) {
        self.maxWidth = maxWidth
        self.horizontalInset = horizontalInset
        self.verticalInset = verticalInset
        self.content = content()
    }

    public var body: some View {
        content
            .textSelection(.enabled)
            .frame(maxWidth: maxWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, horizontalInset)
            .padding(.vertical, verticalInset)
    }
}
