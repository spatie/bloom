import Foundation
import Testing
@testable import BloomCore

@Suite("Remote workspace availability")
struct RemoteWorkspaceAvailabilityTests {
    @Test("A reset server cannot leave an unknown workspace opening forever")
    func resetServer() {
        #expect(state(connected: false) == .disconnected)
        #expect(state(connected: true, catalogue: true, count: 0) == .empty)
        #expect(state(connected: true, catalogue: true, count: 2) == .missing)
    }

    @Test("Only an actual connection attempt or resolved workspace shows progress")
    func progress() {
        #expect(state(connected: false, connecting: true) == .connecting)
        #expect(state(connected: false, configured: false) == .unconfigured)
        #expect(state(connected: true) == .connecting)
        #expect(state(connected: false, workspace: true) == .opening)
    }

    @Test("A valid cached workspace stays readable during a disconnect")
    func cachedWorkspace() {
        #expect(state(connected: false, workspace: true, model: true) == .ready)
        #expect(state(connected: false, connecting: true, workspace: true, model: true) == .ready)
        #expect(state(connected: false, model: true) == .disconnected)
    }

    private func state(
        connected: Bool, connecting: Bool = false, configured: Bool = true,
        catalogue: Bool = false, count: Int = 0, workspace: Bool = false, model: Bool = false
    ) -> RemoteWorkspaceAvailability {
        .resolve(hasWorkspace: workspace, hasModel: model, isConfigured: configured,
                 isConnected: connected, isConnecting: connecting, hasCatalogue: catalogue, workspaceCount: count)
    }
}

@Suite("Remote sidebar selection memory")
struct RemoteSidebarSelectionMemoryTests {
    @Test("Home clears both legacy remote keys without deleting local history or drafts")
    func homeClearsRemoteMemory() throws {
        try withDefaults { defaults in
            defaults.set("local", forKey: SidebarSelectionMemory.localWorkspaceKey)
            defaults.set("stale-workspace", forKey: SidebarSelectionMemory.remoteWorkspaceKey)
            defaults.set("stale-session", forKey: SidebarSelectionMemory.remoteSessionKey)
            defaults.set("unsent text", forKey: "server.drafts")
            SidebarSelectionMemory.remember(.home, in: defaults)
            #expect(SidebarSelectionMemory.savedRemote(in: defaults) == nil)
            #expect(defaults.string(forKey: SidebarSelectionMemory.localWorkspaceKey) == "local")
            #expect(defaults.string(forKey: "server.drafts") == "unsent text")
        }
    }

    @Test("A legacy remote session cannot reopen the previously selected remote workspace")
    func mutuallyExclusiveRemoteMemory() throws {
        try withDefaults { defaults in
            SidebarSelectionMemory.remember(.remoteWorkspace(WorkspaceID("old")), in: defaults)
            SidebarSelectionMemory.remember(.remote(SessionID("new")), in: defaults)
            #expect(SidebarSelectionMemory.savedRemote(in: defaults) == .remote(SessionID("new")))
            #expect(defaults.object(forKey: SidebarSelectionMemory.remoteWorkspaceKey) == nil)
            SidebarSelectionMemory.remember(.workspace(WorkspaceID("local")), in: defaults)
            #expect(SidebarSelectionMemory.savedRemote(in: defaults) == nil)
        }
    }

    @Test("A fresh catalogue rejects removed IDs and accepts existing workspace and session IDs")
    func validatesRestoration() {
        let workspaces: Set<WorkspaceID> = [WorkspaceID("present")]
        let sessions: Set<SessionID> = [SessionID("chat")]
        #expect(!SidebarSelectionMemory.contains(.remoteWorkspace(WorkspaceID("deleted")), workspaceIDs: workspaces, sessionIDs: sessions))
        #expect(!SidebarSelectionMemory.contains(.remote(SessionID("deleted")), workspaceIDs: workspaces, sessionIDs: sessions))
        #expect(SidebarSelectionMemory.contains(.remoteWorkspace(WorkspaceID("present")), workspaceIDs: workspaces, sessionIDs: sessions))
        #expect(SidebarSelectionMemory.contains(.remote(SessionID("chat")), workspaceIDs: workspaces, sessionIDs: sessions))
        #expect(!SidebarSelectionMemory.contains(.home, workspaceIDs: workspaces, sessionIDs: sessions))
    }

    private func withDefaults(_ body: (UserDefaults) -> Void) throws {
        let name = "RemoteSidebarSelectionMemoryTests-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        body(defaults)
    }
}
