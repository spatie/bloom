import SwiftUI
import BloomCore

/// What a tab carried out of the strip draws over the centre column: the part of the pane it would
/// land in, and a small token of the tab under the pointer.
///
/// Drawn by the column over everything, in `CenterColumnView.space`, rather than by each pane. The
/// panes used to wash themselves from their own drop sessions, which is why this is the same accent
/// at the same strength `CenterPanesView` washes a moving pane with: one wash means "this is where
/// it goes" whichever thing is being carried.
///
/// Two views reading two properties, so the wash is not rebuilt every time the pointer moves and
/// the ghost is the only thing that is. See `TabCarry`.
struct TabCarryOverlay: View {
    var carry: TabCarry

    var body: some View {
        ZStack(alignment: .topLeading) {
            TabCarryWash(carry: carry)
            TabCarryGhost(carry: carry)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct TabCarryWash: View {
    var carry: TabCarry

    var body: some View {
        if let frame = carry.landing?.frame {
            Rectangle()
                .fill(Palette.accent.opacity(0.12))
                .frame(width: frame.width, height: frame.height)
                .position(x: frame.midX, y: frame.midY)
        }
    }
}

/// The tab, as a chip under the pointer, once it has left the strip.
///
/// A chip with the tab's own glyph and name rather than `CenterPanesView`'s blank plate, because a
/// tab has a name worth carrying and a pane being moved does not: the plate stands for a pane the
/// user can already see, and this stands for a tab they have just dragged away from its label.
private struct TabCarryGhost: View {
    var carry: TabCarry

    /// Wide enough for the names tabs get, and no wider than a tab is allowed to be.
    private static let maximumWidth: CGFloat = 200

    var body: some View {
        if let lift = carry.lift, !carry.isInStrip {
            Label(lift.title, systemImage: lift.symbol)
                .labelStyle(.titleAndIcon)
                .font(Typo.caption)
                .lineLimit(1)
                .foregroundStyle(Palette.textPrimary)
                .padding(.horizontal, Metrics.spacingWide)
                .frame(height: TabItemView.tabHeight)
                .background { Capsule().fill(Palette.surface) }
                .overlay { Capsule().strokeBorder(Palette.border, lineWidth: Metrics.outline) }
                .elevation(.lifted)
                .frame(maxWidth: Self.maximumWidth)
                .position(carry.pointer)
        }
    }
}
