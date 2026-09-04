import Foundation
import Testing
@testable import BloomCore

/// What the panel shows once something has been typed: which rows are in the list, in what order,
/// under which headings, and what each chip says.
///
/// The transcript half arrives a moment after the name half, so every test here that cares about
/// ordering hands the transcripts in separately, which is the shape the app is really in: the
/// names are on screen before the store has answered.
@Suite("Search panel results")
struct SearchPanelResultsTests {
    private func workspace(
        _ name: String,
        branch: String? = nil,
        repoID: RepoID = RepoID("repo"),
        state: WorkspaceState = .active,
        at activity: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) -> Workspace {
        Workspace(
            id: WorkspaceID(name),
            repoID: repoID,
            name: name,
            branch: branch ?? "feature/\(name)",
            path: "/tmp/\(name)",
            baseBranch: "main",
            state: state,
            lastActivityAt: activity
        )
    }

    private let repo = Repo(id: RepoID("repo"), name: "runbloom", path: "/tmp/repo")

    private func transcriptResult(_ workspace: String, matches: Int) -> TranscriptWorkspaceMatches {
        TranscriptWorkspaceMatches(
            workspaceID: WorkspaceID(workspace),
            matches: [
                TranscriptMatch(
                    messageID: 1,
                    workspaceID: WorkspaceID(workspace),
                    sessionID: SessionID("s-\(workspace)"),
                    sessionTitle: "Session",
                    seq: 7,
                    kind: .assistantText,
                    createdAt: Date(timeIntervalSince1970: 0),
                    snippet: TranscriptSnippet(segments: []),
                    score: -1
                ),
            ],
            total: matches
        )
    }

    private func build(
        _ query: String,
        workspaces: [Workspace] = [],
        archived: [Workspace] = [],
        transcripts: [TranscriptWorkspaceMatches] = [],
        scope: HomeScope = .all,
        commands: [MenuBarItem] = [],
        hasProjects: Bool = true
    ) -> SearchPanelListing {
        SearchPanelResults.build(
            query: query,
            repos: [repo],
            workspaces: workspaces,
            archived: archived,
            transcripts: transcripts,
            scope: scope,
            commands: commands,
            hasProjects: hasProjects
        )
    }

    /// "Which workspace was it" is the question people open this with, and it is also the half
    /// that is free: an array in memory rather than a hop onto the store.
    @Test("workspaces lead, then commands, then transcripts")
    func theOrderOfTheSections() {
        let listing = build(
            "docs",
            workspaces: [workspace("docs chapters")],
            transcripts: [transcriptResult("docs chapters", matches: 6)],
            commands: [MenuBarCatalogue[.showChanges]]
        )
        #expect(listing.sections.map(\.title) == ["Workspaces", "Transcripts"])

        let withCommand = build(
            "changes",
            workspaces: [workspace("changes")],
            transcripts: [transcriptResult("changes", matches: 2)],
            commands: [MenuBarCatalogue[.showChanges]]
        )
        #expect(withCommand.sections.map(\.title) == ["Workspaces", "Commands", "Transcripts"])
    }

    /// The subsequence match is what ranks and highlights; the substring match is what decides
    /// membership, so the panel reaches exactly what Home reaches.
    @Test("a name match reports the characters it hit and outranks a branch match")
    func nameMatchesLeadAndHighlight() {
        let listing = build(
            "docs",
            workspaces: [
                workspace("appcast", branch: "feature/docs-fix"),
                workspace("docs chapters"),
            ]
        )
        #expect(listing.rows.map(\.id) == ["workspace:docs chapters", "workspace:appcast"])

        guard case .workspace(let best)? = listing.rows.first,
              case .workspace(let branchHit) = listing.rows[1] else {
            Issue.record("expected two workspace rows")
            return
        }
        #expect(best.highlights == [0, 1, 2, 3])
        #expect(best.match == nil)
        #expect(branchHit.match == "feature/docs-fix")
        #expect(branchHit.highlights.isEmpty)
    }

    /// `docs` has to find `rewrite-documentation-site`, and then show why it did.
    @Test("a subsequence of the name is a match and is drawn as one")
    func subsequenceMatching() {
        let listing = build("docs", workspaces: [workspace("rewrite-documentation-site")])
        #expect(listing.rows.count == 1)
    }

    @Test("a row matched on its project says so")
    func projectMatchesSayWhy() {
        let listing = build("runbloom", workspaces: [workspace("pill caps")])
        guard case .workspace(let hit)? = listing.rows.first else {
            Issue.record("expected a workspace row")
            return
        }
        #expect(hit.match == "runbloom")
    }

    /// Home's own counts, worked out in the same pass, so the two surfaces cannot disagree about
    /// how much archived work there is.
    @Test("the chips count workspaces and transcript matches, archived work in both")
    func theChipCounts() {
        let listing = build(
            "docs",
            workspaces: [workspace("docs chapters")],
            archived: [workspace("docs import", state: .archived)],
            transcripts: [
                transcriptResult("docs chapters", matches: 6),
                transcriptResult("docs import", matches: 8),
            ]
        )
        #expect(listing.counts.workspaces == 2)
        #expect(listing.counts.transcripts == 14)
        #expect(listing.counts.transcriptWorkspaces == 2)
        // One archived row plus the eight matches inside the archived workspace.
        #expect(listing.counts.archived == 9)
        #expect(listing.counts.count(of: .all, searching: true) == 16)
    }

    /// The chips split the answer by what kind of thing matched rather than filtering rows, which
    /// is the distinction Home already draws.
    @Test("a chip narrows the rows and leaves the counts alone")
    func aChipDoesNotChangeItsOwnCount() {
        let everything = build(
            "docs",
            workspaces: [workspace("docs chapters")],
            transcripts: [transcriptResult("docs chapters", matches: 6)]
        )
        let transcriptsOnly = build(
            "docs",
            workspaces: [workspace("docs chapters")],
            transcripts: [transcriptResult("docs chapters", matches: 6)],
            scope: .transcripts
        )
        #expect(everything.sections.count == 2)
        #expect(transcriptsOnly.sections.map(\.title) == ["Transcripts"])
        #expect(transcriptsOnly.counts.workspaces == everything.counts.workspaces)
    }

    /// The Archived chip means finished work rather than finished workspaces, so it holds the
    /// transcripts of archived workspaces as well as their rows.
    @Test("the archived chip keeps an archived workspace's transcript and drops a live one's")
    func theArchivedChip() {
        let listing = build(
            "docs",
            workspaces: [workspace("docs chapters")],
            archived: [workspace("docs import", state: .archived)],
            transcripts: [
                transcriptResult("docs chapters", matches: 6),
                transcriptResult("docs import", matches: 8),
            ],
            scope: .archived
        )
        #expect(listing.rows.map(\.id) == ["workspace:docs import", "transcript:docs import"])
    }

    /// It has been deleted since the index was written, so there is nothing to open.
    @Test("a transcript hit for a workspace that is gone is dropped")
    func orphanedTranscriptsAreDropped() {
        let listing = build(
            "docs",
            workspaces: [workspace("docs chapters")],
            transcripts: [transcriptResult("deleted", matches: 3)]
        )
        #expect(listing.rows.map(\.id) == ["workspace:docs chapters"])
        #expect(listing.counts.transcripts == 0)
    }

    /// Somebody who searched for a workspace that does not exist has just told you what to call
    /// it. Two rows and no more.
    @Test("nothing matching gives exactly the two fallback rows")
    func theFallbackRows() {
        let listing = build("houdini", workspaces: [workspace("docs chapters")])
        #expect(listing.rows.map(\.id) == ["fallback:start-workspace", "fallback:search-home"])
        guard case .fallback(let start)? = listing.rows.first else {
            Issue.record("expected a fallback row")
            return
        }
        #expect(start.title == "Start a workspace called houdini")
        #expect(start.action == .newWorkspace)
    }

    /// With no project added there is nothing to cut a worktree from, so the row would be a
    /// promise the app cannot keep.
    @Test("the start row is absent when there is no project to start it in")
    func noProjectMeansNoStartRow() {
        let listing = build("houdini", hasProjects: false)
        #expect(listing.rows.map(\.id) == ["fallback:search-home"])
    }

    /// Only while the backfill is running. At any other time the same sentence would be an excuse
    /// rather than a fact.
    @Test("the incomplete index is stated only while it is being built")
    func theIndexNotice() {
        #expect(SearchPanelFallback.indexNotice(isIndexing: false) == nil)
        #expect(SearchPanelFallback.indexNotice(isIndexing: true)?.isEmpty == false)
        #expect(SearchPanelFallback.summary(for: " houdini ") == "No workspace, transcript or command matches houdini.")
    }

    /// A menu item is neither a workspace nor a transcript, so a command row under a chip that
    /// names one of those two would be a row the chip above it says is not there.
    @Test("commands are shown under Everything alone, capped, and never for one letter")
    func inlineCommandsAreAHint() {
        let commands = MenuBarCatalogue.commands
        let everything = build("n", workspaces: [], commands: commands)
        #expect(!everything.sections.contains { $0.title == "Commands" })

        let two = build("ne", workspaces: [], commands: commands)
        let section = two.sections.first { $0.title == "Commands" }
        #expect(section?.rows.count == SearchPanelCommands.inlineLimit)

        let narrowed = build("ne", workspaces: [], scope: .workspaces, commands: commands)
        #expect(!narrowed.sections.contains { $0.title == "Commands" })
    }

    @Test("an empty query has no listing of its own")
    func anEmptyQueryIsNotASearch() {
        #expect(build("   ").isEmpty)
    }

    /// The highlight is an index into the flattened rows, so a listing that derived them
    /// differently from the sections would open a row the reader is not looking at.
    @Test("the flattened rows are the drawn order with the headings taken out")
    func flatteningMatchesTheSections() {
        let listing = build(
            "docs",
            workspaces: [workspace("docs chapters")],
            transcripts: [transcriptResult("docs chapters", matches: 6)]
        )
        #expect(listing.rows == listing.sections.flatMap(\.rows))
        #expect(listing.row(at: 1)?.id == "transcript:docs chapters")
        #expect(listing.row(at: 9) == nil)
        #expect(listing.summary == "2 results")
    }

    /// A workspace's own menu acts on a worktree that is there. An archived row has none, and a
    /// command has no workspace at all.
    @Test("only a live workspace's row can be pushed into")
    func whatCanBeDrilled() {
        let listing = build(
            "docs",
            workspaces: [workspace("docs chapters")],
            archived: [workspace("docs import", state: .archived)],
            transcripts: [transcriptResult("docs chapters", matches: 2)]
        )
        let drillable = Dictionary(
            uniqueKeysWithValues: listing.rows.map { ($0.id, $0.drillable) }
        )
        #expect(drillable["workspace:docs chapters"] == WorkspaceID("docs chapters"))
        #expect(drillable["workspace:docs import"] == .some(nil))
        #expect(drillable["transcript:docs chapters"] == WorkspaceID("docs chapters"))
    }
}
