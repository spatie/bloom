import SwiftUI

/// The quiet scope band shared by native review panes.
public struct BloomDiffHunkHeader<Symbol: View, Title: View>: View {
    private let symbol: Symbol
    private let title: Title
    private let spacing: CGFloat
    private let inset: CGFloat
    private let width: CGFloat?
    private let height: CGFloat?
    private let foreground: Color
    private let surface: Color

    public init(spacing: CGFloat = 6, inset: CGFloat = 8, width: CGFloat? = nil, height: CGFloat? = nil,
                foreground: Color = .secondary, surface: Color = .primary.opacity(0.035),
                @ViewBuilder symbol: () -> Symbol, @ViewBuilder title: () -> Title) {
        self.spacing = spacing
        self.inset = inset
        self.width = width
        self.height = height
        self.foreground = foreground
        self.surface = surface
        self.symbol = symbol()
        self.title = title()
    }

    public var body: some View {
        HStack(spacing: spacing) {
            symbol.accessibilityHidden(true)
            title.lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .foregroundStyle(foreground)
        .padding(.horizontal, inset)
        .frame(width: width, height: height, alignment: .leading)
        .background(surface)
    }
}
