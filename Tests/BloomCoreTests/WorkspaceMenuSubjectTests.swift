import Testing
@testable import BloomCore

/// The menu bar going dead against a row that is visibly highlighted.
///
/// Home's selection is `.home` and the Archive's is `.archive`, so every item in the Workspace menu
/// greyed out on both screens while the user was pointing at the workspace it names.
@Suite("What the Workspace menu acts on")
struct WorkspaceMenuSubjectTests {
    private let live = WorkspaceID("workspace-1")
    private let other = WorkspaceID("workspace-2")

    @Test("a selected workspace answers, with no list focused")
    func selectionAnswers() {
        #expect(
            WorkspaceMenuSubject.resolve(selection: .workspace(live), focusedRow: nil)
                == .live(live)
        )
        #expect(
            WorkspaceMenuSubject.resolve(selection: .archived(live), focusedRow: nil)
                == .archived(live)
        )
    }

    /// The whole point: on Home and in the Archive the highlighted row is what the menu means.
    @Test("a highlighted row answers on the screens that have no workspace selected")
    func focusedRowAnswers() {
        for selection in [SidebarSelection.home, .search, .archive] {
            #expect(
                WorkspaceMenuSubject.resolve(
                    selection: selection,
                    focusedRow: .init(id: live, isArchived: false)
                ) == .live(live)
            )
        }
    }

    @Test("an archived row is not offered as a live one")
    func archivedRow() {
        #expect(
            WorkspaceMenuSubject.resolve(
                selection: .home, focusedRow: .init(id: live, isArchived: true)
            ) == .archived(live)
        )
    }

    /// A subagent selection is a workspace selection, which is what keeps the menu pointed at the
    /// parent while a child's transcript is being read.
    @Test("reading a subagent still acts on its workspace")
    func subagent() {
        let subagent = SubagentID("subagent-1")
        #expect(
            WorkspaceMenuSubject.resolve(selection: .subagent(live, subagent), focusedRow: nil)
                == .live(live)
        )
    }

    /// The precedence, which exists so that a focused value published a frame after its screen was
    /// left cannot aim the menu at a row nobody can see.
    @Test("a selected workspace wins over a row left behind by another screen")
    func selectionWins() {
        #expect(
            WorkspaceMenuSubject.resolve(
                selection: .workspace(live), focusedRow: .init(id: other, isArchived: false)
            ) == .live(live)
        )
    }

    @Test("nothing selected and nothing highlighted is nothing to act on")
    func nothing() {
        #expect(WorkspaceMenuSubject.resolve(selection: .home, focusedRow: nil) == nil)
    }

    @Test("a live workspace answers to everything but Restore")
    func liveActions() {
        let subject = WorkspaceMenuSubject.live(live)
        for action in WorkspaceMenuAction.allCases where action != .restore {
            #expect(subject.allows(action), "\(action)")
        }
        #expect(!subject.allows(.restore))
        #expect(subject.liveID == live)
        #expect(subject.archivedID == nil)
    }

    /// An archived workspace has no worktree, so the four items that touch the disk are refused
    /// and the two that read the database are not.
    @Test("an archived workspace answers only to Restore and Copy Branch Name")
    func archivedActions() {
        let subject = WorkspaceMenuSubject.archived(live)
        #expect(subject.allows(.restore))
        #expect(subject.allows(.copyBranchName))
        #expect(!subject.allows(.archive))
        #expect(!subject.allows(.openInEditor))
        #expect(!subject.allows(.revealInFinder))
        #expect(!subject.allows(.rename))
        #expect(subject.liveID == nil)
        #expect(subject.archivedID == live)
        #expect(subject.id == live)
    }
}
