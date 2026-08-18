import SwiftUI

/// The chevron only appears under the pointer. A column of them down a dense transcript reads as
/// noise, and the row is clickable anywhere regardless.
struct TranscriptDisclosure: View {
    var isExpanded: Bool
    var isVisible: Bool

    var body: some View {
        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
            .font(Typo.micro)
            .imageScale(.small)
            .foregroundStyle(Palette.textTertiary)
            .frame(width: TranscriptLayout.disclosureWidth)
            .opacity(isVisible || isExpanded ? 1 : 0)
            .accessibilityHidden(true)
    }
}
