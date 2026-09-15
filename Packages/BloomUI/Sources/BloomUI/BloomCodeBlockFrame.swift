import SwiftUI

/// Shared fence structure with native copy controls and cached syntax text supplied by the host.
public struct BloomCodeBlockFrame<Label: View, Copy: View, Content: View, Fold: View>: View {
    private let surface: Color
    private let border: Color
    private let label: Label
    private let copy: Copy
    private let content: Content
    private let fold: Fold
    private let canFold: Bool

    public init(
        surface: Color = Color.primary.opacity(0.035),
        border: Color = Color.primary.opacity(0.15),
        canFold: Bool = false,
        @ViewBuilder label: () -> Label,
        @ViewBuilder copy: () -> Copy,
        @ViewBuilder content: () -> Content,
        @ViewBuilder fold: () -> Fold
    ) {
        self.surface = surface
        self.border = border
        self.canFold = canFold
        self.label = label()
        self.copy = copy()
        self.content = content()
        self.fold = fold()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                label
                Spacer(minLength: 12)
                copy
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            rule
            ScrollView(.horizontal) {
                content.padding(12)
            }
            if canFold {
                rule
                fold.padding(.horizontal, 12).padding(.vertical, 6)
            }
        }
        .background(surface)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay {
            RoundedRectangle(cornerRadius: 6).strokeBorder(border, lineWidth: 0.5)
        }
    }

    private var rule: some View { border.frame(height: 1).accessibilityHidden(true) }
}
