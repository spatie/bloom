import Foundation

/// What happens to a name being typed on a row when the field stops being edited.
///
/// **The bug this is written from.** The three rows with an in-place rename (a workspace in the
/// sidebar, a project header, a workspace on Home) each wired Return and Escape and nothing else.
/// Click anywhere else in the window and the field stayed open on the row, holding uncommitted
/// text, indefinitely; and the sidebar cleared the field whenever the selection moved, so
/// selecting another workspace silently threw away what had been typed. Finder, Xcode and Mail all
/// commit an in-place rename when the field resigns first responder, and a Mac user reads an
/// abandoned edit as the app having eaten it.
///
/// **Why one rule rather than three.** The three rows had three copies of the same four lines, and
/// what they must agree on is not the typing but the endings: Escape is the only one that throws
/// the draft away, and everything else keeps it. A rule with the endings named is also the only way
/// to test it, since a decision taken inside a view is a decision nothing can hold still.
public enum InPlaceRename {
    /// How the field stopped being edited.
    public enum Ending: String, Sendable, CaseIterable {
        /// Return.
        case submitted
        /// The field lost first responder: a click elsewhere in the window, or the keyboard moving
        /// to another control.
        case focusLost
        /// Escape.
        case escaped
        /// The list closed the field from underneath, which is what moving the selection does.
        case dismissed
    }

    public enum Outcome: Equatable, Sendable {
        case commit(String)
        /// Nothing to write: the edit was cancelled, or the name came back the same or empty.
        case discard
    }

    /// - Parameters:
    ///   - draft: what is in the field, untrimmed.
    ///   - current: the name the thing already has.
    public static func outcome(_ ending: Ending, draft: String, current: String) -> Outcome {
        // Escape is the one ending that means "forget it", and it has to stay that way: it is the
        // only way out of a rename that does not write, and a Mac user who has typed the wrong
        // thing reaches for it before they reach for the old name.
        guard ending != .escaped else { return .discard }

        let name = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        // An empty field is not a request to have no name, and a name that came back unchanged is
        // not a rename: writing either would spend a database round trip and a sidebar reflow on
        // nothing.
        guard !name.isEmpty, name != current else { return .discard }
        return .commit(name)
    }
}
