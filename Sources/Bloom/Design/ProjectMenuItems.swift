import SwiftUI
import BloomCore

/// Everything you can do to a project, as the right click menu on its header row.
///
/// Pulled out of `RepoHeaderRow` for the reason `WorkspaceMenuItems` was pulled out of the two
/// rows that had grown their own copy: a menu that lives inside a view body is a menu nothing can
/// photograph. `MenuProbe --menu-part project` builds this very view, so a picture of this menu
/// cannot show an item the app does not have, and the hidden and not hidden wordings can each be
/// looked at rather than reasoned about.
///
/// ## Three groups, and the rule is what each one acts on
///
/// The first item is about the WORKSPACES under this header: it makes another one. The next four
/// are about the PROJECT itself: what it is called, how it is set up, where it lives on disk, and
/// whether the sidebar lists it at all. The last destroys it, and a destructive item at the foot
/// of a menu behind a rule of its own is the grouping this menu already had.
///
/// Hide project sits at the foot of the middle group rather than at the top, directly above
/// Remove project, and the pair is meant to be read together: one takes the project out of the
/// list and keeps everything, the other makes Bloom forget it. Putting the reversible one first
/// is what stops Remove being the only item that looks like "get this out of my sidebar".
///
/// Show workspaces and Hide workspaces used to be the second item, and they are gone. They folded
/// the project's rows away, which is exactly what the chevron at the leading edge of the header
/// already does, with its own state, its own animation and its own accessibility value. Nothing
/// else read the menu item and the stored `collapsed` flag it wrote is still written and still
/// read by that chevron, so removing the item orphaned nothing.
///
/// Three rules and not four. The obvious fourth would fence Reveal in Finder off as "goes
/// somewhere else", and that leaves a menu whose bottom half carries a rule between every item,
/// which says exactly as much as no rules at all.
///
/// Ask Siri, which the owner sees at the top of this menu, is not in this list and is not ours to
/// move. macOS 27 puts it on context menus itself for a user who has Apple Intelligence on. The
/// menu was read back as AppKit displayed it and carried these items and nothing else, so nothing
/// here contributes it. There is also no switch to reach it with: `NSMenu.allowsContextMenuPlugIns`
/// covers Services and contextual menu plug-ins, Ask Siri is registered as neither, and a SwiftUI
/// `contextMenu` hands out no `NSMenu` to set it on in any case.
struct ProjectMenuItems: View {
    var repo: Repo
    /// Raised to the sidebar, which owns the create sheet.
    var onCreateWorkspace: (Repo) -> Void
    /// The rename is a field on the row itself, so the row starts it.
    var onRename: () -> Void
    /// The confirmation hangs off the row, for the same reason.
    var onRemove: () -> Void

    @Environment(AppModel.self) private var app
    /// Opens the project settings window, the same call the gear on the header makes.
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("New workspace") { onCreateWorkspace(repo) }
        Divider()
        Button("Rename", action: onRename)
        // The route to this project's settings that needs no pointer on the gear, which is drawn
        // only while the pointer is on the header. File's own Project Settings item opens the
        // selected workspace's project; this one opens the project it was raised from, which is
        // not always the same thing.
        Button("Project settings…") {
            openWindow(id: RepoSettingsWindow.id, value: repo.id)
        }
        Button("Reveal in Finder") { Reveal.inFinder(repo.path) }
        // "Unhide" rather than "Show", because Show workspaces stood in this menu until today and
        // an owner who reads Show project as the other half of that pair would expect it to unfold
        // the rows. Unhide can only mean the one thing, and it names the state the project is in.
        Button(repo.hidden ? "Unhide project" : "Hide project") {
            Task { await app.toggleHidden(repo) }
        }
        Divider()
        Button("Remove project", role: .destructive, action: onRemove)
    }
}
