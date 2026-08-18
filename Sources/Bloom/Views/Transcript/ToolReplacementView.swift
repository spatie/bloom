import SwiftUI

/// An Edit reads as a two colour before and after, which is the closest a one-file view gets to a
/// diff without running one.
struct ToolReplacementView: View {
    var old: String?
    var new: String?

    var body: some View {
        VStack(alignment: .leading, spacing: TranscriptLayout.tight) {
            if let old, !old.isEmpty {
                DetailCodeBlock(text: old, tint: Palette.diffDeleteBackground)
            }
            if let new, !new.isEmpty {
                DetailCodeBlock(text: new, tint: Palette.diffAddBackground)
            }
        }
    }
}
