import SwiftUI

/// A heading in Home's list, with how many workspaces are under it.
///
/// The count is the half that makes the heading worth having. "Yesterday" alone is a divider;
/// "Yesterday 48" is a fact about how much happened, and it is the only place in the window that
/// says it, because the sidebar counts per project and never per day.
///
/// **It was set in caption ink at secondary weight, and it is the structure of the page.** Home is
/// one flat list, so the date headings are the only thing dividing it, and set that quietly they
/// read as labels on a list rather than as the shape of it. This is the title rung, in primary
/// ink, with the count on a quiet plate beside it and a rule running out to the trailing edge, so
/// the eye can find a day without reading a row.
struct HomeGroupHeading: View {
    var title: String
    var count: Int
    /// A secondary heading, for the archived tail under a live list. It is the same heading a step
    /// down, because the block under it is context rather than the answer: a tail set as loud as
    /// the day above it would read as the list starting again.
    var isSecondary = false
    /// The count's other half, when the block is a sample rather than the whole of something:
    /// "6 of 17" under a live list, where the tail is capped.
    var of: Int?

    var body: some View {
        HStack(spacing: Metrics.spacingWide) {
            Text(title)
                .font(Typo.title)
                .foregroundStyle(isSecondary ? Palette.textSecondary : Palette.textPrimary)

            Text(countText)
                .font(Typo.micro)
                .monospacedDigit()
                .foregroundStyle(Palette.textTertiary)
                .padding(.horizontal, Metrics.chipInsetH)
                .padding(.vertical, Metrics.chipInsetV)
                .background(Palette.hover, in: Capsule())

            // Out to the trailing edge, which is what turns a label into a division. Under
            // `List`'s own leading inset it starts at the heading and ends at the pane's edge, so
            // the day above and the day below are two blocks rather than two lines of text.
            Rectangle()
                .fill(Palette.border)
                .frame(height: Metrics.hairline)
        }
        .padding(.top, Metrics.inset)
        .padding(.bottom, Metrics.spacingSmall)
        // One phrase, so a VoiceOver user hears "Yesterday, 48 workspaces" rather than a heading
        // and then a loose number.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(.isHeader)
    }

    private var countText: String {
        guard let of else { return count.formatted() }
        return "\(count.formatted()) of \(of.formatted())"
    }

    private var accessibilityLabel: String {
        if let of { return "\(title), \(count) of \(of) workspaces" }
        return count == 1 ? "\(title), 1 workspace" : "\(title), \(count) workspaces"
    }
}
