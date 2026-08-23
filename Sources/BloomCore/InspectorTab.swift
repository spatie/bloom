import Foundation

/// Which pane the top of the inspector is showing, and which of them are offered at all.
///
/// The enum lives here rather than beside the strip that draws it because whether a tab exists is
/// a decision, and a decision taken inside a view is a decision nothing can test. The strip asks
/// `available(for:)` for its segments and hands whatever the reader picked back through
/// `resolve(_:available:)`.
public enum InspectorTab: String, Hashable, CaseIterable, Sendable {
    case allFiles = "All files"
    case changes = "Changes"
    case checks = "Checks"

    /// The pane a selection falls back to when the tab it names is not on offer.
    ///
    /// Changes rather than All files: it is the model's own starting tab, it is the one the strip
    /// counts in its title, and it is the pane a reader who was watching CI is most likely to want
    /// next. It is also the one tab that is always available, which is what makes it safe to be
    /// the answer of last resort.
    public static let fallback: InspectorTab = .changes

    /// The tabs worth drawing for a workspace, in the order the strip draws them.
    ///
    /// Checks is the only conditional one, and it is deliberately **last**. A segmented control
    /// sizes each segment to its own label and lays them out from the leading edge, so a tab
    /// appended at the end arrives without moving the two before it: a pull request landing
    /// mid-session cannot shift a segment out from under a click already on its way to it, and
    /// neither can one going away.
    public static func available(for pullRequest: PullRequest?) -> [InspectorTab] {
        allCases.filter { $0 != .checks || hasChecks(pullRequest) }
    }

    /// Whether GitHub has reported a check run worth a tab of its own.
    ///
    /// The gate is the runs, not the pull request, and the difference is a real state rather than
    /// a pedantic one: a repository with no workflows at all has an open pull request and nothing
    /// whatever to put in this pane, and a tab that can only say "No checks" is a tab that can
    /// only disappoint. `GitHub.rollup` answers `.none` exactly when the rollup was empty, so this
    /// reads as "GitHub reported at least one run".
    ///
    /// It happens to be true today that the runs can only arrive with a pull request, because
    /// every check Bloom knows about comes out of the `statusCheckRollup` of a single
    /// `gh pr view`. That is why the pull request is what gets passed in. It is not the reason for
    /// the gate: a branch pushed with no pull request can still have check runs, because a
    /// workflow may trigger on `push`, and the day Bloom asks GitHub for those the answer this
    /// function wants is still "is there a run", not "is there a pull request".
    public static func hasChecks(_ pullRequest: PullRequest?) -> Bool {
        guard let pullRequest else { return false }
        return pullRequest.checks != .none
    }

    /// The tab actually on screen, given what the reader last chose and what is on offer.
    ///
    /// The choice is kept rather than overwritten, which is the whole reason this is a function of
    /// two arguments instead of a stored property somebody clamps. A pull request is re-read every
    /// few seconds and a single failed `gh` call answers nil, so a reader sitting on Checks would
    /// otherwise be moved to Changes by a network hiccup and left there once the answer came back.
    /// Resolving on the way out instead means the pane falls back for exactly as long as the tab
    /// is gone, and the reader is returned to Checks the moment it exists again.
    public static func resolve(_ selected: InspectorTab, available: [InspectorTab]) -> InspectorTab {
        if available.contains(selected) { return selected }
        return available.contains(fallback) ? fallback : (available.first ?? fallback)
    }
}
