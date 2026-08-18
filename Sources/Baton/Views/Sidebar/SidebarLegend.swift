import SwiftUI

/// What the glyph at the head of each sidebar row means.
///
/// The glyph is the densest thing in the window, and a legend is cheaper than making every state
/// self-explanatory at 13 points. Shown from the status bar's help button as a popover.
struct SidebarLegend: View {
    /// Wide enough for the longest explanation on one line, narrow enough to read as a legend.
    private static let width: CGFloat = 220

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.spacingWide) {
            Text("Workspace states")
                .font(Typo.captionEmphasis)
                .foregroundStyle(Palette.textSecondary)

            row(Palette.running, "An agent is working") {
                ActivityDot(isActive: true)
            }
            row(Palette.accent, "Finished, not read yet") {
                Image(systemName: "circle.fill").font(Typo.micro)
            }
            row(Palette.warning, "Setup script failed") {
                Image(systemName: "exclamationmark.triangle.fill").font(Typo.caption)
            }
            row(Palette.textTertiary, "Idle, on its own branch") {
                Image(systemName: "arrow.triangle.branch").font(Typo.caption)
            }
        }
        .padding(Metrics.gutter)
        .frame(width: Self.width)
    }

    private func row<Glyph: View>(
        _ tint: Color,
        _ text: String,
        @ViewBuilder glyph: () -> Glyph
    ) -> some View {
        HStack(spacing: Metrics.spacingWide) {
            glyph()
                .foregroundStyle(tint)
                .frame(width: Metrics.glyph, height: Metrics.glyph)
                // The glyph is the thing being explained, so the explanation beside it is the
                // whole accessible content of the row.
                .accessibilityHidden(true)
            Text(text)
                .font(Typo.caption)
                .foregroundStyle(Palette.textSecondary)
            Spacer(minLength: 0)
        }
    }
}
