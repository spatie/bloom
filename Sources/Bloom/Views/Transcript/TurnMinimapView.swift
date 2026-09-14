import SwiftUI
import BloomCore

/// A mark per prompt down the margin of a long conversation. Pointing at one shows what was asked,
/// clicking goes there. The spacing, the fit and the hit testing are `TurnMinimap`'s.
///
/// **One `Canvas` rather than a view per mark.** A conversation of two hundred turns is two hundred
/// marks, and they change together whenever the reader crosses into another turn; as views that
/// is two hundred diffs on a scroll frame, as a canvas it is one redraw of a few rectangles.
///
/// The card is drawn to the left of the strip rather than as a popover, for the reason the pinned
/// question is an overlay: a window of its own would take focus arguments the transcript has
/// already settled, and it would lag a pointer moving down the strip by a frame per mark.
struct TurnMinimapView: View {
    var turns: [PinnedQuestion]
    /// The turn the reader is in, drawn longer and darker.
    var current: Int?
    var onOpen: (PinnedQuestion) -> Void

    @State private var height: CGFloat = 0
    @State private var hovered: Int?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let markHeight: CGFloat = 2
    private static let restingLength: CGFloat = 8
    private static let raisedLength: CGFloat = 14
    private static let cardWidth: CGFloat = 280

    var body: some View {
        // Clear and untouchable, so the margin it measures still scrolls and selects as the
        // transcript under it; only the strip itself takes the pointer.
        Color.clear
            .allowsHitTesting(false)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
            .overlay(alignment: .trailing) {
                if let map = TurnMinimap(turns: turns.count, height: height) {
                    strip(map)
                }
            }
    }

    private func strip(_ map: TurnMinimap) -> some View {
        Canvas { context, size in
            let top = (size.height - map.length) / 2
            let thickness = min(Self.markHeight, max(map.pitch * 0.6, 1))
            for index in turns.indices {
                let isCurrent = index == current
                let isHovered = index == hovered
                let length = isCurrent || isHovered ? Self.raisedLength : Self.restingLength
                let rect = CGRect(
                    x: size.width - length,
                    y: top + map.centre(of: index) - thickness / 2,
                    width: length,
                    height: thickness
                )
                let ink = isCurrent ? Palette.textPrimary : isHovered ? Palette.textSecondary : Palette.textTertiary
                context.fill(Path(roundedRect: rect, cornerRadius: thickness / 2), with: .color(ink))
            }
        }
        .frame(width: TurnMinimap.width, height: map.length)
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            switch phase {
            case .active(let point):
                let index = map.index(at: point.y)
                if hovered != index { hovered = index }
            case .ended:
                hovered = nil
            }
        }
        .gesture(SpatialTapGesture().onEnded { tap in
            onOpen(turns[map.index(at: tap.location.y)])
        })
        .pointerStyle(.link)
        .overlay(alignment: .topTrailing) {
            if let hovered, turns.indices.contains(hovered) {
                card(for: hovered)
                    .alignmentGuide(.top) { dimensions in
                        dimensions.height / 2 - map.centre(of: hovered)
                    }
                    // An alignment guide propagates into the enclosing trailing-aligned overlay
                    // and can shift the strip under its own card. Offset only the card, leaving
                    // the marks and their pointer target in place, with a visible gap between them.
                    .offset(x: -(TurnMinimap.width + Metrics.spacingWide))
                    .transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : Motion.hover, value: hovered == nil)
        .padding(.trailing, TurnMinimap.edgeInset)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Turns in this conversation")
        .accessibilityChildren {
            ForEach(turns, id: \.seq) { turn in
                Button(turn.summary) { onOpen(turn) }
            }
        }
    }

    private func card(for index: Int) -> some View {
        VStack(alignment: .leading, spacing: Metrics.spacingWide) {
            Text(turns[index].summary)
                .font(Typo.label)
                .foregroundStyle(Palette.textPrimary)
                .lineLimit(3)
                .truncationMode(.tail)
            Text("\(index + 1) of \(turns.count)")
                .font(Typo.micro)
                .foregroundStyle(Palette.textSecondary)
                .monospacedDigit()
        }
        .padding(Metrics.inset)
        .frame(width: Self.cardWidth, alignment: .leading)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: Metrics.corner))
        .overlay {
            RoundedRectangle(cornerRadius: Metrics.corner)
                .strokeBorder(Palette.border, lineWidth: Metrics.outline)
        }
        .elevation(.resting)
        .fixedSize(horizontal: true, vertical: true)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
