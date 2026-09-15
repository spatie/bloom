import Foundation

/// Whether the Mac app shows anything about remote servers at all, and what the window does with
/// a selection that points at one when the answer is no.
///
/// One setting rather than a beta channel, because the owner wanted the feature out of the way of
/// everybody who has not asked for it, while the people trying it keep every saved server. So the
/// switch hides and stops, and never deletes: saved profiles, drafts and the remembered selection
/// all stay where they are, and turning it back on finds them.
///
/// The decisions are here rather than in `AppModel` because a remote selection surviving the
/// switch is the one way the feature leaks back into view: the toolbar, the detail column and the
/// inspector all draw a server's workspace straight off the selection, without asking whether
/// servers are shown.
public enum RemoteServerFeature {
    public static let settingKey = "remoteServersEnabled"
    /// Off, so a fresh install shows no servers and starts no connection until somebody asks.
    public static let isOnByDefault = false

    /// On in Bloom Remote, the separate copy built only to try servers with, and off everywhere
    /// else. Its first launch showed no servers and no way to add one, because the Window menu's
    /// Add Server opened a window the switch closed again at once.
    public static func isOnByDefault(bundleIdentifier: String?) -> Bool {
        bundleIdentifier == Store.remoteBundleIdentifier || isOnByDefault
    }

    public static let settingTitle = "Remote servers"
    public static let settingDetail = "Adds servers to the sidebar, the File menu and the create windows, so workspaces can run on another machine."
    public static let settingFootnote = "Saved servers are kept while this is off, but Bloom hides them and does not connect."

    /// Read through `object(forKey:)` so an unregistered key still answers with the default above,
    /// rather than the `false` `bool(forKey:)` would give whatever the default says.
    public static func isEnabled(in defaults: UserDefaults) -> Bool {
        defaults.object(forKey: settingKey) as? Bool ?? isOnByDefault
    }

    /// Whether the window may move to `selection`. A remote row can still be asked for with the
    /// feature off, by a restored window or a catalogue that arrives late, and refusing it here is
    /// cheaper than hiding every surface that draws from it.
    public static func admits(_ selection: SidebarSelection, isEnabled: Bool) -> Bool {
        isEnabled || !selection.isRemote
    }

    /// Where the window goes when the feature is turned off, or nil to stay put.
    ///
    /// Back to the last local workspace when it still exists, because that is where the person was
    /// before they opened the server's, and Home otherwise.
    public static func selectionAfterDisabling(
        _ selection: SidebarSelection, lastLocalWorkspace: WorkspaceID?, workspaces: Set<WorkspaceID>
    ) -> SidebarSelection? {
        guard selection.isRemote else { return nil }
        if let id = lastLocalWorkspace, workspaces.contains(id) { return .workspace(id) }
        return .home
    }

    /// What launch does with the remembered selection.
    public enum LaunchRestore: Equatable, Sendable {
        /// Wait for the server's catalogue and move there if the row still exists.
        case remote(SidebarSelection)
        /// Restore the last local workspace. `forgetsRemote` is false while the feature is off,
        /// so the server's row is still remembered for the day it is turned back on.
        case local(forgetsRemote: Bool)
    }

    public static func launchRestore(
        savedRemote: SidebarSelection?, isEnabled: Bool, isConfigured: Bool
    ) -> LaunchRestore {
        guard isEnabled else { return .local(forgetsRemote: false) }
        if isConfigured, let savedRemote { return .remote(savedRemote) }
        return .local(forgetsRemote: true)
    }
}
