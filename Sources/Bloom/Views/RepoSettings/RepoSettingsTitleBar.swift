import AppKit
import SwiftUI
import BloomCore

/// Gives the project settings window an ordinary Mac title bar, above its tab bar.
///
/// A `TabView` at the root of a window hands its tab bar to the title bar, and SwiftUI hides the
/// window's title when it does. The title is not lost, only undrawn: `navigationTitle` still sets
/// `NSWindow.title`, and the window carries the right string the whole time. So the tab bar and a
/// title are not in competition for one row, and the belief that a window has to choose between
/// them is wrong. Making the title visible again and asking for the toolbar style a preferences
/// window uses gives the title a row of its own with the tab bar centred underneath, which is the
/// shape of the app's own Settings window and the reason a `TabView` was chosen here.
///
/// The folder comes along as the window's `representedURL`, so the title bar behaves like every
/// document window on the Mac: the proxy icon beside the title drags into a terminal or an editor,
/// and Command-clicking the title drops down the path from the project up to the volume, each
/// level of which opens in Finder.
///
/// AppKit rather than SwiftUI because SwiftUI models neither of the two things this needs.
/// `windowToolbarStyle` has no case for the preferences style, and nothing in SwiftUI un-hides a
/// title the framework decided to hide. `WindowProxyIcon` reaches for the main window's title bar
/// the same way and for the same reason.
struct RepoSettingsTitleBar: ViewModifier {
    let repo: Repo

    @State private var window: NSWindow?

    func body(content: Content) -> some View {
        content
            .background(WindowAccessor(window: $window))
            // Both halves can arrive first: the window is attached a pass after the view exists,
            // and a project renamed in the main window changes the folder under an open window.
            .onChange(of: window, initial: true) { _, _ in apply() }
            .onChange(of: repo.path) { _, _ in apply() }
    }

    private func apply() {
        guard let window else { return }
        // The title itself stays `navigationTitle`'s to set, so there is one place that decides
        // what this window is called.
        window.titleVisibility = .visible
        window.toolbarStyle = .preference
        window.representedURL = URL(filePath: repo.path)
    }
}

extension View {
    /// Titles the project settings window after the project, and points it at its folder.
    func showsProjectInTitleBar(_ repo: Repo) -> some View {
        modifier(RepoSettingsTitleBar(repo: repo))
    }
}
