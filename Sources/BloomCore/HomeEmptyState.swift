import Foundation

/// Which of five things Home says when its list has nothing in it, and what each of them says.
///
/// One generic "nothing to show" would be wrong in every case. The fixes are to add a project, to
/// start a workspace, to clear the search, to widen the project filter and to stop hiding
/// archived, and a placeholder naming none of them leaves the reader guessing which of the five
/// controls above it did this. So the sentence has to name the state, which means something has
/// to decide the state.
///
/// That decision was a five-branch `if` chain inside `HomeView`'s `emptyState`, mixed in with the
/// `ContentUnavailableView`s it produced, where nothing could ask it anything: not which state a
/// given machine is in, not whether the five are reachable, and not whether two of them overlap.
/// The order matters and is not obvious. A machine with no projects also has no workspaces and
/// also has an empty list, so all three of the first branches are true at once and only the first
/// is right.
///
/// What stays in the view is the drawing: the marks, the buttons, the tints, and the argument
/// about why these are the one part of Home still centred.
public enum HomeEmptyState: Sendable, Equatable {
    /// No project has been added to Bloom at all.
    case noProjects
    /// Projects, but nothing has ever been started in any of them.
    case noWorkspaces
    /// There is work, and the search matches none of it.
    case noMatch(query: String)
    /// There is work, and the project filter is hiding all of it.
    case noneInChosenProjects(phrase: String)
    /// There is work, all of it is archived, and archived is being hidden.
    case allArchived(count: Int)

    /// The state this machine is in, or nothing when the list has rows in it.
    ///
    /// **The order is the whole of it.** Emptiest first: a machine with no projects satisfies
    /// every test below it, so asking them in any other order answers a later question about an
    /// earlier machine. The search is asked before the project filter because a search is typed
    /// and a filter is left set, so the thing the reader did last is the thing to undo first.
    ///
    /// - Parameter projectPhrase: what to call the chosen projects, which needs their names and
    ///   is therefore the caller's to build.
    public static func resolve(
        hasProjects: Bool,
        hasAnyWorkspace: Bool,
        isListEmpty: Bool,
        query: String,
        hasProjectFilter: Bool,
        projectPhrase: String,
        archivedCount: Int
    ) -> HomeEmptyState? {
        guard hasProjects else { return .noProjects }
        guard hasAnyWorkspace else { return .noWorkspaces }
        guard isListEmpty else { return nil }

        let needle = query.trimmingCharacters(in: .whitespaces)
        if !needle.isEmpty { return .noMatch(query: needle) }
        if hasProjectFilter { return .noneInChosenProjects(phrase: projectPhrase) }
        return .allArchived(count: archivedCount)
    }

    public var title: String {
        switch self {
        case .noProjects: "Nothing running yet"
        case .noWorkspaces: "No workspaces yet"
        case .noMatch: "No workspace matches"
        case let .noneInChosenProjects(phrase): "Nothing in \(phrase)"
        case .allArchived: "Everything here is archived"
        }
    }

    public var symbol: String {
        switch self {
        case .noProjects, .noWorkspaces: "square.stack.3d.up"
        case .noMatch: "magnifyingglass"
        case .noneInChosenProjects: "folder"
        case .allArchived: "archivebox"
        }
    }

    /// One sentence each, and it says what the state is rather than what the product does.
    ///
    /// It was two sentences, and the second was always a description of the product, which is
    /// what an empty pane on a Mac does not do.
    public var message: String {
        switch self {
        case .noProjects:
            // Deliberately NOT what the sidebar's empty panel says, which is what this was. On
            // first run both are on screen at once, one in the sidebar and one in the middle of
            // the window, and they were the same sentence printed twice under two headings that
            // also matched, which reads as a rendering bug. The sidebar keeps the pitch, because
            // it is standing where the projects will be and it holds the button that adds one.
            // Home says what Home will show, in the future tense.
            return "Everything running on this Mac will be listed here, newest first."
        case .noWorkspaces:
            return "A workspace gets a branch, a worktree and an agent of its own."
        case let .noMatch(query):
            // Typographic quotes. Everything else in the window is careful about this, and a
            // straight pair in the one sentence that quotes the user reads as a string literal
            // that escaped.
            return "Nothing here is called, branched or filed under \u{201C}\(query)\u{201D}."
        case .noneInChosenProjects:
            return "The other projects still have work in them."
        case let .allArchived(count):
            return "All \(ArchiveDeletion.count(count, "workspace")) on this Mac have been "
                + "archived, and archived ones are being hidden."
        }
    }

    /// What the button under it says. Every one of these is a real way out of the state above it,
    /// which is the reason there are five states rather than one.
    public var actionTitle: String {
        switch self {
        case .noProjects: "Choose a folder"
        case .noWorkspaces: "New workspace"
        case .noMatch: "Clear the search"
        case .noneInChosenProjects: "Show all projects"
        case .allArchived: "Show archived"
        }
    }
}
