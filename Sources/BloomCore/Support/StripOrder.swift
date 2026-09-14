import Foundation

/// One opening order for conversations and tools, with manual reordering preserved.
///
/// Both stores record arrivals in this list. Previously it was written only after a drag, so a
/// new conversation jumped ahead of tools until the user first rearranged the strip.
///
/// The mixed order lives in user defaults. If it is missing, existing tabs retain the legacy
/// conversations-then-tools order once; subsequent arrivals append. Each kind also keeps its own
/// relative order in its source store, so losing defaults loses only their interleaving.
public enum StripOrder {
    /// Record arrivals before the next tab opens, so alternating chats and tools keep their
    /// opening order without requiring a drag. Nil means that store has not loaded yet.
    public static func updated(
        sessions: [SessionID]? = nil, tools: [String]? = nil, stored: [PaneContent]
    ) -> [PaneContent] {
        let chats = sessions.map { Set($0) }
        let toolIDs = tools.map { Set($0) }
        var seen: Set<PaneContent> = []
        let kept = stored.filter { entry in
            let present = switch entry {
            case .chat(let id): chats?.contains(id) ?? true
            case .tool(let id): toolIDs?.contains(id) ?? true
            }
            return present && seen.insert(entry).inserted
        }
        let arrivals = TabSet.all(sessions: sessions ?? [], tools: tools ?? [])
            .filter { seen.insert($0).inserted }
        return kept + arrivals
    }

    /// The strip, left to right, with the saved order applied to the available content.
    ///
    /// Anything the stored list has never heard of goes after everything it has, in the order
    /// `TabSet` would have put it in. That is what makes a new conversation or a new terminal
    /// appear at the end of the strip rather than at the end of its own kind.
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
