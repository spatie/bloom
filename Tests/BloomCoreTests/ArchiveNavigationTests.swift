import Testing
@testable import BloomCore

/// Where the window goes when a workspace is archived.
///
/// The bug these are written against: confirming an archive took the row out of the sidebar at
/// once and left the workspace itself filling the centre column for another two or three seconds,
/// until `git worktree remove` had finished walking the worktree. The decision was already taken,
/// the sidebar already said so, and the rest of the window sat there.
///
/// Moving the window is the easy half. The reason this is a value in the core rather than a line
/// inside the archive is the other half: it also has to refuse to move it, for somebody who picked
/// another workspace while the disk was still working, and for the second time one archive asks.
@Suite("Archive navigation")
struct ArchiveNavigationTests {
    private let archived = WorkspaceID("w1")
    private let other = WorkspaceID("w2")

    @Test("the window on the archived workspace goes to Home")
    func theOpenWorkspaceLeaves() {
        #expect(
            ArchiveNavigation.destination(
                leaving: .workspace(archived), archiving: archived
            ) == .home
        )
    }

    /// A subagent and a crew member both live in the worktree that is being deleted, and both
    /// answer `workspaceID` with it. Reading either while its workspace is archived would leave
    /// the window on a transcript belonging to a directory that no longer exists.
    @Test("a child of the archived workspace leaves with it")
    func childrenLeaveToo() {
        let subagent = SidebarSelection.subagent(archived, SubagentID("s1"))
        let crew = SidebarSelection.crew(archived, SessionID("c1"))
        #expect(ArchiveNavigation.destination(leaving: subagent, archiving: archived) == .home)
        #expect(ArchiveNavigation.destination(leaving: crew, archiving: archived) == .home)
    }

    /// The whole point of the guard. Cleanup runs for seconds, and somebody who moves to another
    /// workspace while it finishes must not be dragged to Home when it does. Their children stay
    /// as well, for the same reason they leave above: those are about a worktree nobody is
    /// deleting.
    @Test("a window that moved to another workspace stays there")
    func anotherWorkspaceIsLeftAlone() {
        #expect(ArchiveNavigation.destination(leaving: .workspace(other), archiving: archived) == nil)
        #expect(
            ArchiveNavigation.destination(
                leaving: .subagent(other, SubagentID("s1")), archiving: archived
            ) == nil
        )
        #expect(
            ArchiveNavigation.destination(
                leaving: .crew(other, SessionID("c1")), archiving: archived
            ) == nil
        )
    }

    /// Nil rather than `.home`, and the difference is a write. The caller only assigns when there
    /// is somewhere to go, so archiving from Home's row menu, from Ask Bloom or from the sidebar
    /// while nothing is selected writes nothing to the selection at all.
    @Test("a window on no workspace is not moved")
    func destinationsWithNoWorkspaceAreLeftAlone() {
        #expect(ArchiveNavigation.destination(leaving: .home, archiving: archived) == nil)
        #expect(ArchiveNavigation.destination(leaving: .ask, archiving: archived) == nil)
    }

    /// An archived workspace open for reading is not a workspace being archived: its worktree
    /// went long ago, and what closes that reader is deleting the record, which `deleteArchived`
    /// does and says so. Archiving `w1` while `w1`'s own archived transcript is on screen cannot
    /// happen, and if it ever did the reader would still be readable.
    @Test("the archived reader is not what this moves")
    func theArchivedReaderStays() {
        #expect(ArchiveNavigation.destination(leaving: .archived(archived), archiving: archived) == nil)
    }

    /// Asked twice by one archive, once when the row leaves the sidebar and once when git has
    /// finished, and the second answer has to be nil or it would move a window that has already
    /// been moved. That is what makes the second call safe to keep as a guard.
    @Test("asking again after the window has left answers nothing")
    func askingTwiceMovesOnce() {
        var selection = SidebarSelection.workspace(archived)
        if let first = ArchiveNavigation.destination(leaving: selection, archiving: archived) {
            selection = first
        }
        #expect(selection == .home)
        #expect(ArchiveNavigation.destination(leaving: selection, archiving: archived) == nil)
    }
}
