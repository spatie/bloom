import Foundation

/// A run of rows under one heading.
///
/// **Headings stay in the scroll rather than sticking.** A sticky header inside a list three
/// hundred points tall eats one of the four rows you can see, and the panel's whole argument is
/// that the answer is on screen before you have finished typing.
public struct SearchPanelSection: Equatable, Sendable, Identifiable {
    public var id: String
    /// Nil for a section that needs no heading, which is the action list: the pill in the field
    /// already names what is being acted on.
    public var title: String?
    public var rows: [SearchPanelRow]

    public init(id: String, title: String?, rows: [SearchPanelRow]) {
        self.id = id
        self.title = title
        self.rows = rows
    }
}

/// Everything the panel is showing, in one value.
///
/// `rows` is the same rows as `sections` flattened, and it is held rather than derived at every
/// keystroke because it is what the arrow keys walk: the highlight is an index into this, so a
/// listing that recomputed it and a key handler that recomputed it differently would be two lists
/// disagreeing about which row Return opens. See `SearchPanelKeys`.
public struct SearchPanelListing: Equatable, Sendable {
    public var sections: [SearchPanelSection]
    /// Drawn order, headings taken out. The arrows walk this, so they skip the headings for free.
    public var rows: [SearchPanelRow]
    /// What each chip says, worked out in the same pass. Home's own counts, so the two surfaces
    /// cannot disagree about how much archived work there is.
    public var counts: HomeScopeCounts
    /// Whether there is a query behind this listing, which is what decides the chips on offer.
    public var isSearching: Bool
    /// The line at the right of the footer: how much there is.
    ///
    /// Stored rather than derived from `rows.count`, for the reason `nothing` below is: the row
    /// count is not the answer in either of the two lists that fold or cap. Only the builder knows
    /// which chip is lit, how many matches those rows stand for, and how many workspaces were left
    /// off the resting list. See `SearchPanelSummary`, which holds the words and the argument.
    ///
    /// The default is the plain row count, which is right for the menu bar and for a workspace's
    /// own actions: neither folds anything and neither caps.
    public var summary: String?
    /// What the card says instead of rows, and nil whenever there are any.
    ///
    /// It is here rather than derived in the view from `rows.isEmpty`, because an empty list is
    /// not one fact: a fresh install has nothing yet, a query can miss, and the menu bar can be
    /// asked for a command it does not have. Only the builder knows which of those it is.
    public var nothing: SearchPanelNothing?

    public init(
        sections: [SearchPanelSection],
        counts: HomeScopeCounts = HomeScopeCounts(),
        isSearching: Bool = false,
        summary: String? = nil,
        nothing: SearchPanelNothing? = nil
    ) {
        self.sections = sections
        self.rows = sections.flatMap(\.rows)
        self.counts = counts
        self.isSearching = isSearching
        self.summary = summary ?? SearchPanelSummary.rows(self.rows.count)
        self.nothing = nothing
    }

    public static let empty = SearchPanelListing(sections: [])

    public var isEmpty: Bool { rows.isEmpty }

    /// The row at an index the highlight is holding, or nothing when the list has moved under it.
    public func row(at index: Int?) -> SearchPanelRow? {
        guard let index, rows.indices.contains(index) else { return nil }
        return rows[index]
    }

}
