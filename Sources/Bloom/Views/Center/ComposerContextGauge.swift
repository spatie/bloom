import SwiftUI

/// How full the context window is, in the composer footer, with the numbers behind it on click.
///
/// It sits with the model and the permission mode because it answers the same kind of question:
/// something about the next turn that the user may want to act on before sending it.
struct ComposerContextGauge: View {
    var usage: ContextWindowUsage

    @State private var isShowingDetail = false
    @State private var isHovered = false

    /// The bar in the footer. Narrow, because the number beside it is the reading and this only
    /// says how close to full that number is.
    private static let barWidth: CGFloat = 26
    private static let barHeight: CGFloat = 4

    /// Where a nearly full window stops being background information. Past it the bar takes the
    /// warning colour, which is the only thing in this control that asks to be noticed.

    var body: some View {
        Button {
            isShowingDetail = true
        } label: {
            HStack(spacing: Metrics.spacingSmall) {
                bar
                Text(ContextWindowUsage.percent(usage.fraction))
                    .monospacedDigit()
            }
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
        // The crowded state is drawn as amber and as nothing else, so it has to be said here or
        // a reader gets the number with no indication that the number is a problem.
        .accessibilityValue(
            "\(ContextWindowUsage.percent(usage.fraction)) used, "
                + "\(ContextWindowUsage.format(usage.used)) of \(ContextWindowUsage.format(usage.limit)) tokens"
                + (usage.isCrowded ? ", filling up" : "")
        )
        .popover(isPresented: $isShowingDetail, arrowEdge: .top) {
            ContextWindowDetail(usage: usage)
        }
    }

    private var bar: some View {
        ContextWindowBar(fraction: usage.fraction, isCrowded: usage.isCrowded)
            .frame(width: Self.barWidth, height: Self.barHeight)
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
