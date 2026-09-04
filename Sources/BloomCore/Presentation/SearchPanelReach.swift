import Foundation

/// How far the search panel is allowed to look: live work by default, and finished or tidied-away
/// work only when something asks for it.
///
/// # Why the default narrowed
///
/// The panel used to answer over everything the database held. On the owner's machine that made
/// "Everything" 3752 against "Archived" 2317, so more than half of every answer was work he had
/// finished with, and a name he half remembered came back as four archived worktrees and the one
/// live workspace he wanted, in whatever order the ranking chose. His words were to make the panel
/// "only take active non-archived, non-hidden workspace and project into account by default", and
/// to add a way to widen it.
///
/// # The two halves are not the same fact and do not get the same control
///
/// **Archived work is finished.** The way back to it is the Archived chip, which was already on
/// the row and already meant exactly this: `HomeScope.archived` is "readable, restorable, with
/// nothing left on disk", and it holds the transcripts of archived workspaces as well as their
/// rows. So no control is added for it. What changes is that the other three chips stop carrying
/// it, which is also what makes their counts honest: Everything now counts what Everything shows.
///
/// **Hidden is somebody saying "not now, and not in my way".** It already has a control, a
/// persistent one, and it is the sidebar's own "Show hidden projects": see
/// `ProjectVisibility.showsHiddenKey`. The panel reads that same preference rather than growing a
/// second switch, so there is one answer in the window to "am I looking at hidden projects", and
/// turning it on to find something puts it back in the sidebar too, which is where somebody
/// looking for a hidden project is going next.
///
/// **This makes an old sentence false and it has been corrected rather than left.**
/// `ProjectVisibility` and `Repo.hidden` both said that a hidden project's workspaces keep turning
/// up in search, and that was a deliberate decision at the time: hiding is a view preference and
/// must never be a way to lose work. That argument still holds and this does not break it, because
/// a hidden project's workspaces still run, still notify, still appear on Home and in the menu bar,
/// and are one switch away here. What changed is that "narrows one list" is now "narrows the two
/// lists that are about browsing", and both are governed by the same switch.
///
/// # Nothing is lost silently
///
/// A search of live work alone would otherwise refuse to find the archived workspace somebody is
/// searching for the name of, which `HomeScope.settle` warns about in as many words. So when the
/// live answer is empty and the archive is not, the card says so and says how much: see
/// `SearchPanelNothing.noLiveMatch`. The narrowing is only safe because that sentence exists.
public struct SearchPanelReach: Equatable, Sendable {
    /// Whether finished work is in the answer.
    public var archived: Bool

    /// Whether the projects the sidebar is leaving out are in the answer.
    public var hidden: Bool

    /// The default: live work, in the projects the sidebar is showing.
    public static let live = SearchPanelReach()

    public init(archived: Bool = false, hidden: Bool = false) {
        self.archived = archived
        self.hidden = hidden
    }

    /// What the panel reaches for under one chip, with the sidebar's own preference.
    ///
    /// The Archived chip is the widening rather than a narrowing of something already there,
    /// which is the whole of the design: under it the archive is fetched and drawn, and under
    /// every other chip it is counted and not drawn. Counted, because a chip whose number went to
    /// nought whenever it was not lit is a chip nobody would ever press.
    public static func reading(scope: HomeScope, showsHiddenProjects: Bool) -> SearchPanelReach {
        SearchPanelReach(archived: scope == .archived, hidden: showsHiddenProjects)
    }

    /// The projects a search is allowed to answer over.
    public func projects(_ repos: [Repo]) -> [Repo] {
        hidden ? repos : repos.filter { !$0.hidden }
    }
}
