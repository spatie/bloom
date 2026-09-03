import SwiftUI

/// The window a project is started in.
///
/// **A window rather than a sheet, and the owner asked for it in one line: "could you make start
/// new project a separate window too."** The too is the create window, which had just stopped
/// being a sheet for a reason that holds here as well. The one field on this surface takes a path,
/// and where a person reads a path is the Finder, a terminal, or the sidebar of the window this
/// used to be pinned on top of. A sheet blocks all three: the answer to "what was that folder
/// called" was to cancel, go and look, and come back. This can be dragged aside and the projects
/// already in Bloom read behind it.
///
/// **A `Window` rather than a `WindowGroup`, which is the one place this differs from the create
/// window.** That one is keyed by project, so there is one per project and asking again for the
/// same one brings it forward. This asks nothing about any project, so there is no value to key it
/// by, and a `WindowGroup` with no value opens a second window every time the menu item is
/// pressed. A `Window` is a single unique window by definition, and `openWindow(id:)` on one
/// raises what is already there. Two of these open at once would be two half typed paths racing to
/// make the same folder.
///
/// Not resizable, for the reason the create window is not: the width is `StartProjectView.width`
/// and the height is whatever the phase needs, so a window dragged taller would hand every extra
/// point to a blank margin. The block in the middle grows for a long refusal, which moves the
/// window's own height and is the only movement here worth paying for.
///
/// Restoration off, again as the create window has it. Nothing here survives a relaunch worth
/// having: no folder has been made yet, the field holds half a path typed against a project list
/// that is empty until the store answers, and the item is one keystroke away.
struct StartProjectWindow: Scene {
    let model: AppModel

    /// The scene id. Opening this window from anywhere is `openWindow(id:)` with it.
    static let id = "start-project"

    var body: some Scene {
        // The window's title is set by its content instead, because it says which of the three
        // phases the window is in. See `StartProjectView.title`.
        Window("Start a Project", id: Self.id) {
            StartProjectView()
                .environment(model)
                // Cmd+W, and not Escape from the key monitor. Escape here belongs to the Cancel
                // and Stop buttons in the footer, which carry it as `.cancelAction` and which are
                // the only things in this window that want it. See `WindowRoles`.
                .windowRole(.utility)
        }
        .windowResizability(.contentSize)
        .restorationBehavior(.disabled)
    }
}
