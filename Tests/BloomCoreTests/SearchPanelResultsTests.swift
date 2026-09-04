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
        repos: [Repo]? = nil,
        reach: SearchPanelReach = .live
    ) -> SearchPanelListing {
        SearchPanelResults.build(
            query: query,
            repos: repos ?? [repo],
            workspaces: workspaces,
            archived: archived,
            transcripts: transcripts,
            scope: scope,
            commands: commands,
            reach: reach
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

    /// **Each chip counts what pressing it would show, and no chip counts another chip's work.**
    /// The three live chips used to carry archived work as well, so Everything read 3752 against
    /// Archived 2317 on the owner's machine and more than half of Everything was work he had
    /// finished with. See `SearchPanelReach`.
    @Test("the live chips count live work and Archived counts the archive")
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
        #expect(listing.counts.workspaces == 1)
        #expect(listing.counts.transcripts == 6)
        #expect(listing.counts.transcriptWorkspaces == 1)
        // One archived row plus the eight matches inside the archived workspace. Counted even
        // though none of it is drawn: a chip whose number went to nought whenever it was not lit
        // is a chip nobody would ever press.
        #expect(listing.counts.archived == 9)
        #expect(listing.counts.count(of: .all, searching: true) == 7)
        // And the rows are the live ones alone.
        #expect(listing.rows.map(\.id) == ["workspace:docs chapters", "transcript:docs chapters"])
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

    /// The owner looked at the two rows that used to be here and said no: say nothing was found,
    /// and offer nothing.
    @Test("a search that matches nothing draws no rows at all")
    func nothingFound() {
        let listing = build("houdini", workspaces: [workspace("docs chapters")])
        #expect(listing.rows.isEmpty)
        #expect(listing.nothing == .noMatch("houdini"))
        // The footer counted the two rows it used to draw, so a card saying nothing matched
        // carried "2 results" beside it.
        #expect(listing.summary == nil)

        let matched = build("docs", workspaces: [workspace("docs chapters")])
        #expect(matched.nothing == nil)
        #expect(matched.summary == "1 result")
    }

    /// A fresh install is the state nobody who builds this ever sees, and it is the one that
    /// cannot be told apart from a search that missed unless the builder says which it is.
    @Test("an empty install searching for anything is told apart from a query that missed")
    func nothingFoundWithNothingInstalled() {
        let listing = build("houdini")
        #expect(listing.rows.isEmpty)
        #expect(listing.nothing == .noMatch("houdini"))
        #expect(listing.counts == HomeScopeCounts())
    }

    /// The query is the useful part of the message: somebody who typed nine characters wants to
    /// see which nine.
    @Test("the words say which of the three nothings this is, and quote the query")
    func theWordsForNothing() {
        #expect(SearchPanelNothing.noMatch("houdini").message.contains("houdini"))
        #expect(SearchPanelNothing.noCommand("houdini").message.contains("houdini"))
        #expect(SearchPanelNothing.noMatch("houdini").title != SearchPanelNothing.nothingYet.title)
        #expect(SearchPanelNothing.noCommand("x").title != SearchPanelNothing.noMatch("x").title)
        // Trimmed, so a trailing space typed before the search landed is not quoted back.
        #expect(SearchPanelNothing.noMatch(" houdini ").message.contains("\u{201C}houdini\u{201D}"))
    }

    /// Only while the backfill is running. At any other time the same sentence would be an excuse
    /// rather than a fact, and it belongs to a search that missed rather than to an empty install,
    /// which has nothing to index.
    @Test("the incomplete index is stated only while it is being built")
    func theIndexNotice() {
        #expect(SearchPanelNothing.noMatch("x").indexNotice(isIndexing: false) == nil)
        #expect(SearchPanelNothing.noMatch("x").indexNotice(isIndexing: true)?.isEmpty == false)
        #expect(SearchPanelNothing.nothingYet.indexNotice(isIndexing: true) == nil)
        #expect(SearchPanelNothing.noCommand("x").indexNotice(isIndexing: true) == nil)
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
        // Two rows, and the footer says seven, which is the whole point of `SearchPanelSummary`:
        // the second row is one workspace standing for six matches, so counting rows and counting
        // what the chips count are two different questions. This used to say "2 results" under a
        // chip saying seven.
        #expect(listing.rows.count == 2)
        #expect(listing.summary == "7 results")
    }

    /// Every row that names a workspace can be pushed into, archived ones included: what an
    /// archived workspace can be asked to do is `WorkspaceMenuSubject.allows`, and it is the same
    /// shorter menu Home already draws for one. A command has no workspace at all.
    @Test("a row that names a workspace can be pushed into, whether or not it is archived")
    func whatCanBeDrilled() {
        // Under the Archived chip, because that is the only place an archived row is drawn now.
        let listing = build(
            "docs",
            workspaces: [workspace("docs chapters")],
            archived: [workspace("docs import", state: .archived)],
            transcripts: [transcriptResult("docs chapters", matches: 2)],
            reach: SearchPanelReach(archived: true)
        )
        let drillable = Dictionary(
            uniqueKeysWithValues: listing.rows.map { ($0.id, $0.drillable) }
        )
        #expect(drillable["workspace:docs chapters"] == WorkspaceID("docs chapters"))
        #expect(drillable["workspace:docs import"] == WorkspaceID("docs import"))
        #expect(drillable["transcript:docs chapters"] == WorkspaceID("docs chapters"))
    }
}

/// What the one line at the right of the footer says, and why it is not the row count.
@Suite("Search panel summary")
struct SearchPanelSummaryTests {
    private func counts(workspaces: Int = 0, transcripts: Int = 0, archived: Int = 0) -> HomeScopeCounts {
        var built = HomeScopeCounts()
        built.workspaces = workspaces
        built.transcripts = transcripts
        built.archived = archived
        return built
    }

    /// The bug this exists for: the chip said 3749 and the footer said 30, and neither was wrong.
    /// A transcript row is one workspace folded out of many matches, so the two were counting
    /// different things and nothing on the card said so.
    @Test("a search answers the lit chip in the lit chip's own unit")
    func theFooterAnswersTheChip() {
        let found = counts(workspaces: 3, transcripts: 3_749)
        #expect(SearchPanelSummary.searching(scope: .transcripts, counts: found) == "3749 matches")
        #expect(SearchPanelSummary.searching(scope: .workspaces, counts: found) == "3 workspaces")
        // `all` is workspaces plus matches, which is Home's definition and is two kinds of thing
        // added together, so the vague noun is the only honest one for it.
        #expect(SearchPanelSummary.searching(scope: .all, counts: found) == "3752 results")
    }

    @Test("one of anything is said in the singular")
    func theSingular() {
        #expect(SearchPanelSummary.searching(
            scope: .workspaces, counts: counts(workspaces: 1)
        ) == "1 workspace")
        #expect(SearchPanelSummary.searching(
            scope: .transcripts, counts: counts(transcripts: 1)
        ) == "1 match")
        #expect(SearchPanelSummary.rows(1) == "1 result")
    }

    /// Nothing to count is said by the card rather than by the footer. See `SearchPanelNothing`.
    @Test("nothing found says nothing here")
    func nothingIsSaidElsewhere() {
        #expect(SearchPanelSummary.searching(scope: .all, counts: HomeScopeCounts()) == nil)
        #expect(SearchPanelSummary.rows(0) == nil)
        #expect(SearchPanelSummary.resting(shown: 0, of: 0) == nil)
    }

    /// The one place in the panel where a total really is withheld, and it had no number at all.
    @Test("the resting list names the workspaces it is not showing")
    func theRestingCap() {
        #expect(SearchPanelSummary.resting(shown: 10, of: 43) == "10 of 43 workspaces")
        // "10 of 10" is a worse sentence than "10 workspaces" and says nothing the first half did
        // not, so the total is named only when it is bigger.
        #expect(SearchPanelSummary.resting(shown: 10, of: 10) == "10 workspaces")
        #expect(SearchPanelSummary.resting(shown: 1, of: 1) == "1 workspace")
    }

    /// A listing that says nothing about itself falls back to the plain row count, which is right
    /// for the two lists that neither fold nor cap.
    @Test("a plain list of rows counts its rows")
    func thePlainCase() {
        let listing = SearchPanelListing(sections: [
            SearchPanelSection(id: "commands", title: nil, rows: []),
        ])
        #expect(listing.summary == nil)
    }
}
