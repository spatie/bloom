import SwiftUI
import BloomCore

/// Hover and the rule down the left of a row that went wrong, shared by every row that opens.
///
/// A refused call gets the same rule in the caution colour rather than the alarm one. Nothing
/// failed: the call was declined, and a column of red down a transcript full of denials reads as a
/// broken agent when what happened is a setting.
///
/// The hover fill comes from `rowBackground` rather than a fill of its own, so a transcript row
/// highlights exactly the way a sidebar row and a file row do, and follows the window's active
/// state with them.
struct ExpandableRow: ViewModifier {
    var isHovered: Bool
    var isError: Bool = false
    /// Set when the call never ran. Takes precedence over `isError`, which a refusal also sets.
    var refusal: ToolRefusal? = nil

    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .rowBackground(isSelected: false, isHovered: isHovered)
            .overlay(alignment: .leading) {
                if isError {
                    Rectangle()
                        .fill(refusal == nil ? Palette.negative : Palette.warning)
                        .frame(width: TranscriptLayout.rule)
                }
            }
    }
}
