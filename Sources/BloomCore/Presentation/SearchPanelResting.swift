import Foundation

/// What the panel shows before anything has been typed.
///
/// **It is not recents and it is not everything.** Slack's quick switcher shows only unread
/// conversations, capped at twenty-four, having found that listing every channel was crushing on a
/// large team. Bloom has a better version of that finding available to it: it knows not merely
/// that something is unread but whether an agent has stopped to ask a question. Somebody running
/// eight agents opens this panel already wanting to know which one wants them, so that is answered
/// first, under a heading, and what they last had open comes second.
///
/// **It caps itself, which a full list does not.** The panel is three hundred points of list. A
/// scrollable index of the machine put at the top of it would be a worse Home, reached by a key.
public enum SearchPanelResting {
    /// How many workspaces the first section can hold.
    ///
    /// Five, because a person with more than five agents wanting them has a problem the panel
    /// cannot solve by listing it, and because the second section has to be visible without
    /// scrolling for the panel to read as two answers rather than one long one.
    public static let waitingCap = 5

    /// How many of the recently open follow.
    public static let recentCap = 5

    /// The resting list, in drawn order.
    ///
    /// - Parameters:
    ///   - workspaces: the live ones, which is what "waiting" and "what you last had open" are
    ///     both about. An archived workspace is neither: it cannot be waiting on anybody and it is
    ///     not open. It is still reachable by typing its name, which is the point of the search
    ///     half.
    ///   - repos: for the project name each row carries, because the panel is flat and a row is
    ///     the only place its project can be said.
    ///   - activity: which agents are running and which have stopped to ask. Handed in for the
    ///     reason `HomeActivity` gives: it lives in the app's memory and moves without the row
    ///     moving.
    public static func build(
        workspaces: [Workspace],
        repos: [Repo],
        activity: HomeActivity
    ) -> SearchPanelListing {
        var byID: [RepoID: Repo] = [:]
        byID.reserveCapacity(repos.count)
        for repo in repos { byID[repo.id] = repo }

        // Most recent first in both sections, which is the order every other list of workspaces in
        // the app is in. Sorted once and split, rather than sorted twice.
        let recent = workspaces.sorted { $0.lastActivityAt > $1.lastActivityAt }

        let waiting = recent
            .compactMap { workspace -> SearchPanelWorkspaceHit? in
                guard let reason = reason(for: workspace, activity: activity) else { return nil }
                return SearchPanelWorkspaceHit(
                    workspace: workspace, repo: byID[workspace.repoID], waiting: reason
                )
            }
            .prefix(waitingCap)

        let taken = Set(waiting.map(\.id))
        let opened = recent
            .filter { !taken.contains($0.id) }
            .prefix(recentCap)
            .map { SearchPanelWorkspaceHit(workspace: $0, repo: byID[$0.repoID]) }

        var sections: [SearchPanelSection] = []
        if !waiting.isEmpty {
            sections.append(
                SearchPanelSection(
                    id: "waiting", title: "Waiting on you",
                    rows: waiting.map { .workspace($0) }
                )
            )
        }
        if !opened.isEmpty {
            sections.append(
                SearchPanelSection(
                    id: "recent", title: sections.isEmpty ? "Recent" : "Recently open",
                    rows: opened.map { .workspace($0) }
                )
            )
        }
        // A machine with no workspaces on it at all, which is every fresh install and is the one
        // state nobody who builds this ever sees. The card says so rather than drawing an empty
        // rounded rectangle with a footer under it.
        return SearchPanelListing(
            sections: sections,
            // The one place in this panel where a total really is withheld: the two caps above
            // mean a machine with forty-three live workspaces draws ten rows, and nothing used to
            // say the other thirty-three were there. See `SearchPanelSummary.resting`.
            summary: SearchPanelSummary.resting(
                shown: waiting.count + opened.count, of: workspaces.count
            ),
            nothing: sections.isEmpty ? .nothingYet : nil
        )
    }

    /// Which of the two kinds of waiting a workspace is in, or neither.
    ///
    /// The question is asked in the order a person would want answering: an agent blocked on an
    /// answer needs them now, where a finished turn is only unread. Both come from
    /// `HomeActivity.needsYou`, which is the same rule Home's rows and the sidebar's glyphs draw,
    /// so a workspace cannot be waiting here and quiet there.
    public static func reason(
        for workspace: Workspace, activity: HomeActivity
    ) -> SearchPanelWaiting? {
        guard activity.needsYou(workspace) else { return nil }
        return activity.waiting.contains(workspace.id) ? .askedAQuestion : .turnFinished
    }
}
