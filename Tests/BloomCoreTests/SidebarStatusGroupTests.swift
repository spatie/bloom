import Foundation
import Testing
@testable import BloomCore

/// What the pane looks like when it is sorted by what each workspace needs.
///
/// The rule worth the suite is the last block: a selected row keeps its section. Everything in the
/// pane that moves a row between sections (reading it, answering it, an agent finishing) happens
/// while somebody is looking at that row, and a list that reorders itself under the pointer is the
/// failure this was built to avoid.
@Suite("Sidebar status grouping")
struct SidebarStatusGroupTests {
    private func workspace(_ id: String) -> Workspace {
        Workspace(
            id: WorkspaceID(id),
            repoID: RepoID("r1"),
            name: id,
            branch: "bloom/\(id)",
            path: "/tmp/\(id)",
            baseBranch: "main"
        )
    }

    // MARK: - Which section a state lands in

    @Test func aPermissionQuestionAndAFailedSetupBothWantAPerson() {
        #expect(SidebarStatusGroup.of(.awaitingPermission) == .needsYou)
        #expect(SidebarStatusGroup.of(.setupFailed) == .needsYou)
    }

    @Test func aFinishedTurnNobodyHasReadRanksAboveOneStillRunning() throws {
        #expect(SidebarStatusGroup.of(.unread) == .readyToRead)
        #expect(SidebarStatusGroup.of(.running) == .working)

        let order = SidebarStatusGroup.allCases
        let read = try #require(order.firstIndex(of: .readyToRead))
        let working = try #require(order.firstIndex(of: .working))
        #expect(read < working)
    }

    @Test func cuttingAWorktreeCountsAsWorking() {
        #expect(SidebarStatusGroup.of(.settingUp) == .working)
    }

    /// Every state GitHub can report is one thing to the queue: not now.
    @Test func everyPullRequestStateIsIdle() {
        let states: [WorkspaceStatus] = [
            .merged, .closed, .conflicted, .checksFailing, .checksRunning, .checksPassed, .draft,
            .pullRequestOpen, .changed, .clean,
        ]
        for state in states {
            #expect(SidebarStatusGroup.of(state) == .idle, "\(state) should be idle")
        }
    }

    @Test func everyStateHasASection() {
        for status in WorkspaceStatus.allCases {
            _ = SidebarStatusGroup.of(status)
        }
    }

    // MARK: - The listing

    @Test func emptySectionsAreNotDrawn() {
        let listing = SidebarStatusListing.build(
            workspaces: [workspace("a")], status: { _ in .clean }
        )
        #expect(listing.sections.map(\.group) == [.idle])
    }

    @Test func sectionsComeInTheOrderTheCasesAreDeclaredIn() {
        let rows = [workspace("idle"), workspace("run"), workspace("ask"), workspace("unread")]
        let listing = SidebarStatusListing.build(workspaces: rows) { workspace in
            switch workspace.id.rawValue {
            case "run": .running
            case "ask": .awaitingPermission
            case "unread": .unread
            default: .clean
            }
        }
        #expect(listing.sections.map(\.group) == [.needsYou, .readyToRead, .working, .idle])
    }

    /// The order the pane already draws projects and their rows in is kept inside each section, so
    /// a section of six reads project by project rather than in an order nobody chose.
    @Test func rowsKeepTheOrderTheyWereHandedIn() {
        let rows = [workspace("a"), workspace("b"), workspace("c")]
        let listing = SidebarStatusListing.build(workspaces: rows, status: { _ in .clean })
        #expect(listing.sections.first?.workspaces.map(\.id.rawValue) == ["a", "b", "c"])
    }

    // MARK: - The selected row stays put

    @Test func readingTheSelectedRowDoesNotMoveIt() {
        let rows = [workspace("a"), workspace("b")]
        // "a" was unread when it was selected, and reading it has just made it clean.
        let listing = SidebarStatusListing.build(
            workspaces: rows,
            status: { _ in .clean },
            stuck: .init(id: WorkspaceID("a"), group: .readyToRead)
        )
        #expect(listing.sections.map(\.group) == [.readyToRead, .idle])
        #expect(listing.sections.first?.workspaces.map(\.id.rawValue) == ["a"])
    }

    @Test func aTurnEndingUnderThePointerLeavesTheRowWhereItWas() {
        let listing = SidebarStatusListing.build(
            workspaces: [workspace("a")],
            status: { _ in .unread },
            stuck: .init(id: WorkspaceID("a"), group: .working)
        )
        #expect(listing.sections.map(\.group) == [.working])
    }

    @Test func everyOtherRowSettlesWhereItsStateSaysEvenWhileOneIsHeld() {
        let listing = SidebarStatusListing.build(
            workspaces: [workspace("held"), workspace("free")],
            status: { _ in .unread },
            stuck: .init(id: WorkspaceID("held"), group: .idle)
        )
        #expect(listing.sections.map(\.group) == [.readyToRead, .idle])
        #expect(listing.sections.first?.workspaces.map(\.id.rawValue) == ["free"])
    }

    @Test func aHeldRowThatIsNoLongerInThePaneHoldsNothing() {
        let listing = SidebarStatusListing.build(
            workspaces: [workspace("a")],
            status: { _ in .running },
            stuck: .init(id: WorkspaceID("gone"), group: .needsYou)
        )
        #expect(listing.sections.map(\.group) == [.working])
    }

    // MARK: - Folding

    @Test func onlyIdleFolds() {
        #expect(SidebarStatusGroup.idle.isFoldable)
        for group in SidebarStatusGroup.allCases where group != .idle {
            #expect(!group.isFoldable, "\(group) should not fold")
        }
    }

    // MARK: - Grouping

    @Test func onlyTheProjectShapeCanBeReordered() {
        #expect(SidebarGrouping.projects.allowsReordering)
        #expect(!SidebarGrouping.status.allowsReordering)
    }
}

/// Which states keep a mark at rest, and which lost one.
@Suite("Sidebar mark policy")
struct SidebarMarkPolicyTests {
    @Test func aRestingRowOnlyMarksWorkAndAnswers() {
        for status in [WorkspaceStatus.settingUp, .awaitingPermission, .running, .setupFailed, .unread] {
            #expect(SidebarMarkPolicy.drawsMark(status), "\(status) should keep its mark")
        }
    }

    /// The two branch states a person has to clear by hand, which nothing else in the pane says.
    @Test func brokenBranchesKeepTheirMark() {
        #expect(SidebarMarkPolicy.drawsMark(.checksFailing))
        #expect(SidebarMarkPolicy.drawsMark(.conflicted))
    }

    @Test func aStateThatWantsNothingDrawsNothing() {
        let quiet: [WorkspaceStatus] = [
            .merged, .closed, .checksRunning, .checksPassed, .draft, .pullRequestOpen, .changed,
            .clean,
        ]
        for status in quiet {
            #expect(!SidebarMarkPolicy.drawsMark(status), "\(status) should rest")
        }
    }
}
