import AppKit
import SwiftUI

/// Names the window after the workspace the user is looking at.
///
/// **It used to set a `representedURL` as well, and that is deliberately gone.** A represented URL
/// makes a title bar behave like a document window's: the folder can be dragged out of it, and
/// Command-clicking the title drops down the path from the worktree up to the volume. Bloom's
/// workspaces really are folders, so the affordance was free.
///
/// What it also does is draw a folder proxy icon in front of the title, and macOS reveals that
/// icon on hover. The owner asked for it to go: a chat window that grows a folder badge when the
/// pointer crosses its title reads as a document window, and this is not one. The icon is not
/// separable from the URL, so hiding the button would be fighting AppKit for a picture it will
/// put back; the URL goes instead, and the drag and the path menu go with it. If either is ever
/// wanted again it is one line here.
///
/// On Home there is no workspace, so the title says Bloom rather than staying on the last one.
///
/// **AppKit no longer DRAWS the title.** `WindowTitleControl` does, as a toolbar item, so that a
/// double click can be bounded to the run of text rather than to the whole bar: a double click
/// anywhere in a title bar is already the system's, wired to Zoom or Minimise in Desktop & Dock.
/// The window still has a title, which is what the Window menu, Mission Control, the Dock and
/// saved window state read. What this file keeps is the title itself; `WindowChrome` is what turns
/// AppKit's drawing of it off.
struct WindowTitle: ViewModifier {
    let app: AppModel

    @State private var window: NSWindow?

    private var title: String {
        app.selectedWorkspace?.name ?? "Bloom"
    }

    func body(content: Content) -> some View {
        content
            .background(WindowAccessor(window: $window))
            // Two triggers, because either half can arrive first: the window is attached one pass
            // after the view exists, and the selection changes for the rest of the launch.
            .onChange(of: title, initial: true) { _, value in apply(value) }
            .onChange(of: window, initial: true) { _, _ in apply(title) }
    }

    private func apply(_ value: String) {
        guard let window else { return }
        window.title = value
        // Cleared rather than merely never set. A window restored from a previous launch, or one
        // that carried a represented URL before this was changed, keeps it otherwise, and the
        // folder icon would come back for exactly the readers who had already seen it.
        window.representedURL = nil
        // Read BACK rather than passed on, so a build's own mark comes with it. See
        // `WindowTitleText`. Whether AppKit draws any of this is `WindowChrome`'s to say.
        WindowTitleText.shared.set(window.title)
    }
}

/// What the title bar reads, published so a view can draw it.
///
/// It is `window.title` read back rather than the name that went in, and that is the only reason
/// this exists. `Tools/dev-build.sh` patches the assignment in `WindowTitle.apply` to prefix
/// "[DEV] ", so once AppKit stops drawing the title a dev window has to keep saying so; reading
/// the window back picks that mark up without a second anchor to keep in step with the first.
///
/// **The name being EDITED never comes from here.** `WindowTitleControl` seeds its field from the
/// workspace, so no build prefix can reach a stored name.
@MainActor
@Observable
final class WindowTitleText {
    static let shared = WindowTitleText()

    private(set) var text = "Bloom"

    private init() {}

    func set(_ value: String) {
        guard text != value else { return }
        text = value
    }
}

extension View {
    func showsWorkspaceInTitleBar(_ app: AppModel) -> some View {
        modifier(WindowTitle(app: app))
    }
}
