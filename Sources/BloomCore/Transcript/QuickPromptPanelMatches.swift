import Foundation

/// One row of the quick prompt panel: one of the owner's prompts, or one the repository offers.
public enum QuickPromptPanelRow: Identifiable, Sendable, Hashable {
    case personal(QuickPrompt)
    case project(ProjectQuickPrompt)

    /// Prefixed by where the row came from, so an owner's prompt and a project's cannot answer to
    /// the same id however they are named.
    public var id: String {
        switch self {
        case .personal(let prompt): "personal." + prompt.id.rawValue
        case .project(let prompt): "project." + prompt.id
        }
    }

    public var name: String {
        switch self {
        case .personal(let prompt): prompt.resolvedName
        case .project(let prompt): prompt.name
        }
    }
}

/// What the quick prompt panel draws once a project has prompts of its own: the owner's first,
/// the repository's under them, and one search over both.
///
/// **Two sections rather than one ranked list, and the owner's always first.** A prompt the owner
/// wrote is one they chose to keep, and a project's is one they were handed; interleaving them by
/// score would let a teammate's prompt with a lucky name push the owner's own off the first row,
/// which is where Return lands. Within a section the rule is `QuickPromptMatches`'s, unchanged, so
/// the two halves rank alike.
///
/// The arrow keys walk the two sections as one list, top to bottom, which is what `rows` is.
public struct QuickPromptPanelMatches: Sendable, Hashable {
    public let query: String
    public let personal: [QuickPrompt]
    public let project: [ProjectQuickPrompt]

    public init(query: String = "", personal: [QuickPrompt] = [], project: [ProjectQuickPrompt] = []) {
        self.query = query
        self.personal = personal
        self.project = project
    }

    /// Every row in the order the panel draws them and the arrows walk them.
    public var rows: [QuickPromptPanelRow] {
        personal.map(QuickPromptPanelRow.personal) + project.map(QuickPromptPanelRow.project)
    }

    public var isEmpty: Bool { personal.isEmpty && project.isEmpty }

    /// Both lists against what is in the search field. `limit` is per section, so a long personal
    /// library cannot hide every project prompt below it.
    public static func ranking(
        personal: [QuickPrompt], project: [ProjectQuickPrompt], query: String, limit: Int = 100
    ) -> QuickPromptPanelMatches {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return QuickPromptPanelMatches(
            query: trimmed,
            personal: QuickPromptMatches.ranked(
                personal, query: trimmed, limit: limit, name: \.resolvedName, text: \.text
            ),
            project: QuickPromptMatches.ranked(
                project, query: trimmed, limit: limit, name: \.name, text: \.text
            )
        )
    }

    /// Where the highlight lands after a step. By id, so a row whose prompt was edited in the
    /// meantime is still the row that was highlighted.
    public func stepped(from current: QuickPromptPanelRow?, by step: Int) -> QuickPromptPanelRow? {
        let rows = rows
        let held = current.flatMap { current in rows.first { $0.id == current.id } }
        return MenuRows.stepped(from: held, by: step, in: rows)
    }

    /// What stays highlighted when the list changes: the same row if it survived, otherwise the
    /// first there is. See `QuickPromptMatches.settled`.
    public func settled(after current: QuickPromptPanelRow?) -> QuickPromptPanelRow? {
        let rows = rows
        guard let current, let held = rows.first(where: { $0.id == current.id }) else {
            return rows.first
        }
        return held
    }
}
