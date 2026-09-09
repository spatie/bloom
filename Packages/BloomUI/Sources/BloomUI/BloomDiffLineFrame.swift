import SwiftUI

/// Keeps the gutter, source and row wash continuous while the native host owns interactions.
public struct BloomDiffLineFrame<Gutter: View, Content: View>: View {
    private let width: CGFloat
    private let height: CGFloat
    private let gutter: Gutter
    private let content: Content

    public init(width: CGFloat, height: CGFloat, @ViewBuilder gutter: () -> Gutter, @ViewBuilder content: () -> Content) {
        self.width = width
        self.height = height
        self.gutter = gutter()
        self.content = content()
    }

    public var body: some View {
        HStack(spacing: 0) { gutter; content }
            .frame(width: width, height: height, alignment: .leading)
    }
}
