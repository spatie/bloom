import Foundation

/// Whether Home's list may take the keyboard for itself.
///
/// **The bug this is written down from.** Home's list aims first responder at itself from a
/// `.task`, because Full Keyboard Access is off by default on macOS and without it the only way
/// into the table is to click a row, which opens it. A `.task` fires when the view it is attached
/// to is CREATED, and the list is created far more often than the user arrives at Home: the pane
/// draws either `HomeEmptyState` or the list, never both, so every crossing of
/// `HomeListing.isEmpty` destroys the table and builds a new one.
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
/// filter is not an arrival: the view that owns Home is thrown away and rebuilt when the selection
/// leaves and comes back, which is exactly when the offer should be made again.
public enum HomeListKeyboard {
    /// - Parameters:
    ///   - searchFieldHasKeyboard: whether the window's search field is first responder.
    ///   - hasClaimed: whether the list has already been handed the keyboard on this visit.
    public static func claims(searchFieldHasKeyboard: Bool, hasClaimed: Bool) -> Bool {
        !searchFieldHasKeyboard && !hasClaimed
    }
}
