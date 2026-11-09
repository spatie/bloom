import Foundation
import Testing
@testable import BloomCore

/// When Home's view tree exists. The crash it is kept alive for is on `HomePresence`: leaving Home
/// during a live resize tore its `List` down while AppKit was still asking it for rows.
@Suite("Home's presence in the detail column")
struct HomePresenceTests {
    private let workspace = SidebarSelection.workspace(WorkspaceID("w1"))

    @Test("Home is mounted and presented while it is selected")
    func selectedHomeIsPresented() {
        var presence = HomePresence()
        presence.select(.home)
        #expect(presence.isMounted(for: .home))
        #expect(HomePresence.isPresented(.home))
    }

    /// The fix. Leaving Home must not remove its tree, because removing it is what aborted.
    @Test("leaving Home keeps it mounted, behind the pane that replaced it")
    func leavingHomeKeepsItMounted() {
        var presence = HomePresence()
        presence.select(.home)
        presence.select(workspace)
        #expect(presence.isMounted(for: workspace))
        #expect(!HomePresence.isPresented(workspace))
        presence.select(.mail)
        #expect(presence.isMounted(for: .mail))
    }

    /// A window that opens on a workspace and never goes to Home should not build a list of every
    /// workspace on the machine for nothing.
    @Test("Home is not built before its first visit")
    func neverVisitedIsNotMounted() {
        var presence = HomePresence()
        presence.select(workspace)
        #expect(!presence.isMounted(for: workspace))
        #expect(!presence.hasVisited)
    }

    /// The first frame of a visit, before `select` has heard about it. The pane has to be there on
    /// that frame or the window draws nothing where Home should be.
    @Test("Home is mounted on the frame it is selected, before the visit is recorded")
    func mountedBeforeVisitIsRecorded() {
        let presence = HomePresence()
        #expect(presence.isMounted(for: .home))
    }
}
