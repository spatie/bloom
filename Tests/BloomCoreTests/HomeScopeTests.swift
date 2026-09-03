import Foundation
import Testing
@testable import BloomCore

/// The chips on Home's strip: which set is offered, what each lets through, and what happens when
/// a search starts and ends.
///
/// This is the one rule where there used to be three. Home had a search field and a "Hide
/// archived" switch, the Search screen had a field of its own with a second layout and a second
/// keyboard model, and the Archive screen listed the archived workspaces a third time. All of them
/// asked the same question of the same list.
@Suite("Home's scopes")
struct HomeScopeTests {
    private func workspace(
        _ name: String,
        repoID: RepoID = RepoID("repo"),
        state: WorkspaceState = .active,
        unread: Bool = false
    ) -> Workspace {
        Workspace(
            id: WorkspaceID(name),
            repoID: repoID,
            name: name,
            branch: "feature/\(name)",
            path: "/tmp/\(name)",
            baseBranch: "main",
            state: state,
            lastActivityAt: Date(timeIntervalSince1970: 1_000),
            unread: unread
        )
    }

    private func row(_ workspace: Workspace) -> HomeRow {
        HomeRow(workspace: workspace, repo: Repo(id: workspace.repoID, name: "repo", path: "/tmp"))
    }

    // MARK: - Which chips are on offer

    /// Browsing narrows the rows by what is happening in them; searching narrows the answer by
    /// what kind of thing matched. Two questions, two sets.
    @Test("the two sets share exactly one chip, and it is the widest one")
    func theSetsShareOnlyAll() {
        let browsing = Set(HomeScope.offered(searching: false))
        let searching = Set(HomeScope.offered(searching: true))
        #expect(browsing.contains(.all))
        #expect(searching.contains(.all))
        #expect(browsing.contains(.archived))
        #expect(searching.contains(.archived))
        #expect(!browsing.contains(.transcripts))
        #expect(!searching.contains(.running))
    }

    /// "All 47" and "Everything 41" are the same chip. In a search the count is over two kinds of
    /// result rather than over rows, and the word has to say so.
    @Test("the resting chip is called All while browsing and Everything in a search")
    func theRestingChipIsRenamed() {
        #expect(HomeScope.all.label(searching: false) == "All")
        #expect(HomeScope.all.label(searching: true) == "Everything")
        #expect(HomeScope.archived.label(searching: false) == "Archived")
        #expect(HomeScope.archived.label(searching: true) == "Archived")
    }

    /// A chip that is not on offer in the set being drawn would leave a list showing nothing with
    /// no control on screen explaining why.
    @Test("a chip that is not on offer falls back to the resting one")
    func aScopeThatIsNotOfferedSettles() {
        #expect(HomeScope.settle(.running, searching: true) == .all)
        #expect(HomeScope.settle(.transcripts, searching: false) == .all)
        #expect(HomeScope.settle(.all, searching: true) == .all)
    }

    /// Home opens on live work, because it is what somebody sees on launch and the question they
    /// arrive with is what needs them, not what is finished. A search opens on everything, because
    /// a search narrowed by default answers a question nobody asked.
    @Test("Home rests on Live, and a search rests on Everything")
    func theRestingScopeIsLive() {
        #expect(HomeScope.resting(searching: false) == .all)
        #expect(HomeScope.resting(searching: true) == .all)
        #expect(HomeFilter().scope == .all)
    }

    /// The default leads, because a strip whose first chip is one nobody wants selected reads as a
    /// strip you have to correct. Its two subsets follow it, then the other half of the machine,
    /// then the widest net.
    @Test("Live leads the browsing chips and All closes them")
    func liveLeadsTheStrip() {
        // Two, not five. See `offered`: the three that went were each a true fact drawn as a
        // control nobody pressed, and `needsYou` is the one to bring back if it is missed.
        #expect(HomeScope.offered(searching: false) == [.all, .archived])
        #expect(HomeScope.offered(searching: true).first == .all)
    }

    /// A search of live work alone would refuse to find the archived workspace somebody is
    /// searching for the name of.
    @Test("Live widens to everything when a search starts")
    func liveWidensIntoASearch() {
        #expect(HomeScope.settle(.live, searching: true) == .all)
    }

    /// Somebody who narrowed to finished work and then typed a name is still asking about finished
    /// work, so this one chip survives the crossing in both directions.
    @Test("Archived survives a search starting and ending")
    func archivedSurvivesTheCrossing() {
        #expect(HomeScope.settle(.archived, searching: true) == .archived)
        #expect(HomeScope.settle(.archived, searching: false) == .archived)
    }

    // MARK: - What each chip lets through

    @Test("each chip lets through what its name says")
    func eachScopeLetsThroughWhatItSays() {
        let live = row(workspace("live"))
        let unread = row(workspace("unread", unread: true))
        let running = row(workspace("running"))
        let archived = row(workspace("gone", state: .archived))
        let activity = HomeActivity(
            running: [running.id], waiting: [WorkspaceID("asking")]
        )

        #expect(HomeScope.all.includes(archived, activity: activity))
        #expect(HomeScope.live.includes(live, activity: activity))
        #expect(!HomeScope.live.includes(archived, activity: activity))
        #expect(HomeScope.archived.includes(archived, activity: activity))
        #expect(!HomeScope.archived.includes(live, activity: activity))
        #expect(HomeScope.running.includes(running, activity: activity))
        #expect(!HomeScope.running.includes(live, activity: activity))
        #expect(HomeScope.needsYou.includes(unread, activity: activity))
        #expect(!HomeScope.needsYou.includes(live, activity: activity))
        // A transcript chip is about the other half of the pane, so no workspace row is in it.
        #expect(!HomeScope.transcripts.includes(live, activity: activity))
    }

    /// An agent that has stopped to ask is waiting on a person just as squarely as a turn nobody
    /// has read, and both are what the chip is for.
    @Test("Needs you covers a question asked and a turn unread")
    func needsYouCoversBoth() {
        let asking = workspace("asking")
        let unread = workspace("unread", unread: true)
        let activity = HomeActivity(waiting: [asking.id])
        #expect(activity.needsYou(asking))
        #expect(activity.needsYou(unread))
        #expect(!activity.needsYou(workspace("quiet")))
    }

    /// An archived workspace's `unread` is a leftover with nothing behind it: nothing draws it,
    /// the Dock badge does not count it, and the two states say opposite things about the same row.
    @Test("an archived workspace never needs you, whatever its unread flag says")
    func archivedNeverNeedsYou() {
        let stale = workspace("gone", state: .archived, unread: true)
        #expect(!HomeActivity(waiting: [stale.id]).needsYou(stale))
    }

    // MARK: - The counts

    /// Finder's scope bar behaviour: a count that changed when you clicked it would be a count of
    /// the thing you are already looking at.
    @Test("every chip counts what clicking it would show, whichever chip is lit")
    func countsIgnoreTheSelectedChip() {
        let workspaces = [
            workspace("running"),
            workspace("unread", unread: true),
            workspace("quiet"),
        ]
        let archived = [workspace("gone", state: .archived)]
        let activity = HomeActivity(running: [WorkspaceID("running")])

        for scope in HomeScope.offered(searching: false) {
            let listing = HomeList.build(
                repos: [Repo(id: RepoID("repo"), name: "repo", path: "/tmp")],
                workspaces: workspaces,
                archived: archived,
                filter: HomeFilter(scope: scope),
                activity: activity
            )
            #expect(listing.counts.live == 3)
            #expect(listing.counts.archived == 1)
            #expect(listing.counts.running == 1)
            #expect(listing.counts.needsYou == 1)
            #expect(listing.counts.count(of: .all, searching: false) == 4)
        }
    }

    /// The resting strip read "Needs you 0, Running 0", which is two facts stated in the least
    /// useful way there is: the noughts are the state most of the time, so they are what the eye
    /// learns to skip, and the numbers beside them get skipped with them.
    @Test("a chip at nought draws no number")
    func aNoughtDrawsNoNumber() {
        var counts = HomeScopeCounts()
        counts.live = 3
        counts.archived = 17
        // Only the two chips whose number is a size. Live's three is a state, and the list under
        // the strip already says it.
        #expect(counts.badge(of: .archived, searching: false) == 17)
        #expect(counts.badge(of: .all, searching: false) == 20)
        #expect(counts.badge(of: .live, searching: false) == nil)
        #expect(counts.badge(of: .needsYou, searching: false) == nil)
        #expect(counts.badge(of: .running, searching: false) == nil)
        // And the two that do keep a number still drop it at nought.
        #expect(HomeScopeCounts().badge(of: .all, searching: false) == nil)
        #expect(HomeScopeCounts().badge(of: .archived, searching: false) == nil)
    }

    /// The project menu narrows what the chips count, because it narrows what clicking one would
    /// show. That is the one narrowing a chip's number is under.
    @Test("the project filter is inside the counts")
    func theProjectFilterIsInsideTheCounts() {
        let listing = HomeList.build(
            repos: [
                Repo(id: RepoID("a"), name: "a", path: "/tmp/a"),
                Repo(id: RepoID("b"), name: "b", path: "/tmp/b"),
            ],
            workspaces: [
                workspace("one", repoID: RepoID("a")),
                workspace("two", repoID: RepoID("b")),
            ],
            archived: [],
            filter: HomeFilter(projects: [RepoID("a")])
        )
        #expect(listing.counts.live == 1)
        #expect(listing.shown == 1)
        // And the total the readout narrows FROM is still every workspace on the machine.
        #expect(listing.considered == 2)
    }
}
