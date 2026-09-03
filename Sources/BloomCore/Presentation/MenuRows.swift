import Foundation

/// Where the highlight lands when a floating list is walked with the arrow keys.
///
/// **It wraps at both ends, which is what an `NSMenu` does**, and it is the one place in the app
/// that rule is written down. Three panels had a private copy of these six lines by the time the
/// composer's permission picker needed a fourth: `QuickPromptMatches`, `WorkspaceSourceMatches`
/// and the tab strip inside the second of those, each carrying its own paragraph explaining the
/// wrapping to the next reader. A rule restated three times is a rule three views can disagree
/// about, and the flat lists that do NOT wrap have their own answer in `ListNavigation`, whose
/// head says why a pane's list is different from a menu.
public enum MenuRows {
    /// The row a step of `by` reaches, or nil when there is nothing to step through.
    ///
    /// With nothing highlighted yet it answers with the end the key came from, so the first press
    /// of Down after a panel opens does not swallow itself.
    public static func stepped<Row: Equatable>(
        from current: Row?, by step: Int, in rows: [Row]
    ) -> Row? {
        guard !rows.isEmpty else { return nil }
        guard let current, let index = rows.firstIndex(of: current) else {
            return step < 0 ? rows.last : rows.first
        }
        return rows[(index + step + rows.count) % rows.count]
    }
}
