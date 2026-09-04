import SwiftUI

/// The plate a selected or hovered row in the panel is drawn on, and how far off the card's edge
/// it stops.
///
/// **The fill used to run the full width of the card**, so a selected row's left and right edges
/// landed exactly on the panel's own border and the blue plate read as a band cutting across the
/// card rather than as a row inside it. The owner's words were "selection touches border, doesn't
/// seem good". Spotlight and Raycast both inset theirs, which is why their selection looks seated.
///
/// **The fill moves and the content does not.** Each row keeps ten points between its icon and the
/// card's edge, exactly as before: the plate's inset is taken off the row's own horizontal padding
/// and given back outside the fill, so nothing in the row shifts when it becomes selected. A
/// selection that nudges the icon column is worse than one that touches the border.
///
/// The corner and the inset are the app's rather than a third set of numbers. `Metrics.corner` is
/// what `RowBackground` already rounds to and what `QuestionOptionStyle` draws its option plates
/// at in the transcript, and `Metrics.spacing` is the inset. Six and six, so the plate's corner
/// and the air around it are the same number, which is what makes it read as a plate rather than
/// as a clipped band.
enum SearchPanelRowMetrics {
    /// How far the plate stops short of the card's edge.
    static let plateInset: CGFloat = Metrics.spacing

    /// What is left inside the row for its own padding, so the content stays where it was.
    static let contentInset: CGFloat = Metrics.inset - plateInset
}

extension View {
    /// A panel row's own horizontal padding, which is the card's inset less the plate's.
    func searchPanelRowPadding() -> some View {
        padding(.horizontal, SearchPanelRowMetrics.contentInset)
    }

    /// The plate, inset from the card's edges.
    ///
    /// Focused, because the panel's field really does hold the keyboard while the arrows walk this
    /// list, which is the one case AppKit paints in the accent.
    func searchPanelRowPlate(isSelected: Bool, isHovered: Bool) -> some View {
        rowBackground(isSelected: isSelected, isHovered: isHovered, isFocused: true)
            .padding(.horizontal, SearchPanelRowMetrics.plateInset)
    }
}
