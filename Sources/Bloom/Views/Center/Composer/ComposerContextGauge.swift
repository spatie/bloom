import SwiftUI

/// How full the context window is, in the composer footer, with the numbers behind it on click.
///
/// It sits with the model and the permission mode because it answers the same kind of question:
/// something about the next turn that the user may want to act on before sending it.
struct ComposerContextGauge: View {
    /// The percentage and the spoken sentence, formatted by the footer. Passed in rather than
    /// worked out here because this control is built two or three times per pass: see
    /// `ContextWindowUsage.Reading`.
    var reading: ContextWindowUsage.Reading
    /// Owned by the footer, not by this view, and the popover is attached there too.
    ///
    /// `ComposerFooterView` draws this row inside a `ViewThatFits` with three candidates, and two
    /// of them contain this control. State inside a candidate is state that goes away when
    /// `ViewThatFits` picks a different one, so narrowing the pane while the detail was open
    /// swapped the candidate and took the popover's presenter out of the tree with it. A flag the
    /// footer holds, and a presenter attached outside the `ViewThatFits`, cannot be swapped out
    /// from under an open popover. This file had already hoisted three arrays out for the same
    /// reason.
    @Binding var isShowingDetail: Bool

    @State private var isHovered = false

    var body: some View {
        Button {
            isShowingDetail = true
        } label: {
            Text(reading.percent)
                .monospacedDigit()
                .font(Typo.label)
                .foregroundStyle(Palette.textSecondary)
                .padding(.horizontal, Metrics.spacing)
                .frame(height: Metrics.rowHeight)
                .background {
                    RoundedRectangle(cornerRadius: Metrics.cornerSmall)
                        .fill(isHovered ? Palette.hover : .clear)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .fixedSize()
        .help("Context window")
        .accessibilityLabel("Context window")
        .accessibilityValue(reading.spoken)
    }
}

/// The filled track both the footer gauge and its popover draw, so the two cannot disagree about
/// what "nearly full" looks like.
struct ContextWindowBar: View {
    var fraction: Double
    var isCrowded: Bool

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Palette.selected)
                Capsule()
                    .fill(isCrowded ? Palette.warning : Palette.accent)
                    .frame(width: max(proxy.size.height, proxy.size.width * fraction))
            }
        }
        .accessibilityHidden(true)
    }
}
