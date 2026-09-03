import Foundation

/// Which question Home's list is ordered by: when the work happened, or what the record costs.
///
/// **A size order and Home's date headings cannot both be true, so one of them has to go.** Home
/// is ordered by recency and bucketed into Today, Yesterday, Last week; ordering by bytes puts a
/// workspace from March above one from yesterday, and every heading over them is then a lie.
/// Sorting inside each bucket instead keeps the headings honest and answers nothing: the largest
/// record on the machine ends up halfway down the list under "Earlier this month", which is the
/// one place somebody looking for it will not look.
///
/// So `largest` collapses the date groups into one. That is not a new idea here: searching does
/// exactly the same to them, for exactly the same reason, and the note on `HomeList.build` says
/// so. The list is answering a different question, and the headings were the answer to the old
/// one.
///
/// **It is offered on the Archived chip and nowhere else.** A size here is what the database
/// still holds about work that is over. A live workspace's transcript is still being written and
/// its worktree is on disk, so a column of bytes beside it would be measuring the wrong thing and
/// an order over it would move rows for reasons nobody chose.
public enum HomeOrder: String, Hashable, Sendable, CaseIterable, Codable {
    /// Most recent first, under date headings. What Home has always done.
    case recent
    /// The largest record first, in one flat list.
    case largest

    public var label: String {
        switch self {
        case .recent: "Recent"
        case .largest: "Largest"
        }
    }

    /// The heading over a list this order has flattened, or nil when the date headings stand.
    ///
    /// **It is not a restatement of the control that produced it**, which is the objection worth
    /// answering, because that control says what the list will be sorted by and this is the only
    /// thing in the list itself saying the dates have stopped being what the order means. A search
    /// puts "Workspaces" over its results with the query in plain sight in the field above, for
    /// the same reason.
    public var heading: String? {
        self == .largest ? "Largest first" : nil
    }

    /// Whether this order can be asked for at all in the state the strip is in.
    ///
    /// Nothing settles back to `recent` when the answer is no, which is the opposite of what
    /// `HomeScope.settle` does to a chip and is deliberate. `HomeList.build` refuses to apply an
    /// order that does not apply, so there is no state where the list is silently sorted by
    /// something with no control on screen; leaving the value alone means the Archived chip is
    /// still on Largest when you come back to it, rather than quietly reset by a visit to All.
    public static func applies(scope: HomeScope, searching: Bool) -> Bool {
        !searching && scope.showsFootprints
    }
}
