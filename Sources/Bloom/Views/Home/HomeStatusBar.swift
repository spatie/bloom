import SwiftUI
import BloomCore

/// The line along the foot of Home's list, saying what is in it.
///
/// **It used to be the trailing end of the strip at the top, and the owner's word for it was
/// "strange".** Two things were wrong with it up there. The bar was doing three jobs in one line,
/// so five chips, a project picker and a sentence all read at one weight and nothing led. And a
/// count printed above the thing it counts is a count in the wrong place: Finder says "23 items,
/// 140 GB available" along the bottom of the window, Mail counts its messages there, and both of
/// them are next to what they are counting.
///
/// Finder's register, deliberately: one line, caption ink, centred, a rule above it, and nothing
/// on it to press. The project filter stayed up on the strip for that last reason.
///
/// **It sits beside `SidebarStatusBar`, and the two are meant to read as one band.** They are both
/// `Palette.sidebar` at `Metrics.barHeight` with a `Hairline` over them, so what divides them
/// across the bottom of the window is the split view's own rule and nothing else. The sidebar's
/// half was on `.bar`, a material, which put it a few units off the column it stands in and off
/// this; that is the same argument `HomeBar` makes about the glass it lost.
struct HomeStatusBar: View {
    /// What the list adds up to, worked out by `HomeList.summary`. Empty means there is nothing to
    /// say, and then the bar is not drawn at all.
    var summary: String

    var body: some View {
        VStack(spacing: 0) {
            Hairline()

            Text(summary)
                .font(Typo.caption)
                .foregroundStyle(Palette.textTertiary)
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.horizontal, HomeMetrics.gutter)
                .frame(maxWidth: .infinity)
                .frame(height: Metrics.barHeight)
        }
        .background(Palette.sidebar)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Showing \(summary)")
    }
}
