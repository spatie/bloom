import SwiftUI

/// A date heading in Home's list, with how many workspaces are under it.
///
/// The count is the half that makes the heading worth having. "Yesterday" alone is a divider;
/// "Yesterday 48" is a fact about how much happened, and it is the only place in the window that
/// says it, because the sidebar counts per project and never per day.
struct HomeGroupHeading: View {
    var title: String
    var count: Int

    var body: some View {
        HStack(spacing: Metrics.spacingWide) {
            Text(title)
                .font(Typo.captionEmphasis)
                .foregroundStyle(Palette.textSecondary)

            Text(count, format: .number)
                .font(Typo.caption)
                .monospacedDigit()
                .foregroundStyle(Palette.textTertiary)

            Spacer(minLength: 0)
        }
        // One phrase, so a VoiceOver user hears "Yesterday, 48 workspaces" rather than a heading
        // and then a loose number.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(count == 1 ? "\(title), 1 workspace" : "\(title), \(count) workspaces")
        .accessibilityAddTraits(.isHeader)
    }
}
