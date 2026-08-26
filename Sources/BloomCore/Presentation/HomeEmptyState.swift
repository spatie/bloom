import Foundation

/// What Home says when its list has nothing in it, and what each of those says.
///
/// One generic "nothing to show" would be wrong in every case. The fixes are to add a project, to
/// start a workspace, to clear the search, to widen the project filter and to click a different
/// chip, and a placeholder naming none of them leaves the reader guessing which of the controls
/// above it did this. So the sentence has to name the state, which means something has to decide
/// the state.
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
    /// There is work, and the search matches none of it. The scope travels with it because a
    /// search narrowed to transcripts that found nothing did not fail to find a workspace.
    case noMatch(query: String, scope: HomeScope)
    /// There is work, and the project filter is hiding all of it.
    case noneInChosenProjects(phrase: String)
    /// There is work, and none of it is in the chosen scope: nothing is waiting on you, nothing
    /// is running, nothing has been archived.
    case emptyScope(HomeScope)

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
        scope: HomeScope,
        hasProjectFilter: Bool,
        projectPhrase: String
    ) -> HomeEmptyState? {
        guard hasProjects else { return .noProjects }
        guard hasAnyWorkspace else { return .noWorkspaces }
        guard isListEmpty else { return nil }

        let needle = query.trimmingCharacters(in: .whitespaces)
        if !needle.isEmpty { return .noMatch(query: needle, scope: scope) }
        if hasProjectFilter { return .noneInChosenProjects(phrase: projectPhrase) }
        return .emptyScope(scope)
    }

    public var title: String {
        switch self {
        case .noProjects: "Nothing running yet"
        case .noWorkspaces: "No workspaces yet"
        case let .noMatch(_, scope):
            switch scope {
            case .transcripts: "Nothing was said about it"
            case .archived: "Nothing archived matches"
            default: "No results"
            }
        case let .noneInChosenProjects(phrase): "Nothing in \(phrase)"
        case let .emptyScope(scope):
            switch scope {
            case .needsYou: "Nothing is waiting for you"
            case .running: "No agent is running"
            case .live: "Nothing is live"
            case .archived: "Nothing has been archived"
            default: "Nothing to show"
            }
        }
    }

    public var symbol: String {
        switch self {
        case .noProjects, .noWorkspaces: "square.stack.3d.up"
        case .noMatch: "magnifyingglass"
        case .noneInChosenProjects: "folder"
        case let .emptyScope(scope):
            switch scope {
            case .needsYou: "bell"
            case .running: "play.circle"
            case .archived: "archivebox"
            default: "square.stack.3d.up"
            }
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
        case let .noMatch(query, scope):
            // Typographic quotes. Everything else in the window is careful about this, and a
            // straight pair in the one sentence that quotes the user reads as a string literal
            // that escaped.
            let quoted = "\u{201C}\(query)\u{201D}"
            switch scope {
            case .transcripts:
                return "No agent on this Mac has said \(quoted)."
            case .archived:
                return "No archived workspace and no archived transcript matches \(quoted)."
            case .workspaces:
                return "Nothing here is called, branched or filed under \(quoted)."
            default:
                return "Nothing is called, branched or filed under \(quoted), and no agent said it."
            }
        case .noneInChosenProjects:
            return "The other projects still have work in them."
        case let .emptyScope(scope):
            switch scope {
            case .needsYou:
                return "No agent has asked a question, and every finished turn has been read."
            case .running:
                return "Nothing on this Mac is mid turn."
            case .live:
                return "Every workspace here has been archived."
            case .archived:
                return "Archiving a workspace removes its worktree and keeps everything it said."
            default:
                return "Nothing on this Mac matches what the strip is asking for."
            }
        }
    }

    /// What the button under it says. Every one of these is a real way out of the state above it,
    /// which is the reason there are five states rather than one.
    public var actionTitle: String {
        switch self {
        case .noProjects: "New project"
        case .noWorkspaces: "New workspace"
        case .noMatch: "Clear the search"
        case .noneInChosenProjects: "Show all projects"
        case .emptyScope: "Show everything"
        }
    }

    /// The second way out, where there are two, and nil everywhere else.
    ///
    /// Only the first state has one, and it is the state this exists for: somebody with no
    /// projects is either about to start one or about to point Bloom at a repository they already
    /// have, and those are two different acts with two different first steps. Every other state
    /// here is undoing a control that is still on screen, which has exactly one way back.
    ///
    /// The prominent half is deliberately the one that needs no folder, because the person who
    /// has nothing yet is the one this screen fails today.
    public var secondaryActionTitle: String? {
        switch self {
        case .noProjects: "Add a project folder"
        default: nil
        }
    }
}
