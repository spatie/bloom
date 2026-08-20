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
/// It also refuses the system's window tabbing, which is the one thing on this window that nobody
/// asked for. macOS groups windows of the same class into one tabbed window by default, so opening
/// settings for a second project merged it into the first as a tab, and a `+` beside it offered a
/// third. This window is one project's, and it already has a tab bar of its own directly above:
/// two rows of tabs, one meaning "which part of this project" and the other "which project", read
/// as one row meaning neither. There is nothing to gain here from the system's row either, since
/// the app's own tab bar is what a settings window is for. `.disallowed` is per window rather than
/// `NSWindow.allowsAutomaticWindowTabbing = false`, which would be the app speaking for windows
/// this file knows nothing about.
///
/// AppKit rather than SwiftUI because SwiftUI models none of the three things this needs.
/// `windowToolbarStyle` has no case for the preferences style, nothing in SwiftUI un-hides a title
/// the framework decided to hide, and there is no scene modifier for tabbing at all.
/// `WindowProxyIcon` reaches for the main window's title bar the same way and for the same reason.
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
        window.tabbingMode = .disallowed
        // Refusing tabbing decides what may happen to this window next, not what has already
        // happened to it: a window that is in a group when the mode is set stays in it, measured.
        // Nothing merges a window before this runs in practice, because the mode is set as the
        // window is attached and the second window is what merges. A pair restored from saved
        // state is the case that could, and it would look exactly like the fix having failed.
        if let group = window.tabGroup, group.windows.count > 1 {
            group.removeWindow(window)
        }
    }
}

extension View {
    /// Titles the project settings window after the project, and points it at its folder.
    func showsProjectInTitleBar(_ repo: Repo) -> some View {
        modifier(RepoSettingsTitleBar(repo: repo))
    }
}
