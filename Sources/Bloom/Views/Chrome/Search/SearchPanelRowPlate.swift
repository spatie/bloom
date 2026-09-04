import SwiftUI

/// The plate a selected or hovered row in the panel is drawn on: how far off the card's edge it
/// stops, how much air is inside it, and how much is between one and the next.
///
/// # The inset
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
/// # The air
///
/// The rows then read as a dense block, which was the next report: "add more room between items,
/// feels cramped now". The three numbers below are taken from the nearest thing this app already
/// draws, which is `AgentQuestionCard`'s list of option plates: six points inside the plate, two
/// between one plate and the next, and two between a row's two lines. The gap and the padding are
/// deliberately different numbers, because they are different measurements: the padding is what
/// keeps a row's own text off its fill, and the gap is what stops two fills reading as one band.
///
/// The corner is `Metrics.corner`, which is what `RowBackground` already rounds to and what
/// `QuestionOptionStyle` draws those same option plates at.
enum SearchPanelRowMetrics {
    /// How far the plate stops short of the card's edge.
    static let plateInset: CGFloat = Metrics.spacing

    /// What is left inside the row for its own horizontal padding, so the content stays where it
    /// was when the plate moved in.
    static let contentInset: CGFloat = Metrics.inset - plateInset

    /// The air above and below a row's content, inside its plate.
    static let air: CGFloat = Metrics.spacing

    /// The gap between one plate and the next.
    static let gap: CGFloat = Metrics.spacingTight

    /// Between a row's title and the quiet line under it.
    static let lineGap: CGFloat = Metrics.spacingTight
}

extension View {
    /// A panel row's own padding: the card's inset less the plate's, and the air inside the plate.
    func searchPanelRowPadding() -> some View {
        padding(.horizontal, SearchPanelRowMetrics.contentInset)
            .padding(.vertical, SearchPanelRowMetrics.air)
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
