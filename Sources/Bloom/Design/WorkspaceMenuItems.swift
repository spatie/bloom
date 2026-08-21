import SwiftUI
import BloomCore

/// Everything you can do to a workspace, as the right click menu on its row.
///
/// One copy, used by the sidebar (`SidebarWorkspaceRow`) and by Home (`HomeRowMenu`). It was two,
/// deliberately and temporarily, with a note in `HomeRowMenu` saying what to pull out when the two
/// were put back together, and this is that: a view taking the workspace and one `onRename`
/// closure, reading `AppModel` from the environment as both sites already did. The rename is the
/// only thing the two callers genuinely do differently, because the sidebar writes an id into a
/// binding shared across its whole list and Home writes one into its own.
///
/// The duplication was tolerable while the menu was six items that never changed. It stopped being
/// tolerable the moment two items were added to it: the same workspace would have answered
/// differently depending on which list you happened to right click in, which is exactly the drift
/// that put `WorkspaceNameText` in this folder.
///
/// Archived workspaces are not drawn from here. The sidebar never lists one, and Home's menu for
/// one is a different, shorter menu about a worktree that no longer exists, so it stays where it
/// is, in `HomeRowMenu`, next to the reasoning for it.
///
/// ## Three groups, and the rule is what each one acts on
///
/// The first three go somewhere else: they open the worktree, show it, or put its branch on the
/// clipboard, and every one of them is about the checkout on disk. The next four are about the ROW
/// and change nothing outside Bloom: whether it floats, whether it is shouting at you, what colour
/// it is, what it is called. The last destroys it, behind a rule of its own, which is the grouping
/// this menu already had and the same rhythm a project header's menu is built on. See
/// `RepoHeaderRow` for why three rules and not four.
///
/// Ask Siri, which the owner sees at the top of this menu, is not in this list and is not ours to
/// move. macOS 27 puts it on context menus itself for a user who has Apple Intelligence on. The
/// menu was read back as AppKit built it and carried these items and nothing else, so nothing here
/// contributes it, and there is no switch to reach it with: `NSMenu.allowsContextMenuPlugIns`
/// covers Services and contextual menu plug-ins, Ask Siri is registered as neither, and a SwiftUI
/// `contextMenu` hands out no `NSMenu` to set it on in any case.
///
/// ## Why the colour is a submenu of named rows and not Finder's row of swatches
///
/// Finder draws seven bare coloured dots on one line, and that shape is not reachable from here.
/// It is not a matter of taste and it was not assumed. Five variants were built and the `NSMenu`
/// SwiftUI produced for each was read back item by item:
///
///   - An `HStack` of swatch buttons is FLATTENED. The seven buttons become seven separate menu
///     items, each with an empty title, no image and no `view`, which is a menu with a column of
///     blank rows in the middle of it. SwiftUI never sets `NSMenuItem.view` for anything, in any
///     variant, so the custom view item Finder itself uses has no route in from a SwiftUI menu.
///   - A SwiftUI `Circle` in a `Label`'s icon position keeps the title but draws no image at all.
///     This is the neighbouring rule `RepoIconImage` already paid to learn.
///   - `Label { Text(name) } icon: { Image(nsImage:) }` comes through whole: title and a 12 point
///     image, in the two slots a menu item has for them.
///   - A `Menu` wrapping an inline `Picker` gets the tick, and a separator above and below the
///     group that nothing asked for.
///   - A bare `Picker` in the menu makes its own submenu, with the tick on the current row, the
///     images intact and no stray rules. That is the one below.
///
/// So the tick is the platform's, drawn in the state column beside the swatch rather than instead
/// of it, and "None" is a row like any other rather than a second gesture to learn.
struct WorkspaceMenuItems: View {
    var workspace: Workspace
    /// Raised to the list, which owns the one rename field that can be open at a time.
    var onRename: (String) -> Void

    @Environment(AppModel.self) private var app

    var body: some View {
        Button("Open in Editor") { Reveal.inEditor(workspace.path) }
        Button("Reveal in Finder") { Reveal.inFinder(workspace.path) }
        Button("Copy branch name") { Clipboard.copy(workspace.branch) }
        Divider()
        Button(workspace.pinned ? "Unpin" : "Pin") {
            Task { await app.togglePinned(workspace) }
        }
        // One item that changes its label rather than two, and which of the two it is is decided
        // in the core so the sidebar and Home cannot disagree about one workspace. See
        // `WorkspaceUnreadMark`, which is also where the archived case is argued out.
        if let mark = WorkspaceUnreadMark.action(for: workspace) {
            Button(mark.title) {
                Task { await app.setUnread(workspace, mark.unread) }
            }
        }
        colourPicker
        Button("Rename") { onRename(workspace.id) }
        Divider()
        // Straight through, with no dialog of its own. Whether this needs confirming is not
        // something a menu can know: it depends on what is uncommitted, what is running and what
        // GitHub says about the branch, and `AppModel.archive` is where all three come together.
        // Asking here as well meant a sheet on every archive, including the routine one, which is
        // exactly how a confirmation stops being read.
        //
        // The sidebar row's own hover archive button DOES ask every time, and that is not a
        // disagreement with this. See `SidebarWorkspaceRow.confirmRowArchive`.
        Button("Archive", role: .destructive) {
            Task { await app.archive(workspace) }
        }
    }

    /// The colour submenu: None, then the ten colours, with the tick on the current one.
    ///
    /// A bare `Picker`, which is what makes its own submenu titled "Colour" with the state column
    /// filled in for us. A `Button` carrying a checkmark symbol in its label never gets one, which
    /// is the same thing `ComposerOptionMenu` found.
    ///
    /// None is offered as its own row rather than by pressing the current colour again, which is
    /// how Finder clears a tag. A press that means "set" everywhere except on one row, where it
    /// means "clear", is a rule you can only find out about by losing a colour you wanted.
    private var colourPicker: some View {
        Picker("Colour", selection: colourSelection) {
            Text("None").tag("")
            ForEach(WorkspaceColour.all) { colour in
                Label {
                    Text(colour.name)
                } icon: {
                    if let swatch = WorkspaceColourImage.of(colour.hex) {
                        // `.original`, or the swatch is repainted flat in the label's colour and
                        // the menu comes up as ten grey dots.
                        Image(nsImage: swatch).renderingMode(.original)
                    }
                }
                .tag(colour.hex)
            }
        }
    }

    /// The empty string is "no colour", because a `Picker` needs every row to carry a tag of one
    /// type and there is no row to put `nil` on.
    ///
    /// A workspace holding a hex that is not in the list selects nothing, so no row is ticked and
    /// the dot on the row goes on being drawn in the colour it was given. That is the right way
    /// round: the stored value is the truth and this list is only the menu's opinion of it.
    private var colourSelection: Binding<String> {
        Binding(
            get: { workspace.colour ?? "" },
            set: { hex in
                Task { await app.setColour(workspace, to: hex.isEmpty ? nil : hex) }
            }
        )
    }
}
