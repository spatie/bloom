import SwiftUI

/// The chevron only appears under the pointer. A column of them down a dense transcript reads as
/// noise, and the row is clickable anywhere regardless.
struct TranscriptDisclosure: View {
    var isExpanded: Bool
    var isVisible: Bool

    var body: some View {
        // The same rung and scale as `TranscriptGlyph`: the two are the furniture at either end
        // of one row, and a chevron drawn a size below the leading glyph reads as a different
        // kind of control rather than as the other half of the same one.
        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
            .font(Typo.label)
            .imageScale(.small)
            .foregroundStyle(Palette.textTertiary)
            .frame(width: TranscriptLayout.disclosureWidth)
            .opacity(isVisible || isExpanded ? 1 : 0)
            .accessibilityHidden(true)
    }
}
