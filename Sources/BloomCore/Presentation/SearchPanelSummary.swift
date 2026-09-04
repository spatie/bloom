import Foundation

/// The one line at the right of the panel's footer: how much there is.
///
/// # The two numbers were not the same kind of thing
///
/// The card showed "Transcripts 3749" on a chip and "30 results" in the footer, and the owner read
/// that as a contradiction. It was worth finding out which of them was wrong before changing
/// either, and the answer is neither: **they were counting different things and neither said so.**
///
/// A transcript row is one workspace, folded by `TranscriptSearch.group`, and it carries every
/// match in that workspace in `total`. So the chip was summing MATCHES, 3749 of them, and the
/// footer was counting ROWS, 30 of them, and the 3719 in between were not withheld from anybody:
/// they were on screen, folded into twenty-seven rows that each say "26 matches" on their own
/// second line. "30 of 3749" would have been a tidier looking sentence and a new untruth.
///
/// So the footer answers the lit chip in the chip's own unit. Nothing on the card can disagree
/// with anything else on it, because the two are now the same number said twice, and the word
/// beside it says what it counts.
///
/// # Where "N of M" is honest, and it is not here
///
/// There is one place in this panel where a total really is being withheld, and it had no number
/// at all: the resting list. `SearchPanelResting` caps at five waiting and five recent, so a
/// machine with forty-three live workspaces drew ten rows and said "10 results", with nothing
/// saying the other thirty-three existed. That is the shape the footer was reached for, applied
/// where it is true.
public enum SearchPanelSummary {
    /// What a search says, under the chip it is being read through.
    ///
    /// `all` and `archived` keep the vague word on purpose. `HomeScopeCounts` builds both of them
    /// by adding workspace rows to transcript matches, which is Home's definition and shared with
    /// it, so "results" is the only honest noun for a number made of two kinds of thing. The two
    /// chips that count one kind get that kind named.
    public static func searching(scope: HomeScope, counts: HomeScopeCounts) -> String? {
        let count = counts.count(of: scope, searching: true)
        guard count > 0 else { return nil }
        switch scope {
        case .workspaces:
            return count == 1 ? "1 workspace" : "\(count) workspaces"
        case .transcripts:
            return count == 1 ? "1 match" : "\(count) matches"
        default:
            return rows(count)
        }
    }

    /// What the resting list says: how many workspaces it is showing, and how many there are.
    ///
    /// The total is named only when it is bigger. "10 of 10 workspaces" is a worse sentence than
    /// "10 workspaces" and says nothing the first half did not.
    public static func resting(shown: Int, of total: Int) -> String? {
        guard shown > 0 else { return nil }
        guard total > shown else {
            return shown == 1 ? "1 workspace" : "\(shown) workspaces"
        }
        return "\(shown) of \(total) workspaces"
    }

    /// A plain list of rows, which is the menu bar and a workspace's own actions. Nothing is folded
    /// and nothing is capped in either, so a row is a result and the count is the count.
    public static func rows(_ count: Int) -> String? {
        guard count > 0 else { return nil }
        return count == 1 ? "1 result" : "\(count) results"
    }
}
