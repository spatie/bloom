import SwiftUI

/// Hover, shared by every row that opens.
///
/// It used to draw a coloured rule down the left of a row that failed or was refused, and that
/// rule is gone. The state was already on the row twice, in the word at the trailing edge and in
/// the tint of the leading glyph, and the bar was the loudest of the three: a column of red and
/// amber down a transcript pulled the eye away from the answer the agent had written underneath
/// it. What is left says the same thing in the two places that were already saying it.
///
/// The hover fill comes from `rowBackground` rather than a fill of its own, so a transcript row
/// highlights exactly the way a sidebar row and a file row do, and follows the window's active
/// state with them.
struct ExpandableRow: ViewModifier {
    var isHovered: Bool

    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .rowBackground(isSelected: false, isHovered: isHovered)
    }
}
