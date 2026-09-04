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
    /// Whether there is a query behind this listing, which is what decides the chips on offer and
    /// whether the fallback rows can appear at all.
    public var isSearching: Bool

    public init(
        sections: [SearchPanelSection],
        counts: HomeScopeCounts = HomeScopeCounts(),
        isSearching: Bool = false
    ) {
        self.sections = sections
        self.rows = sections.flatMap(\.rows)
        self.counts = counts
        self.isSearching = isSearching
    }

    public static let empty = SearchPanelListing(sections: [])

    public var isEmpty: Bool { rows.isEmpty }

    /// The row at an index the highlight is holding, or nothing when the list has moved under it.
    public func row(at index: Int?) -> SearchPanelRow? {
        guard let index, rows.indices.contains(index) else { return nil }
        return rows[index]
    }

    /// The count in the footer, on the right, where it does not compete with the keys.
    public var summary: String {
        let count = rows.count
        return count == 1 ? "1 result" : "\(count) results"
    }
}
