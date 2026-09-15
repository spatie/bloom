import Foundation
import Testing
@testable import BloomCore

/// The switch that hides remote servers. What matters is that a server's workspace cannot stay on
/// screen with the feature off, and that turning it off forgets nothing.
@Suite("Remote server feature")
struct RemoteServerFeatureTests {
    private let local = WorkspaceID("local")
    private let remote = WorkspaceID("remote")

    @Test("off unless somebody turned it on")
    func offByDefault() throws {
        let name = "RemoteServerFeatureTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }

        #expect(!RemoteServerFeature.isOnByDefault)
        #expect(!RemoteServerFeature.isEnabled(in: defaults))
        defaults.set(true, forKey: RemoteServerFeature.settingKey)
        #expect(RemoteServerFeature.isEnabled(in: defaults))
    }

    @Test("a remote selection is refused only while the feature is off")
    func admitsSelections() {
        #expect(!RemoteServerFeature.admits(.remoteWorkspace(remote), isEnabled: false))
        #expect(!RemoteServerFeature.admits(.remote(SessionID("s")), isEnabled: false))
        #expect(RemoteServerFeature.admits(.remoteWorkspace(remote), isEnabled: true))
        #expect(RemoteServerFeature.admits(.workspace(local), isEnabled: false))
        #expect(RemoteServerFeature.admits(.home, isEnabled: false))
    }

    @Test("turning it off leaves a local selection where it is")
    func localSelectionStays() {
        let next = RemoteServerFeature.selectionAfterDisabling(
            .workspace(local), lastLocalWorkspace: local, workspaces: [local]
        )
        #expect(next == nil)
    }

    @Test("turning it off moves a remote selection to the last local workspace")
    func remoteSelectionReturnsToLocal() {
        let next = RemoteServerFeature.selectionAfterDisabling(
            .remoteWorkspace(remote), lastLocalWorkspace: local, workspaces: [local]
        )
        #expect(next == .workspace(local))
    }

    @Test("turning it off moves a remote selection Home when the local workspace has gone")
    func remoteSelectionReturnsHome() {
        #expect(RemoteServerFeature.selectionAfterDisabling(
            .remote(SessionID("s")), lastLocalWorkspace: local, workspaces: []
        ) == .home)
        #expect(RemoteServerFeature.selectionAfterDisabling(
            .remoteWorkspace(remote), lastLocalWorkspace: nil, workspaces: [local]
        ) == .home)
    }

    @Test("launch never restores a server row while the feature is off, and does not forget it")
    func launchWithFeatureOff() {
        let restore = RemoteServerFeature.launchRestore(
            savedRemote: .remoteWorkspace(remote), isEnabled: false, isConfigured: true
        )
        #expect(restore == .local(forgetsRemote: false))
    }

    @Test("launch restores a server row as before while the feature is on")
    func launchWithFeatureOn() {
        #expect(RemoteServerFeature.launchRestore(
            savedRemote: .remoteWorkspace(remote), isEnabled: true, isConfigured: true
        ) == .remote(.remoteWorkspace(remote)))
        #expect(RemoteServerFeature.launchRestore(
            savedRemote: .remoteWorkspace(remote), isEnabled: true, isConfigured: false
        ) == .local(forgetsRemote: true))
        #expect(RemoteServerFeature.launchRestore(
            savedRemote: nil, isEnabled: true, isConfigured: true
        ) == .local(forgetsRemote: true))
    }
}
