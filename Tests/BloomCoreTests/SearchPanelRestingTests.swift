import Foundation
import Testing
@testable import BloomCore

/// What the panel shows before anything has been typed: what is waiting on you, then what you last
/// had open, both capped.
///
/// The dates here are built rather than read off the clock, for the reason `HomeListTests` gives:
/// a suite that says "an hour ago" against `Date()` is a suite whose ordering is decided by when
/// it ran.
@Suite("Search panel resting list")
struct SearchPanelRestingTests {
    private func workspace(
        _ name: String,
        at activity: Date,
        unread: Bool = false,
        repoID: RepoID = RepoID("repo")
    ) -> Workspace {
        Workspace(
            id: WorkspaceID(name),
            repoID: repoID,
            name: name,
            branch: "feature/\(name)",
            path: "/tmp/\(name)",
            baseBranch: "main",
            lastActivityAt: activity,
            unread: unread
        )
    }

    private func date(_ minutesAgo: Int) -> Date {
        Date(timeIntervalSince1970: 1_700_000_000 - Double(minutesAgo) * 60
        )
    }

    private let repo = Repo(id: RepoID("repo"), name: "bloom", path: "/tmp/repo")

    /// Somebody running eight agents opens this panel already wanting to know which one wants
    /// them, so that question is answered before they type.
    @Test("the workspaces waiting on you lead, under their own heading")
    func waitingLeads() {
        let asking = workspace("docs chapters", at: date(4))
        let finished = workspace("appcast signing", at: date(26), unread: true)
        let quiet = workspace("pill caps", at: date(1))

        let listing = SearchPanelResting.build(
            workspaces: [quiet, asking, finished],
            repos: [repo],
            activity: HomeActivity(waiting: [asking.id])
        )

        #expect(listing.sections.map(\.title) == ["Waiting on you", "Recently open"])
        #expect(listing.sections[0].rows.map(\.id) == [
            "workspace:docs chapters", "workspace:appcast signing",
        ])
        #expect(listing.sections[1].rows.map(\.id) == ["workspace:pill caps"])
    }

    /// The two kinds are drawn apart because they mean different things: an agent blocked on an
    /// answer needs you now, where a finished turn is only unread.
    @Test("a blocked agent and a finished turn are told apart")
    func theTwoKindsOfWaiting() {
        let asking = workspace("asking", at: date(1))
        let finished = workspace("finished", at: date(2), unread: true)
        let activity = HomeActivity(waiting: [asking.id])

        #expect(SearchPanelResting.reason(for: asking, activity: activity) == .askedAQuestion)
        #expect(SearchPanelResting.reason(for: finished, activity: activity) == .turnFinished)
        #expect(SearchPanelResting.reason(for: workspace("quiet", at: date(3)), activity: activity) == nil)
        #expect(SearchPanelWaiting.askedAQuestion.label == "asked a question")
        #expect(SearchPanelWaiting.turnFinished.label == "turn finished")
    }

    /// A row cannot be in both sections. Slack's finding is that listing everything is crushing;
    /// listing the same thing twice is worse.
    @Test("a workspace that is waiting is not repeated under what you last had open")
    func noRowAppearsTwice() {
        let asking = workspace("asking", at: date(1))
        let other = workspace("other", at: date(2))
        let listing = SearchPanelResting.build(
            workspaces: [asking, other], repos: [repo], activity: HomeActivity(waiting: [asking.id])
        )
        #expect(listing.rows.count == 2)
        #expect(Set(listing.rows.map(\.id)).count == 2)
    }

    /// The panel is three hundred points of list. An index of the machine put at the top of it
    /// would be a worse Home, reached by a key.
    @Test("both sections cap themselves")
    func bothSectionsCap() {
        let waiting = (0..<9).map { workspace("waiting-\($0)", at: date($0), unread: true) }
        let quiet = (0..<9).map { workspace("quiet-\($0)", at: date(100 + $0)) }
        let listing = SearchPanelResting.build(
            workspaces: waiting + quiet, repos: [repo], activity: HomeActivity()
        )
        #expect(listing.sections[0].rows.count == SearchPanelResting.waitingCap)
        #expect(listing.sections[1].rows.count == SearchPanelResting.recentCap)
    }

    /// With nothing waiting there is only one section, and it says "Recent" rather than "Recently
    /// open", because "open" only means something against the heading that is not there.
    @Test("a quiet machine gets one section")
    func aQuietMachineGetsOneSection() {
        let listing = SearchPanelResting.build(
            workspaces: [workspace("one", at: date(1))], repos: [repo], activity: HomeActivity()
        )
        #expect(listing.sections.map(\.title) == ["Recent"])
        #expect(!listing.isSearching)
    }

    /// Every picture anybody has taken of this panel came off a machine with four projects on it.
    /// A fresh install has none, and Cmd+K works from the moment the app opens.
    @Test("a machine with nothing on it says so rather than drawing an empty card")
    func nothingAtAll() {
        let listing = SearchPanelResting.build(workspaces: [], repos: [], activity: HomeActivity())
        #expect(listing.isEmpty)
        #expect(listing.sections.isEmpty)
        #expect(listing.nothing == .nothingYet)
        // Nothing to count, so the footer says nothing rather than "0 results".
        #expect(listing.summary == nil)
    }

    /// "You have nothing yet" and "your search matched nothing" are two different facts, and a
    /// panel that said the same words to both would be declining to know which it was in.
    @Test("an empty install is told apart from a search that missed")
    func anEmptyInstallIsNotAMissedSearch() {
        let resting = SearchPanelResting.build(workspaces: [], repos: [], activity: HomeActivity())
        #expect(resting.nothing != SearchPanelNothing.noMatch(""))
        #expect(resting.nothing?.title != SearchPanelNothing.noMatch("x").title)
    }

    /// The keyboard on a list with nothing in it. Every one of these is a nil the panel has to
    /// swallow rather than a row to move to.
    @Test("the keyboard does nothing rather than crashing on an empty list")
    func theKeyboardOnAnEmptyList() {
        let listing = SearchPanelResting.build(workspaces: [], repos: [], activity: HomeActivity())
        #expect(listing.row(at: nil) == nil)
        #expect(listing.row(at: 0) == nil)

        let context = SearchPanelKeyContext(rowCount: listing.rows.count, highlighted: nil)
        #expect(SearchPanelKeys.outcome(for: .down, in: context) == .handled)
        #expect(SearchPanelKeys.outcome(for: .up, in: context) == .handled)
        #expect(SearchPanelKeys.outcome(for: .returnKey, in: context) == .handled)
        #expect(SearchPanelKeys.outcome(for: .commandReturn, in: context) == .handled)
        // Tab still walks the chips, whose counts are all nought, rather than being swallowed.
        #expect(SearchPanelKeys.outcome(for: .tab, in: context) == .scope(.workspaces))
        #expect(HomeScopeCounts().count(of: .all, searching: true) == 0)
    }

    /// The project travels with the row because the panel is flat: a row is the only place its
    /// project can be said.
    @Test("a row carries its project")
    func aRowCarriesItsProject() {
        let listing = SearchPanelResting.build(
            workspaces: [workspace("one", at: date(1))], repos: [repo], activity: HomeActivity()
        )
        guard case .workspace(let hit)? = listing.rows.first else {
            Issue.record("expected a workspace row")
            return
        }
        #expect(hit.repo?.name == "bloom")
    }
}
