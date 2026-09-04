import Foundation
import Testing
@testable import BloomCore

/// How far the panel looks: live work in visible projects by default, wider when something asks.
@Suite("Search panel reach")
struct SearchPanelReachTests {
    private let visible = Repo(id: RepoID("visible"), name: "runbloom", path: "/tmp/visible")
    private let tidied = Repo(
        id: RepoID("tidied"), name: "there-there", path: "/tmp/tidied", hidden: true
    )

    private func workspace(
        _ name: String,
        repoID: RepoID = RepoID("visible"),
        state: WorkspaceState = .active
    ) -> Workspace {
        Workspace(
            id: WorkspaceID(name),
            repoID: repoID,
            name: name,
            branch: "feature/\(name)",
            path: "/tmp/\(name)",
            baseBranch: "main",
            state: state,
            lastActivityAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    private func transcriptResult(_ workspace: String, matches: Int) -> TranscriptWorkspaceMatches {
        TranscriptWorkspaceMatches(
            workspaceID: WorkspaceID(workspace),
            matches: [
                TranscriptMatch(
                    messageID: 1,
                    workspaceID: WorkspaceID(workspace),
                    sessionID: SessionID("s"),
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
        scope: HomeScope = .all, reach: SearchPanelReach = .live
    ) -> SearchPanelListing {
        SearchPanelResults.build(
            query: "docs",
            repos: [visible, tidied],
            workspaces: [
                workspace("docs here"),
                workspace("docs tidied", repoID: RepoID("tidied")),
            ],
            archived: [workspace("docs finished", state: .archived)],
            transcripts: [
                transcriptResult("docs here", matches: 2),
                transcriptResult("docs tidied", matches: 4),
                transcriptResult("docs finished", matches: 8),
            ],
            scope: scope,
            commands: [],
            reach: reach
        )
    }

    // MARK: - The default

    /// What the owner asked for: active, non-archived, non-hidden, and nothing else.
    @Test("by default the panel answers over live work in the projects the sidebar is showing")
    func theDefaultIsLiveAndVisible() {
        let listing = build()
        #expect(listing.rows.map(\.id) == ["workspace:docs here", "transcript:docs here"])
        // The hidden project's workspace is not counted either, so no chip offers a number that
        // pressing it could not produce.
        #expect(listing.counts.workspaces == 1)
        #expect(listing.counts.transcripts == 2)
    }

    /// A hidden project is left out of the archive's tally too, so the widening the card offers is
    /// one the reader can actually act on.
    @Test("a hidden project is out of every count, the archive's included")
    func hiddenIsOutOfTheCountsToo() {
        let listing = build()
        // One archived row plus its eight matches, and nothing from the hidden project.
        #expect(listing.counts.archived == 9)
    }

    // MARK: - Widening

    /// The Archived chip is the way to the archive, and it needs no control of its own because it
    /// was already on the row.
    @Test("the Archived chip reaches the archive and draws it")
    func theArchivedChipWidens() {
        let listing = build(scope: .archived, reach: .reading(scope: .archived, showsHiddenProjects: false))
        #expect(listing.rows.map(\.id) == ["workspace:docs finished", "transcript:docs finished"])
    }

    /// One switch, the sidebar's own, and turning it on widens both lists at once.
    @Test("the sidebar's own switch is what reaches a hidden project")
    func theHiddenSwitchWidens() {
        let listing = build(reach: .reading(scope: .all, showsHiddenProjects: true))
        #expect(listing.rows.map(\.id).contains("workspace:docs tidied"))
        #expect(listing.counts.workspaces == 2)
        #expect(listing.counts.transcripts == 6)
    }

    @Test("the reach a chip asks for is the chip and the preference, and nothing else")
    func whatTheChipAsksFor() {
        #expect(SearchPanelReach.reading(scope: .all, showsHiddenProjects: false) == .live)
        #expect(SearchPanelReach.reading(scope: .archived, showsHiddenProjects: false)
            == SearchPanelReach(archived: true))
        #expect(SearchPanelReach.reading(scope: .transcripts, showsHiddenProjects: true)
            == SearchPanelReach(hidden: true))
    }

    // MARK: - Nothing is lost silently

    /// The narrowing is only safe because this sentence exists. `HomeScope.settle` warns in as
    /// many words that a search of live work alone would refuse to find the archived workspace
    /// somebody is searching for the name of.
    @Test("an empty live answer says how much the archive holds")
    func theCardOffersTheArchive() {
        let listing = SearchPanelResults.build(
            query: "houdini",
            repos: [visible],
            workspaces: [workspace("docs here")],
            archived: [
                workspace("houdini one", state: .archived),
                workspace("houdini two", state: .archived),
            ],
            transcripts: [],
            scope: .all,
            commands: []
        )
        #expect(listing.rows.isEmpty)
        #expect(listing.nothing == .noLiveMatch("houdini", archived: 2))
        let message = listing.nothing?.message ?? ""
        #expect(message.contains("houdini"))
        // The count and the noun separately, so this does not depend on which space is
        // between them: `SearchPanelNothingTests` is what holds that.
        #expect(message.contains("2"))
        #expect(message.contains("archived workspaces do"))
    }

    /// Thirteen of the owner's seventeen projects are hidden, so an answer that quietly leaves
    /// them out is leaving out most of his machine. Without this nothing would say so.
    @Test("an empty answer says how many projects it left out")
    func theCardNamesTheHiddenProjects() {
        let listing = SearchPanelResults.build(
            query: "houdini",
            repos: [visible, tidied],
            workspaces: [workspace("docs here")],
            archived: [],
            transcripts: [],
            scope: .all,
            commands: []
        )
        #expect(listing.nothing == .noHiddenMatch("houdini", hidden: 1))
        let message = listing.nothing?.message ?? ""
        #expect(message.contains("houdini"))
        #expect(message.contains("1"))
        #expect(message.contains("hidden project is left out"))
        // Not "were not searched". The store's index has no idea which projects the sidebar is
        // showing, so they are searched and then dropped from the answer and from every count.
        #expect(!message.contains("searched"))
    }

    /// The archive names matches that are known to exist; the hidden count names projects that may
    /// hold nothing. Given one sentence, the certainty is worth more than the possibility.
    @Test("the archive outranks the hidden projects when both would speak")
    func theArchiveOutranksTheHiddenProjects() {
        let listing = SearchPanelResults.build(
            query: "houdini",
            repos: [visible, tidied],
            workspaces: [workspace("docs here")],
            archived: [workspace("houdini one", state: .archived)],
            transcripts: [],
            scope: .all,
            commands: []
        )
        #expect(listing.nothing == .noLiveMatch("houdini", archived: 1))
    }

    /// Turning the sidebar's switch on leaves nothing held back on that axis, so the sentence goes
    /// with it rather than reporting projects that are in the answer.
    @Test("a widened reach has no hidden projects to name")
    func nothingLeftOutIsNotNamed() {
        let listing = SearchPanelResults.build(
            query: "houdini",
            repos: [visible, tidied],
            workspaces: [workspace("docs here")],
            archived: [],
            transcripts: [],
            scope: .all,
            commands: [],
            reach: SearchPanelReach(hidden: true)
        )
        #expect(listing.nothing == .noMatch("houdini"))
    }

    /// Nothing anywhere is a different sentence from nothing live, and the archive is not offered
    /// when the reader is already looking at it.
    @Test("nothing anywhere, and nothing left to offer, say the plain thing")
    func thePlainNothing() {
        let nowhere = SearchPanelResults.build(
            query: "houdini",
            repos: [visible],
            workspaces: [workspace("docs here")],
            archived: [],
            transcripts: [],
            scope: .all,
            commands: []
        )
        // `[visible]` alone, so nothing is held back on either axis and "Nothing in Bloom
        // matches" is the true sentence rather than an overclaim.
        #expect(nowhere.nothing == .noMatch("houdini"))

        let alreadyThere = SearchPanelResults.build(
            query: "houdini",
            repos: [visible],
            workspaces: [workspace("docs here")],
            archived: [workspace("nothing like it", state: .archived)],
            transcripts: [],
            scope: .archived,
            commands: [],
            reach: SearchPanelReach(archived: true)
        )
        #expect(alreadyThere.nothing == .noMatch("houdini"))
    }

    // MARK: - The resting list obeys it too

    /// The two lists have to agree about what exists, or the resting list would offer a workspace
    /// that typing its name then refuses to find.
    @Test("the resting list leaves out the projects the search would leave out")
    func theRestingListObeys() {
        let listing = SearchPanelResting.build(
            workspaces: [
                workspace("docs here"),
                workspace("docs tidied", repoID: RepoID("tidied")),
            ],
            repos: [visible, tidied],
            activity: HomeActivity()
        )
        #expect(listing.rows.map(\.id) == ["workspace:docs here"])
        #expect(listing.summary == "1 workspace")

        let widened = SearchPanelResting.build(
            workspaces: [
                workspace("docs here"),
                workspace("docs tidied", repoID: RepoID("tidied")),
            ],
            repos: [visible, tidied],
            activity: HomeActivity(),
            reach: SearchPanelReach(hidden: true)
        )
        #expect(widened.rows.count == 2)
    }
}
