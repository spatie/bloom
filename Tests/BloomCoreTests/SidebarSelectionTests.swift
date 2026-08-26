import Testing
@testable import BloomCore

/// What the sidebar points at, which is what the whole window is about.
///
/// It lived beside `AppModel` in the app target, so none of this could be asserted. The last test
/// is the one that matters: an archived workspace and a live one with the same id are different
/// selections, and anything that treated them as one would reopen a workspace whose worktree has
/// been deleted as though it were still there.
@Suite("Sidebar selection")
struct SidebarSelectionTests {
    private let workspace = WorkspaceID("w1")
    private let subagent = SubagentID("s1")

    /// A subagent selection IS a workspace selection. The terminal, the diff, the composer, the
    /// toolbar and the Workspace menu all hang off `workspaceID`, and every one of them is still
    /// about the parent while a child's transcript is being read.
    @Test("a subagent carries its workspace")
    func aSubagentIsAWorkspaceSelection() {
        #expect(SidebarSelection.subagent(workspace, subagent).workspaceID == workspace)
        #expect(SidebarSelection.subagent(workspace, subagent).subagentID == subagent)
        #expect(SidebarSelection.workspace(workspace).subagentID == nil)
    }

    /// An archived workspace is not a workspace the window can act on, so it is deliberately not
    /// reachable through `workspaceID`. That absence is what makes the inspector hide itself, the
    /// menu items grey and the background refresh skip it, with no extra code anywhere.
    @Test("an archived workspace is not reachable as a live one")
    func archivedIsNotLive() {
        #expect(SidebarSelection.archived(workspace).workspaceID == nil)
        #expect(SidebarSelection.archived(workspace).archivedWorkspaceID == workspace)
        #expect(SidebarSelection.workspace(workspace).archivedWorkspaceID == nil)
    }

    /// One case, where there were three. Search and Archive were destinations of their own and
    /// both drew the same list of workspaces Home already draws.
    @Test("Home carries no workspace at all")
    func homeCarriesNothing() {
        #expect(SidebarSelection.home.workspaceID == nil)
        #expect(SidebarSelection.home.archivedWorkspaceID == nil)
        #expect(SidebarSelection.home.subagentID == nil)
    }

    /// Everything that hangs off `workspaceID` gets the right answer for a conversation with no
    /// worktree for free: no inspector, no terminal, no diff poll, no pull request accessory, and
    /// a Workspace menu that greys itself. Exactly the fall-out `.home` gets, which is what it
    /// should be, because neither of them is a worktree.
    @Test("Ask Bloom carries no workspace either, and is not Home")
    func askCarriesNothing() {
        #expect(SidebarSelection.ask.workspaceID == nil)
        #expect(SidebarSelection.ask.archivedWorkspaceID == nil)
        #expect(SidebarSelection.ask.subagentID == nil)
        // Two destinations, so a window on one must never be treated as being on the other.
        #expect(SidebarSelection.ask != .home)
        #expect(Set<SidebarSelection>([.ask, .home]).count == 2)
    }

    /// The one that stops an archived workspace being reopened as a live one. Same id, two cases,
    /// and they must not be equal or share a hash: a dictionary or a `Set` keyed on a selection
    /// would otherwise answer for the wrong one.
    @Test("the same id archived and live are different selections")
    func archivedAndLiveDoNotCollide() {
        #expect(SidebarSelection.workspace(workspace) != .archived(workspace))
        #expect(
            SidebarSelection.workspace(workspace).hashValue
                != SidebarSelection.archived(workspace).hashValue
        )
        #expect(Set<SidebarSelection>([.workspace(workspace), .archived(workspace)]).count == 2)
    }

    @Test("two subagents of one workspace are different selections")
    func subagentsDoNotCollide() {
        let other = SubagentID("s2")
        #expect(SidebarSelection.subagent(workspace, subagent) != .subagent(workspace, other))
        #expect(SidebarSelection.subagent(workspace, subagent) != .workspace(workspace))
    }
}
