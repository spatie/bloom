import Foundation

/// Whether Home's list may take the keyboard for itself.
///
/// **The bug this is written down from.** Home's list aims first responder at itself from a
/// `.task`, because Full Keyboard Access is off by default on macOS and without it the only way
/// into the table is to click a row, which opens it. A `.task` fires when the view it is attached
/// to is CREATED, and the list is created far more often than the user arrives at Home: the pane
/// drew either `HomeEmptyState` or the list, never both, so every crossing of
/// `HomeListing.isEmpty` destroyed the table and built a new one. (It lays the empty state over
/// the list now, for the reason on `HomePresence`, but the rule below does not depend on that.)
///
/// Typing into the window's search field crosses that line twice per search, and it does so
/// because the two halves of a search do not land together. The names are matched in memory and
/// are on screen on the keystroke; the transcripts are an FTS5 query behind
/// `AppModel.transcriptSearchDebounce`, and they are cleared outright below
/// `TranscriptSearch.minimumQueryLength`. So the second character of a query that no workspace is
/// named after empties the pane, and the results arriving 120ms later fill it again. That second
/// event built a fresh table, the fresh table's `.task` woke up 50ms later, and the keyboard was
/// pulled out of the search field mid word: typing "df" put the caret in a list of sixteen
/// matches and there was no way to type a third letter.
///
/// So the claim is refused twice over. It is refused while the field has the keyboard, because a
/// list is never the right place for the next character somebody types. And it is refused once it
/// has been made, because arriving at Home is what it is for and a table being rebuilt under a
/// filter is not an arrival. A visit starts when the selection comes back to Home, which is
/// exactly when the offer should be made again.
///
/// **And it is refused while Home is not on screen.** Home stays mounted behind the other panes
/// once it has been visited, for the reason `HomePresence` gives, so its list exists while the
/// reader is in a workspace. A hidden list that took the keyboard would answer Delete by archiving
/// a row nobody can see.
public enum HomeListKeyboard {
    /// - Parameters:
    ///   - isPresented: whether Home is the pane the window is showing. See `HomePresence`.
    ///   - searchFieldHasKeyboard: whether the window's search field is first responder.
    ///   - hasClaimed: whether the list has already been handed the keyboard on this visit.
    public static func claims(isPresented: Bool, searchFieldHasKeyboard: Bool, hasClaimed: Bool) -> Bool {
        isPresented && !searchFieldHasKeyboard && !hasClaimed
    }
}
