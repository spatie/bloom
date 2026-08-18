import AppKit
import SwiftUI

/// Points the window at the worktree the user is looking at.
///
/// A `representedURL` is what makes the title bar behave like every document window on the Mac:
/// the folder can be dragged straight out of it into a terminal or an editor, and Command-clicking
/// the title drops down the path from the worktree up to the volume, each level of which opens in
/// Finder. Bloom's workspaces really are folders on disk, so the affordance is free and the
/// alternative is copying the path out of the inspector by hand.
///
/// The title travels with it, because a proxy icon with a stale name beside it is worse than none.
/// On Home there is no folder, so both are cleared rather than left pointing at the last workspace.
struct WindowProxyIcon: ViewModifier {
    let app: AppModel

    @State private var window: NSWindow?

    /// What the title bar should say and point at, as one value, so a single `onChange` covers
    /// both and they can never be applied a frame apart.
    private struct Represented: Equatable {
        var title: String
        var url: URL?
    }

    private var represented: Represented {
        guard let workspace = app.selectedWorkspace else {
            return Represented(title: "Bloom", url: nil)
        }
        return Represented(title: workspace.name, url: URL(filePath: workspace.path))
    }

    func body(content: Content) -> some View {
        content
            .background(WindowAccessor(window: $window))
            // Two triggers, because either half can arrive first: the window is attached one pass
            // after the view exists, and the selection changes for the rest of the launch.
            .onChange(of: represented, initial: true) { _, value in apply(value) }
            .onChange(of: window, initial: true) { _, _ in apply(represented) }
    }

    private func apply(_ value: Represented) {
        guard let window else { return }
        window.title = value.title
        window.representedURL = value.url
    }
}

extension View {
    func showsWorktreeInTitleBar(_ app: AppModel) -> some View {
        modifier(WindowProxyIcon(app: app))
    }
}
