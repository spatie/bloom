import Foundation

/// The order the user has dragged the strip into, laid over the order it would otherwise have.
///
/// `TabSet` says the strip is conversations and then tools, and it says why: they are two kinds of
/// thing kept in two stores with two lifetimes. That rule stays, as the FALLBACK. What this adds is
/// one list of what the user themselves arranged, and a workspace with no such list reads exactly
/// as it did before this existed.
///
/// # What is lost if the list goes, and why that was accepted
///
/// It lives in user defaults, with the tool tab list, because it is about tool tabs as much as
/// about conversations and because it is the same sort of state: worth restoring, not worth a table
/// or a migration. A conversation is a SQLite row that outlives everything; a terminal or a page is
/// a line in defaults that is better lost than migrated.
///
/// So the two halves of an interleaved strip do not have the same lifetime, and that asymmetry has
/// a consequence worth writing down rather than leaving for whoever finds this key missing one day.
/// **If the defaults are lost, the interleaving goes with them.** The workspace comes back with its
/// conversations first and its tools after them, which is where they were before anybody dragged
/// anything.
///
/// It is milder than it sounds, and deliberately so. Every drag writes the conversations' relative
/// order back to `sessions.sort_order` and the tools' relative order back to their own list as
/// well, so what a lost defaults file costs is only the INTERLEAVING: the conversations keep their
/// order among themselves and the tools keep theirs. And it is recoverable by one drag.
///
/// The owner was told this before it was built and asked for the feature anyway. The alternative
/// was giving both kinds one durable order, which means either putting tool tabs into SQLite,
/// against the decision that they are better lost than migrated, or writing a number into two
/// stores with two lifetimes and having a restored conversation carry a number that means nothing.
public enum StripOrder {
    /// The strip, left to right, with the user's own order laid over the two runs.
    ///
    /// Anything the stored list has never heard of goes after everything it has, in the order
    /// `TabSet` would have put it in. That is what makes a new conversation or a new terminal
    /// appear at the END of the strip rather than at the end of its own kind, which is where
    /// somebody who has arranged their tabs by hand expects a new one to arrive.
    ///
    /// - Parameter stored: what the user arranged, which may name things that have since gone and
    ///   things a tab has since absorbed. Both are simply not in the answer.
    public static func entries(
        sessions: [SessionID],
        tools: [String],
        claimed: Set<PaneContent> = [],
        stored: [PaneContent] = []
    ) -> [PaneContent] {
        let fallback = TabSet.entries(sessions: sessions, tools: tools, claimed: claimed)
        guard !stored.isEmpty else { return fallback }

        let present = Set(fallback)
        var seen: Set<PaneContent> = []
        // A hand edited or half written list could name the same thing twice, which would draw one
        // tab in two places and give the strip two views with one identity.
        let known = stored.filter { present.contains($0) && seen.insert($0).inserted }
        let unknown = fallback.filter { !seen.contains($0) }
        return known + unknown
    }

    /// What to store now that the user has dragged the strip into `drawn`, or nil when that would
    /// change nothing.
    ///
    /// The list that gets written names everything the workspace has, not only what is in the
    /// strip. A thing absorbed into a pane of another tab is not drawn and cannot have been
    /// dragged, and it keeps the slot it already held, so closing the tab that holds it hands it
    /// back where the user left it rather than at the far end. `TabReorder` is the same rule the
    /// two runs already used for the same reason: a drawn order and a stored order are not the
    /// same list.
    ///
    /// It also prunes. A conversation that was closed or a tool tab that was, leaves an id behind
    /// that nothing can draw; reading already ignores those, and this is what stops the list
    /// growing for the life of the workspace.
    public static func rewritten(
        _ drawn: [PaneContent],
        sessions: [SessionID],
        tools: [String],
        stored: [PaneContent]
    ) -> [PaneContent]? {
        let everything = TabSet.all(sessions: sessions, tools: tools)
        let existing = Set(everything)

        var seen: Set<PaneContent> = []
        let kept = stored.filter { existing.contains($0) && seen.insert($0).inserted }
        let base = kept + everything.filter { !seen.contains($0) }

        let order = TabReorder.apply(drawn, to: base) ?? base
        return order == stored ? nil : order
    }
}
