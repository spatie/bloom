import Foundation

/// What the card says when it has no rows to draw.
///
/// # Why this replaced two rows
///
/// It used to be a sentence with two actions under it: "Start a workspace called qsdfqsdf" and
/// "Search Home for qsdfqsdf", argued from Raycast's fallback commands. The owner looked at them
/// and said no: "just say nothing found here, don't offer up those two actions". He is right, and
/// the footer said why better than the argument for them did. The two rows were rows, so the
/// count on the right read "2 results" under a sentence saying nothing matched, and the panel
/// contradicted itself in one glance. A search that found nothing should say so and stop.
///
/// # Three different nothings, because they are three different facts
///
/// Somebody on a fresh install has nothing yet; somebody whose query missed has a query that
/// missed; somebody in the menu bar has typed a command that does not exist. Saying "No results"
/// to all three would be the app declining to know which one it is in. The first is the only one
/// that says what to do next, and it says it in one sentence with no button: an empty install is
/// the one case where the reader genuinely does not know what the app wants from them.
///
/// **The query is in the message, verbatim.** Somebody who typed nine characters wants to see
/// which nine, and a message that repeats them is also how a typo announces itself.
public enum SearchPanelNothing: Equatable, Sendable {
    /// Resting, on a machine with no workspaces to list.
    case nothingYet
    /// A search of workspaces, transcripts and commands that matched nothing.
    case noMatch(String)
    /// The menu bar, searched for something that is not in it.
    case noCommand(String)

    public var title: String {
        switch self {
        case .nothingYet: "Nothing to show yet"
        case .noMatch: "No results"
        case .noCommand: "No such command"
        }
    }

    public var message: String {
        switch self {
        case .nothingYet:
            "Add a project and start a workspace, and what you are working on turns up here."
        case .noMatch(let query):
            "Nothing in Bloom matches \(quoted(query))."
        case .noCommand(let query):
            "No menu item matches \(quoted(query))."
        }
    }

    /// The sentence under the message while the transcript index is still being built.
    ///
    /// **Only while the backfill is actually running.** The index is built after launch, and until
    /// it finishes a "nothing matched" about work the user knows they did can be wrong. At any
    /// other time the same sentence would be an excuse rather than a fact, which is why it is
    /// keyed on the flag rather than printed always. It belongs to `noMatch` alone: an empty
    /// install has nothing to index, and the menu bar is not in the index at all.
    public func indexNotice(isIndexing: Bool) -> String? {
        guard isIndexing, case .noMatch = self else { return nil }
        return "The transcript index is still building, so older conversations are not searchable yet."
    }

    /// Typographic quotes, because the query is quoted prose rather than code.
    private func quoted(_ query: String) -> String {
        "\u{201C}\(query.trimmingCharacters(in: .whitespacesAndNewlines))\u{201D}"
    }
}
