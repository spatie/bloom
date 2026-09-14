import Foundation

/// What the quick prompt panel says in place of its rows, when it has none to draw.
///
/// Three different nothings, and which one is decided here rather than in the panel because a
/// project's prompts added a way to get it wrong. The panel used to show "Nothing here yet." when
/// the owner's library was empty, and an owner with no prompts of their own in a project that
/// offers five would have been told there was nothing above a list of five.
public enum QuickPromptPanelNotice: Equatable, Sendable {
    /// A search matched nothing in either section.
    case noMatches(String)
    /// The owner's library has not been read yet, and there is nothing else to show meanwhile.
    case loading
    /// Nothing at all: no prompts of the owner's and none from the project. The one case worth a
    /// sentence about what a quick prompt is for.
    case nothingYet
}

extension QuickPromptPanelMatches {
    /// What to say instead of rows, or nil when there are rows to draw. Any row at all wins, from
    /// either section, so a project's prompts are never introduced by a sentence saying there are
    /// none.
    public func notice(isLoaded: Bool) -> QuickPromptPanelNotice? {
        guard isEmpty else { return nil }
        if !query.isEmpty { return .noMatches(query) }
        return isLoaded ? .nothingYet : .loading
    }

    /// Whether the project's rows are introduced by a heading. Only when there are some: a project
    /// with no prompts, or a search that matched none of them, draws the panel exactly as it was
    /// before projects could offer any. Drawn even when the owner's section is empty, because the
    /// heading is what says these rows are not the owner's to edit.
    public var showsProjectHeading: Bool { !project.isEmpty }
}
