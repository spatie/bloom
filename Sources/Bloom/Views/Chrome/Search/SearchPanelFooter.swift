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
                    // One line, always. The keys on the left are four fixed pairs and cannot
                    // compress, so at the narrow end of `SearchPanelLayout` a long count would
                    // wrap this strip to two lines rather than shorten itself. Nothing said here
                    // is long enough today: measured at 560, the keys take about 330 points of the
                    // 540 available and the longest count is under 90.
                    .lineLimit(1)
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
