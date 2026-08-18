import SwiftUI

/// Hover and the error rule, shared by every row that opens.
///
/// The hover fill comes from `rowBackground` rather than a fill of its own, so a transcript row
/// highlights exactly the way a sidebar row and a file row do, and follows the window's active
/// state with them.
struct ExpandableRow: ViewModifier {
    var isHovered: Bool
    var isError: Bool = false

    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .rowBackground(isSelected: false, isHovered: isHovered)
            .overlay(alignment: .leading) {
                if isError {
                    Rectangle()
                        .fill(Palette.negative)
                        .frame(width: TranscriptLayout.rule)
                }
            }
    }
}
