import Testing
@testable import BloomCore

@Suite("Dock badge")
struct DockBadgeTests {
    private func workspace(
        id: String, unread: Bool
    ) -> Workspace {
        Workspace(
            id: id,
            repoID: RepoID("repo"),
            name: id,
            branch: "feature/\(id)",
            path: "/tmp/\(id)",
            baseBranch: "main",
            unread: unread
        )
    }

    @Test("counts the workspaces holding something nobody has read")
    func countsUnread() {
        let workspaces = [
            workspace(id: "a", unread: true),
            workspace(id: "b", unread: false),
            workspace(id: "c", unread: true),
        ]

        #expect(DockBadge.unreadCount(in: workspaces, isRunning: { _ in false }) == 2)
    }

    @Test("a workspace whose agent is off again is not waiting on anybody")
    func skipsRunning() {
        let workspaces = [
            workspace(id: "a", unread: true),
            workspace(id: "b", unread: true),
        ]

        let count = DockBadge.unreadCount(in: workspaces, isRunning: { $0.id == "b" })

        #expect(count == 1)
    }

    @Test("counts workspaces rather than what is inside them")
    func countsWorkspacesNotSessions() {
        // One workspace, however many sessions ran in it, is one row in the sidebar and one thing
        // to go and read.
        let workspaces = [workspace(id: "a", unread: true)]

        #expect(DockBadge.unreadCount(in: workspaces, isRunning: { _ in false }) == 1)
    }

    @Test("nothing unread is no badge, not a zero")
    func zeroIsNoBadge() {
        #expect(DockBadge.label(unread: 0, isEnabled: true) == nil)
    }

    @Test("the badge says the count when there is one")
    func labelsTheCount() {
        #expect(DockBadge.label(unread: 3, isEnabled: true) == "3")
    }

    @Test("switched off there is no badge, whatever the count")
    func disabledIsNoBadge() {
        #expect(DockBadge.label(unread: 7, isEnabled: false) == nil)
    }
}
