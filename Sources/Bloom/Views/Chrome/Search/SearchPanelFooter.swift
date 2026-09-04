import SwiftUI
import BloomCore

/// The strip along the bottom of the card: what the keys do, and how many results there are.
///
/// **The count sits on the right, where it does not compete with the keys.** The keys are what
/// somebody reads once and never again; the count is what changes while they type.
struct SearchPanelFooter: View {
    var keys: [SearchPanelFooterKey]
    var summary: String?

    var body: some View {
        HStack(spacing: Metrics.gutter) {
            ForEach(keys) { key in
                HStack(spacing: Metrics.spacingSmall) {
                    Text(key.key)
                        .font(Typo.caption)
                        .foregroundStyle(Palette.textSecondary)
                        .padding(.horizontal, Metrics.chipInsetH)
                        .padding(.vertical, Metrics.chipInsetV)
                        .background(
                            RoundedRectangle(cornerRadius: Metrics.cornerSmall)
                                .fill(Palette.hover)
                        )

                    Text(key.label)
                        .font(Typo.caption)
                        .foregroundStyle(Palette.textTertiary)
                }
            }

            Spacer(minLength: Metrics.spacingWide)

            if let summary {
                Text(summary)
                    .font(Typo.caption)
                    .foregroundStyle(Palette.textTertiary)
            }
        }
        .padding(.horizontal, Metrics.inset)
        .padding(.vertical, Metrics.spacingSmall)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) { Hairline() }
        // Read as one line, not as a row of controls: nothing here is pressable, so nothing here
        // should be reachable by a pointer or announced as a target.
        .accessibilityHidden(true)
    }
}
