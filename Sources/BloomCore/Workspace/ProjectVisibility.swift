import Foundation

/// Which projects the sidebar lists, and what "hidden" is allowed to mean.
///
/// ## What hiding is
///
/// A decluttering of the lists that are about browsing. A project with nothing running in it this
/// month is still a project the owner wants, and the sidebar is a column 260 points wide that has
/// to be scannable at a glance. Hiding takes a project's header and its workspace rows out of that
/// column, and out of what the search panel answers over, and does nothing else at all.
///
/// **It is emphatically not archiving, and not closing.** The workspaces of a hidden project are
/// untouched: their agents keep running, their turns keep landing, their notifications keep
/// arriving, and they keep appearing on Home, in the menu bar summary, in the Shortcuts entities
/// and in the `bloom://` links.
///
/// Search used to be in that list and is not any more, and the change is worth reading rather than
/// noticing. The owner asked for the panel to answer over live, visible work by default, so it
/// reads the same preference this file names, and a hidden project's workspaces are one switch
/// away there exactly as they are in the sidebar. Nothing about the paragraph above is weakened by
/// it: the point was that hiding must never be a way to LOSE work, and a list you can widen from a
/// switch you already own is not that. See `SearchPanelReach`. Anything that would make a running agent disappear
/// because a list was tidied would be a way to lose work, and this is a view preference. Two
/// consequences follow and are deliberate: hiding the project of the workspace on screen does not
/// change the selection or close anything, and the sidebar can be showing a project the pane is
/// not listing. The filter already does exactly that, since `.unread` hides a read workspace the
/// user is sitting in, so the pane has always been a view of the work rather than the whole of it.
///
/// ## Where the order comes from
///
/// Nowhere new. Hidden projects keep their place in the stored order rather than sinking to the
/// bottom of the list when they are shown, because moving them would mean the pane rearranges
/// itself every time the toggle is flipped, and a project the owner is looking for would be in a
/// different place depending on a preference they cannot see from where they are looking. Lower
/// contrast is what says which are hidden. See `SidebarMetrics.hiddenDim`.
public enum ProjectVisibility {
    /// Where the "show them anyway" preference lives.
    ///
    /// A preference, and persistent, rather than a filter that resets when the window opens.
    /// It is the same fact as `Repo.hidden` seen from the other side: the owner decided that these
    /// projects are not worth the room, and a switch that quietly undid that decision on every
    /// launch would make hiding a thing you have to keep doing. It is also the only route back to
    /// a hidden project, so a session that forgot it would make an owner who had turned it on
    /// wonder where their projects went. Nothing about it is per window either: two windows
    /// showing different sets of projects is two answers to a question with one answer.
    ///
    /// Named here rather than written as a literal in the two places that read it, which is the
    /// same reason `DiffLayoutSetting` exists in the app target.
    public static let showsHiddenKey = "sidebar.showsHiddenProjects"

    /// The projects to draw, in the order they were handed over.
    public static func listed(_ repos: [Repo], showingHidden: Bool) -> [Repo] {
        showingHidden ? repos : repos.filter { !$0.hidden }
    }

    /// How many of them are hidden, which is what decides whether the toggle is worth offering at
    /// all: a switch for a state nothing is in is a switch that teaches the reader nothing.
    public static func hiddenCount(_ repos: [Repo]) -> Int {
        repos.count { $0.hidden }
    }

    /// The toggle's title, which says how many projects it is talking about.
    ///
    /// The count is in the words because a menu has no room for a badge, and because "Show hidden
    /// projects" on a sidebar that then gains one row reads as a control that half worked.
    ///
    /// It is offered even when nothing is hidden, and the count comes off the title when there is
    /// none. A switch that appears and disappears with the state it controls cannot be turned off
    /// once the last hidden project is shown, and a switch left on that nobody can see is worse
    /// than a switch that is briefly about nothing: the next project the owner hides would stay in
    /// the list, greyed, and look like a control that did not work.
    public static func toggleTitle(hiddenCount: Int) -> String {
        switch hiddenCount {
        case 0: "Show hidden projects"
        case 1: "Show 1 hidden project"
        default: "Show \(hiddenCount) hidden projects"
        }
    }

    /// Whether a project comes back into the sidebar because a workspace has just been added to
    /// it.
    ///
    /// This does not argue with the paragraph at the top of this file, it follows from it. Hiding
    /// says "there is nothing going on in this project and the column is 260 points wide". Cutting
    /// a worktree in it is that stopping, and the row this new workspace lives in is the one place
    /// in the window the sidebar would be leaving out. The case it was written for is an agent
    /// calling `workspace_start` over the bridge: the owner did not ask for the workspace, so
    /// nobody is watching for it, and the only routes back to a hidden project are a filter menu
    /// and `project_unhide`, neither of which anybody reaches for to find something they do not
    /// know exists.
    ///
    /// It is narrow on purpose. One boolean on one row, only when that row actually says hidden,
    /// and nothing else about hiding changes: the project keeps its place in the stored order
    /// (see above), the workspaces of every other hidden project stay exactly where they were,
    /// and nothing here ever hides anything.
    ///
    /// Nil is a project that is no longer in the database, which a create racing a project removal
    /// can produce, and a project that is gone is not one to bring back.
    public static func comesBack(_ project: Repo?) -> Bool {
        project?.hidden == true
    }

    /// What hiding this project would leave the sidebar showing, for a caller that cannot see it.
    ///
    /// The bridge's two tools say this out loud, because an agent hiding the last visible project
    /// on an owner's behalf leaves a column with nothing in it, and a tool that reports "done"
    /// and nothing else has told the owner's client nothing it could act on.
    public static func remainingSentence(visible: Int) -> String {
        switch visible {
        case 0:
            return "No projects are left showing in Bloom's sidebar. They are all still there: "
                + "turn on Show hidden projects in the sidebar's filter menu, or call "
                + "project_unhide, to bring one back."
        case 1:
            return "1 project is still showing in Bloom's sidebar."
        default:
            return "\(visible) projects are still showing in Bloom's sidebar."
        }
    }
}
