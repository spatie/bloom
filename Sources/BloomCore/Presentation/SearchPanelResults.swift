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
    ///   - hasProjects: whether a workspace can be started, which decides one of the two fallback
    ///     rows. See `SearchPanelFallback`.
    public static func build(
        query: String,
        repos: [Repo],
        workspaces: [Workspace],
        archived: [Workspace],
        transcripts: [TranscriptWorkspaceMatches],
        scope: HomeScope,
        commands: [MenuBarItem] = MenuBarCatalogue.commands,
        hasProjects: Bool
    ) -> SearchPanelListing {
        let needle = WorkspaceSearch.needle(query)
        guard !needle.isEmpty else { return .empty }

        var byID: [RepoID: Repo] = [:]
        byID.reserveCapacity(repos.count)
        for repo in repos { byID[repo.id] = repo }

        var counts = HomeScopeCounts()
        var matched: [SearchPanelWorkspaceHit] = []
        matched.reserveCapacity(workspaces.count)

        func consider(_ workspace: Workspace, isArchived: Bool) {
            let repo = byID[workspace.repoID]
            // **Two rules, and a row is in the list if either answers.** The subsequence over the
            // name is what makes `docs` find `rewrite-documentation-site` and is what says which
            // characters to draw bold. `WorkspaceSearch` is the substring rule Home uses, and it
            // stays because it reaches the branch and the project as well: a search that found a
            // workspace on Home and not here would be worse than either rule on its own.
            let hit = FuzzyMatch.hit(workspace.name, query: needle)
            let field = WorkspaceSearch.match(workspace: workspace, repo: repo, needle: needle)
            guard hit != nil || field != nil else { return }
            matched.append(
                SearchPanelWorkspaceHit(
                    workspace: workspace,
                    repo: repo,
                    highlights: hit?.positions ?? [],
                    // Only when the name was not what put it there, since the row already draws
                    // the name and the characters that hit in it.
                    match: hit == nil && field != workspace.name ? field : nil,
                    isArchived: isArchived,
                    // A name match outranks a branch or project match, always: a workspace called
                    // what you typed is the answer, and one whose project happens to contain the
                    // letters is a near miss.
                    score: hit?.score ?? 0
                )
            )
            if isArchived { counts.archived += 1 } else { counts.live += 1 }
        }

        for workspace in workspaces { consider(workspace, isArchived: false) }
        for workspace in archived { consider(workspace, isArchived: true) }
        counts.workspaces = matched.count

        let archivedIDs = Set(archived.map(\.id))
        let known = Set(workspaces.map(\.id)).union(archivedIDs)
        // A result whose workspace has been deleted since the index was written has nothing to
        // open, so it is dropped rather than drawn as a row that does nothing.
        let hits = transcripts.filter { known.contains($0.workspaceID) }
        for hit in hits {
            counts.transcripts += hit.total
            counts.transcriptWorkspaces += 1
            if archivedIDs.contains(hit.workspaceID) { counts.archived += hit.total }
        }

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
            .filter { scope.includesTranscript(isArchived: archivedIDs.contains($0.workspaceID)) }
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

        var summaryLine: String?
        if sections.isEmpty {
            summaryLine = SearchPanelFallback.summary(for: query)
            let rows = SearchPanelFallback.rows(for: query, hasProjects: hasProjects)
            if !rows.isEmpty {
                sections.append(
                    SearchPanelSection(id: "fallback", title: nil, rows: rows.map { .fallback($0) })
                )
            }
        }

        return SearchPanelListing(
            sections: sections, counts: counts, isSearching: true, summaryLine: summaryLine
        )
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
