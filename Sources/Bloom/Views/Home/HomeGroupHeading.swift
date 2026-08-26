import SwiftUI

/// A heading in Home's list.
///
/// **It is the title and nothing else, and both things it used to carry were removed on sight.**
/// It had the group's count on a capsule plate beside it and a hairline rule running out to the
/// trailing edge. The count answered a question nobody was asking twice, since the chips above the
/// list already say how many are live, waiting and archived, and "1" next to Today is noise
/// dressed as information. The rule made every date look like the start of a document.
///
/// It is a plain row in the list rather than a `Section` header, which is the other half of the
/// same complaint: as a header it pinned to the top of the scroll view and slid the rows under
/// itself, and a flat list of workspaces is not an index that needs its place kept.
struct HomeGroupHeading: View {
    var title: String
    /// A secondary heading, for the archived tail under a live list. It is the same heading a step
    /// down, because the block under it is context rather than the answer: a tail set as loud as
    /// the day above it would read as the list starting again.
    var isSecondary = false

    var body: some View {
        Text(title)
            .font(Typo.title)
            .foregroundStyle(isSecondary ? Palette.textSecondary : Palette.textPrimary)
            .padding(.top, Metrics.inset)
            .padding(.bottom, Metrics.spacingSmall)
            .accessibilityAddTraits(.isHeader)
    }
}
