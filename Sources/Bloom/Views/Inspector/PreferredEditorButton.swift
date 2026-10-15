import SwiftUI
import BloomCore

/// Opens the worktree in the project's editor in one click; a hold shows the list to switch.
///
/// Read from the per repository key alone, not the global fallback, so it appears once this
/// project has a choice of its own, and `@AppStorage` shows it the moment one is recorded.
struct PreferredEditorButton: View {
    let workspace: Workspace

    @AppStorage private var chosenBundleID: String?

    private static let iconSize: CGFloat = 16

    init(workspace: Workspace) {
        self.workspace = workspace
        _chosenBundleID = AppStorage(OpenInPreferences.key(forRepo: workspace.repoID))
    }

    private var target: OpenInTarget { .folder(workspace.path) }

    /// Nil when the remembered application is no longer installed, so no dead button is drawn.
    private var chosenApp: DetectedApp? {
        guard let chosenBundleID else { return nil }
        return OpenIn.candidates(for: target, repo: workspace.repoID).first { $0.id == chosenBundleID }
    }

    var body: some View {
        if let app = chosenApp {
            Menu {
                OpenInAppItems(target: target)
            } label: {
                Image(nsImage: app.icon)
                    .resizable()
                    .frame(width: Self.iconSize, height: Self.iconSize)
            } primaryAction: {
                OpenIn.open(workspace.path, with: app, repo: workspace.repoID)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .environment(\.openInRepoID, workspace.repoID)
            .help("Open worktree in \(app.app.name)")
            .accessibilityLabel("Open worktree in \(app.app.name)")
        }
    }
}
