import Foundation
import BloomCore

/// The same stores and components, owned separately by each execution origin.
@MainActor
final class PaneStores {
    static let local = PaneStores(defaults: .standard, domain: Bundle.main.bundleIdentifier, migrateLegacy: true, identity: "local")
    let sourceNavigation = SourceNavigation()
    private var sourceFiles: [String: SourceEditorState] = [:]

    func sourceFile(_ path: String) -> SourceEditorState {
        let path = URL(fileURLWithPath: path).standardizedFileURL.path
        if let state = sourceFiles[path] { return state }
        let state = SourceEditorState()
        sourceFiles[path] = state
        return state
    }

    let identity: String
    let center: CenterTabStore
    let tabs: WorkspaceTabsStore
    let defaults: UserDefaults

    private init(defaults: UserDefaults, domain: String?, migrateLegacy: Bool, identity: String) {
        self.defaults = defaults
        self.identity = identity
        center = CenterTabStore(defaults: defaults, usesLocalTerminals: migrateLegacy)
        tabs = WorkspaceTabsStore(center: center, defaults: defaults, domain: domain, migrateLegacy: migrateLegacy)
        center.workspaceTabs = tabs
    }

    static func remote(connectionID: String) -> PaneStores {
        let name = PaneStateNamespace.suiteName(connectionID: connectionID, appDomain: Bundle.main.bundleIdentifier ?? "app.bloom")
        // A remote domain never reads or migrates the historical unqualified local keys.
        guard let defaults = UserDefaults(suiteName: name) else { preconditionFailure("Cannot create remote pane defaults") }
        return PaneStores(defaults: defaults, domain: name, migrateLegacy: false, identity: connectionID)
    }
}
