import Foundation

/// What the panel shows once something has been typed: the workspaces, then the handful of
/// commands whose names match, then the transcripts.
///
/// **Workspaces lead, because "which workspace was it" is the question people open this with.**
/// They are also the only half that is free: the names and branches are matched over an array
/// already in memory, so they are on screen before the query has left the main actor, while the
/// transcript half is a hop onto the store, an FTS5 match and a join. The two halves are therefore
/// built from two arguments here rather than from one fetch, and `transcripts` is empty until the
/// slower half answers. The panel fills that section in underneath rather than holding the fast
/// half back. See `AppModel.searchTranscripts` for the debounce and the replacement.
///
/// **Names are matched fuzzily and the matched characters are reported.** `WorkspaceSearch` is a
/// substring test and stays the rule for whether a row is in the list at all, because that is what
/// Home uses and a search that found a workspace in one surface and not the other would be worse
/// than either. What is added on top is `FuzzyMatch` over the name, which both ranks the answer
/// and says which characters to draw bold: typing `docs` should find `rewrite-documentation-site`
/// and then show why it did.
public enum SearchPanelResults {
    /// The listing for one query.
    ///
    /// - Parameters:
    ///   - transcripts: what the full text index said, already folded one row per workspace by
    ///     `TranscriptSearch.group`. Empty until the store answers, and empty when the query is
    ///     too short for it to be worth asking.
    public static func build(
        query: String,
        repos: [Repo],
        workspaces: [Workspace],
        archived: [Workspace],
        transcripts: [TranscriptWorkspaceMatches],
        scope: HomeScope,
        commands: [MenuBarItem] = MenuBarCatalogue.commands,
        reach: SearchPanelReach = .live
    ) -> SearchPanelListing {
        let needle = WorkspaceSearch.needle(query)
        guard !needle.isEmpty else { return .empty }

        var byID: [RepoID: Repo] = [:]
        byID.reserveCapacity(repos.count)
        for repo in repos { byID[repo.id] = repo }

        // The projects the answer is allowed to be about. A workspace whose project is not among
        // them is not considered at all: not drawn, not counted, and not offered as a reason to
        // widen, because "12 archived workspaces match" pointing at a project the sidebar is not
        // showing would be a hint the reader cannot act on. See `SearchPanelReach`.
        let reachable = Set(reach.projects(repos).map(\.id))

        var counts = HomeScopeCounts()
        /// Live matches, which are what every chip but Archived draws.
        var live: [SearchPanelWorkspaceHit] = []
        live.reserveCapacity(workspaces.count)
        /// Archived matches, drawn only under the Archived chip and counted always, so that chip
        /// carries a number worth pressing.
        var finished: [SearchPanelWorkspaceHit] = []

        func consider(_ workspace: Workspace, isArchived: Bool) {
            let repo = byID[workspace.repoID]
            // A project the sidebar is not showing is not an answer this panel gives, unless the
            // sidebar's own switch says otherwise. See `SearchPanelReach`.
            guard reachable.contains(workspace.repoID) else { return }
            // **Two rules, and a row is in the list if either answers.** The subsequence over the
            // name is what makes `docs` find `rewrite-documentation-site` and is what says which
            // characters to draw bold. `WorkspaceSearch` is the substring rule Home uses, and it
            // stays because it reaches the branch and the project as well: a search that found a
            // workspace on Home and not here would be worse than either rule on its own.
            let hit = FuzzyMatch.hit(workspace.name, query: needle)
            let field = WorkspaceSearch.match(workspace: workspace, repo: repo, needle: needle)
            guard hit != nil || field != nil else { return }
            let found = SearchPanelWorkspaceHit(
                workspace: workspace,
                repo: repo,
                highlights: hit?.positions ?? [],
                // Only when the name was not what put it there, since the row already draws the
                // name and the characters that hit in it.
                match: hit == nil && field != workspace.name ? field : nil,
                isArchived: isArchived,
                // A name match outranks a branch or project match, always: a workspace called what
                // you typed is the answer, and one whose project happens to contain the letters is
                // a near miss.
                score: hit?.score ?? 0
            )
            if isArchived {
                finished.append(found)
                counts.archived += 1
            } else {
                live.append(found)
                counts.live += 1
            }
        }

        for workspace in workspaces { consider(workspace, isArchived: false) }
        for workspace in archived { consider(workspace, isArchived: true) }
        // The three live chips count live work and nothing else, which is the whole reason their
        // numbers can be trusted against their own rows now. Archived keeps its own tally above.
        counts.workspaces = live.count

        let archivedIDs = Set(archived.map(\.id))
        let known = Set(workspaces.map(\.id)).union(archivedIDs)
        // A result whose workspace has been deleted since the index was written has nothing to
        // open, so it is dropped rather than drawn as a row that does nothing. A result from a
        // project the reach does not cover is dropped for the reason `reachable` gives.
        let repoOf: (WorkspaceID) -> RepoID? = { id in
            (workspaces.first { $0.id == id } ?? archived.first { $0.id == id })?.repoID
        }
        let hits = transcripts.filter { result in
            guard known.contains(result.workspaceID) else { return false }
            guard let repoID = repoOf(result.workspaceID) else { return false }
            return reachable.contains(repoID)
        }
        /// Every archived workspace this query reached, however it matched, which is what the card
        /// offers when the live answer is empty.
        var archivedWorkspaces = Set(finished.map(\.id))
        for hit in hits {
            if archivedIDs.contains(hit.workspaceID) {
                counts.archived += hit.total
                archivedWorkspaces.insert(hit.workspaceID)
            } else {
                counts.transcripts += hit.total
                counts.transcriptWorkspaces += 1
            }
        }

        let matched = reach.archived ? live + finished : live
        let shownWorkspaces = matched
            .filter { hit in
                scope.showsWorkspaces && scope.includes(
                    HomeRow(workspace: hit.workspace, repo: hit.repo), activity: HomeActivity()
                )
            }
            .sorted { left, right in
                if left.score != right.score { return left.score > right.score }
                return left.workspace.lastActivityAt > right.workspace.lastActivityAt
            }

        let shownTranscripts = hits
            .filter { result in
                let isArchived = archivedIDs.contains(result.workspaceID)
                // The reach first, then the chip. Under Everything the chip would take an archived
                // transcript, and it must not: the three live chips draw live work, which is what
                // makes their counts describe their own rows.
                guard reach.archived || !isArchived else { return false }
                return scope.includesTranscript(isArchived: isArchived)
            }
            .map { result in
                let workspace = workspaces.first { $0.id == result.workspaceID }
                    ?? archived.first { $0.id == result.workspaceID }
                return SearchPanelTranscriptHit(
                    result: result,
                    workspace: workspace,
                    repo: workspace.flatMap { byID[$0.repoID] },
                    isArchived: archivedIDs.contains(result.workspaceID)
                )
            }

        let shownCommands = inlineCommands(needle, scope: scope, commands: commands)

        var sections: [SearchPanelSection] = []
        if !shownWorkspaces.isEmpty {
            sections.append(
                SearchPanelSection(
                    id: "workspaces", title: "Workspaces",
                    rows: shownWorkspaces.map { .workspace($0) }
                )
            )
        }
        if !shownCommands.isEmpty {
            sections.append(
                SearchPanelSection(
                    id: "commands", title: "Commands",
                    rows: shownCommands.map { .command($0) }
                )
            )
        }
        if !shownTranscripts.isEmpty {
            sections.append(
                SearchPanelSection(
                    id: "transcripts", title: "Transcripts",
                    rows: shownTranscripts.map { .transcript($0) }
                )
            )
        }

        // Nothing is added under an empty answer. It used to be a sentence and two action rows,
        // and the owner's reply to seeing them was to say nothing found and offer nothing: see
        // `SearchPanelNothing`.
        return SearchPanelListing(
            sections: sections,
            counts: counts,
            isSearching: true,
            // The lit chip's own number, in the lit chip's own unit. The footer used to count rows
            // while the chips counted matches, and nothing on the card said they were answering
            // different questions. See `SearchPanelSummary`.
            summary: SearchPanelSummary.searching(scope: scope, counts: counts),
            nothing: sections.isEmpty ? nothing(query, archived: archivedWorkspaces.count, reach: reach) : nil
        )
    }

    /// What the card says when the answer is empty, which is not one sentence any more.
    ///
    /// A search of live work alone would otherwise refuse to find the archived workspace somebody
    /// is searching for the name of, and `HomeScope.settle` warns about exactly that. So an empty
    /// live answer over a non-empty archive says how much is in the archive, and the narrowing is
    /// only safe because it does. Under the Archived chip the reach already covers the archive, so
    /// there is nothing left to point at and the plain sentence is the true one.
    private static func nothing(
        _ query: String, archived: Int, reach: SearchPanelReach
    ) -> SearchPanelNothing {
        guard !reach.archived, archived > 0 else { return .noMatch(query) }
        return .noLiveMatch(query, archived: archived)
    }

    /// The few commands a search of things is allowed to show.
    ///
    /// **Under the Everything chip alone.** The other three chips name a kind of thing that
    /// matched, and a menu item is neither a workspace nor a transcript, so a command row under
    /// Workspaces would be a row the chip above it says is not there.
    ///
    /// They are deliberately not in `counts`. The chips are Home's and they count workspaces and
    /// transcript matches; adding a third kind to the Everything number would make the two
    /// surfaces disagree about how much there is, over rows that are a hint rather than the
    /// answer. Typing `>` is what asks for the whole menu bar.
    private static func inlineCommands(
        _ needle: String, scope: HomeScope, commands: [MenuBarItem]
    ) -> [SearchPanelCommandHit] {
        guard scope == .all, needle.count >= SearchPanelCommands.inlineMinimumQueryLength else {
            return []
        }
        return Array(SearchPanelCommands.rank(needle, in: commands).prefix(SearchPanelCommands.inlineLimit))
    }
}
