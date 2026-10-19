import BloomCore
import SwiftUI

/// One disclosure line that stands for hidden transcript work.
///
/// The label keeps the same geometry in both states. The commands belong inside the disclosure,
/// so the collapsed line never promotes one arbitrary command to a title.
struct TranscriptFoldRowView: View {
    var label: String
    var isExpanded: Bool
    /// Whether this stands for a subagent's own work, in which case it is drawn where those rows
    /// are drawn: indented under the call that started them, behind the same rule. A line at the
    /// margin standing for indented rows reads as work the main agent did.
    var isNested = false
    /// The completed turn treatment, with the label held between two quiet rules.
    var showsSeparator = false
    var onToggle: () -> Void

    @State private var isHovered = false

    var body: some View {
        ExpandableRowHeader(
            isExpanded: isExpanded,
            stablePressAppearance: showsSeparator,
            onToggle: onToggle
        ) {
            if showsSeparator {
                HStack(spacing: TranscriptLayout.block) {
                    separator

                    HStack(spacing: Metrics.spacingSmall) {
                        Text(label)
                            .font(Typo.caption)
                            .foregroundStyle(Palette.textSecondary)
                            .monospacedDigit()
                            .lineLimit(1)

                        TranscriptDisclosure(isExpanded: isExpanded, isVisible: true)
                            .frame(width: TranscriptLayout.disclosureWidth)
                    }
                    .fixedSize()

                    separator
                }
                .transcriptRowFrame()
            } else {
                HStack(spacing: Metrics.spacingSmall) {
                    TranscriptDisclosure(isExpanded: isExpanded, isVisible: true)
                        .frame(width: TranscriptLayout.disclosureWidth)

                    HStack(spacing: 0) {
                        Text(label)
                            .font(Typo.caption)
                            .foregroundStyle(Palette.textSecondary)
                            .monospacedDigit()
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .transcriptRowFrame()
                }
            }
        }
        .accessibilityLabel(label)
        .modifier(ExpandableRow(isHovered: isHovered && !showsSeparator))
        .onHover { if !showsSeparator { isHovered = $0 } }
        // Outside the hover treatment, exactly as `TranscriptRowView` puts it outside a row's
        // own: the highlight belongs to the line, not to the gutter the rule is drawn in.
        .padding(.leading, isNested ? TranscriptLayout.nestIndent : 0)
        .overlay(alignment: .leading) {
            if isNested {
                Rectangle()
                    .fill(Palette.border)
                    .frame(width: Metrics.hairline)
                    .padding(.leading, TranscriptLayout.inset)
            }
        }
    }

    private var separator: some View {
        Rectangle()
            .fill(Palette.border)
            .frame(maxWidth: .infinity)
            .frame(height: Metrics.hairline)
            .accessibilityHidden(true)
    }
}
