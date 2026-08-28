import SwiftUI
import BloomCore

/// The workspace's name in the title bar, which you can rename from.
///
/// ## Why this is drawn rather than borrowed
///
/// A document window gets this behaviour free: click the title, get a menu with Rename, choose it,
/// and the title becomes an editable field in place. None of that is reachable from here, and the
/// headers say so rather than it being a guess.
///
///   - The renaming session is `NSDocument`'s. `NSDocument.h` documents `renameDocument:` as
///     "initiates a renaming session in the window returned by `[self windowForSheet]`", and that
///     is the ONLY mention of renaming in the whole public AppKit header set, `NSWindow.h`,
///     `NSToolbar.h` and `NSWindowController.h` included. What it starts, read out of the dyld
///     shared cache, is `NSTitlebarRenamingSession`, entered through
///     `_startLocalRenameSessionWithDelegate:` and bracketed by
///     `_NSWindowTitleBarRenameDidBeginNotification`: all underscored, none of them API.
///   - The menu that would carry Rename hangs off `representedURL`, and `NSWindow.h` says a
///     represented URL is what puts a pop-up menu on "the area containing the document icon and
///     title". The URL is not separable from the folder proxy icon, and the owner asked for that
///     icon to go: `WindowTitle` carries the reasoning. Taking the URL back to get a menu is a
///     trade this window has already refused.
///
///   - **`navigationTitle(_ title: Binding<String>)` is not the door into it, and this was
///     measured rather than read.** The overload is declared for macOS 13 and its own
///     documentation says the binding "allows editing the navigation title when the title is
///     displayed in the toolbar", which reads exactly like the public half of the session above.
///     It is not. Built offscreen twice, once with the binding and once with the plain `String`,
///     and the whole title bar compared: the `NSToolbarTitleView`, the
///     `NSToolbarPrimaryTitleContainerView`, the `_NSToolbarTitleField` and the
///     `NSWindowTitleController` behind them come out with identical ivars and identical gesture
///     recognisers, `_handleToolbarTitleViewLeftPress:` and the two sidecar ones, which are
///     AppKit's own and are there either way. The field is `editable=false` in both. The binding
///     changes nothing about the title bar on macOS; it is an iOS feature with a shared
///     declaration. Do not chase it again.
///
/// So the machinery cannot be borrowed, and this is the smallest thing that behaves like it.
///
/// ## The double click is on the text, never on the bar
///
/// Desktop & Dock has "Double-click a window's title bar to", set to Zoom or Minimise, and a title
/// bar that started a rename instead would be a system preference quietly broken. That is why the
/// title is drawn as a view of ours at all: the gesture is attached to the text's own shape, so
/// every other point of the bar is untouched AppKit and keeps whatever the user set.
///
/// **Two titles have to be turned off for this to be the only one, not one.** `WindowChrome` sets
/// `NSWindow.titleVisibility`, which governs the title AppKit draws; `RootView` says
/// `.toolbar(removing: .title)`, which governs the title item SwiftUI contributes from
/// `navigationTitle`. The first shipped without the second and the window wore its name twice.
///
/// ## The toolbar background is AppKit's, and there is nothing here to draw it
///
/// An earlier report said a bare `Text` in a toolbar item picked up no capsule at all. That report
/// was wrong, and the way it was wrong is why the bar looked broken.
/// On macOS 26 every toolbar item is given a shared background: AppKit wraps it in an
/// `NSToolbarPlatterView` holding an `NSGlassEffectView`, which is the same plate
/// used for toolbar controls, so a `.glassEffect` of ours would be a second treatment over the
/// first.
///
/// What there was instead was a capsule nobody could see, because the search field's capsule
/// began eight points after it and the two read as one long run of glass. Rendered offscreen at
/// 1440 points: the name's plate ran 152 to 408 and the field's 416 to 741. The fix was the space
/// between them, not the plate, and it is `BloomWindowToolbar`'s `ToolbarSpacer`.
///
/// One thing follows from the plate being AppKit's, and it is worth knowing before anybody puts a
/// neighbour next to this one. **Two adjacent items are sometimes drawn in a single plate**, so
/// with the sidebar folded away the `+` and the name can come out as one capsule holding both.
/// Whether they do was not stable across the runs here and is AppKit's to decide; a fixed
/// `ToolbarSpacer` between them does not divide it, and a flexible one would push the name into
/// the middle of the bar. It is left alone. The switch worth knowing about is
/// `.sharedBackgroundVisibility` on the item, which turns a plate off rather than dividing one.
///
/// ## Renaming in place, measured
///
/// The label and the field are drawn in the same toolbar item, so the plate they sit in has one
/// origin and the name cannot jump as it becomes editable. Offscreen, at rest and mid rename, the
/// plate is at x=152.5 both times; it is four points wider while editing, which is the field's own
/// inset and falls off the trailing end where there is nothing to displace.
struct WindowTitleControl: View {
    /// Handed in rather than read from the environment, as `BloomWindowToolbar` takes it, because
    /// a `contextMenu`'s content is built in a detached context that observable values in the
    /// environment do not reliably reach.
    let app: AppModel

    /// The workspace whose name is in the field, captured rather than read back off the selection.
    /// Selecting another workspace ends the rename, and by then the selection is the wrong one to
    /// write to.
    @State private var renaming: Workspace?
    @State private var draft = ""
    /// Whether this rename has already been finished, so the ways of leaving the field cannot
    /// write the name twice. See `WorkspaceRow.end`, which this mirrors deliberately.
    @State private var hasEnded = false
    @FocusState private var fieldFocused: Bool

    /// Past this the name truncates. AppKit gives its own title whatever the bar has left; a
    /// toolbar item asks for what it wants, and an unbounded one would push the rest of the bar
    /// around every time a workspace with a sentence for a name was selected.
    private static let maximumWidth: CGFloat = 360

    var body: some View {
        Group {
            if let workspace = renaming {
                field(workspace)
            } else if let workspace = app.selectedWorkspace {
                label(workspace)
            } else {
                // Home. There is nothing to rename, so it is text and only text.
                titleText.frame(maxWidth: Self.maximumWidth, alignment: .leading)
            }
        }
        // Moving the selection closes the field from underneath, which is an ending like any
        // other and the one the sidebar used to throw away. See `InPlaceRename`.
        .onChange(of: app.selectedWorkspace?.id) { _, _ in
            if renaming != nil { end(.dismissed) }
        }
    }

    // MARK: - Resting

    /// Deliberately carries no frame. The width cap goes on OUTSIDE the gestures below, or the
    /// hit shape is the cap rather than the text and a short name leaves three hundred points of
    /// title bar answering to a double click.
    private var titleText: some View {
        // `WindowTitleText` rather than the workspace's name, so a labelled build keeps its mark.
        Text(WindowTitleText.shared.text)
            .font(Typo.title)
            .foregroundStyle(Palette.textPrimary)
            .lineLimit(1)
            .truncationMode(.tail)
    }

    private func label(_ workspace: Workspace) -> some View {
        titleText
            // The gesture's whole boundary: the text's own rectangle and nothing else.
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { begin(workspace) }
            .contextMenu {
                WorkspaceMenuItems(workspace: workspace, scope: .title) { _ in begin(workspace) }
                    .environment(app)
            }
            .help("Double-click to rename")
            .accessibilityLabel("Workspace name")
            .accessibilityValue(workspace.name)
            // Outside all of the above, so the run past a short name is bar rather than name.
            .frame(maxWidth: Self.maximumWidth, alignment: .leading)
    }

    // MARK: - Renaming

    private func field(_ workspace: Workspace) -> some View {
        ZStack(alignment: .leading) {
            // Sizes the field to its own text in the title's own font. That is what stops the name
            // moving when the label becomes a field, and it is what lets the field grow as you
            // type: a plain `TextField` has no width of its own and would take everything offered.
            Text(draft)
                .font(Typo.title)
                .hidden()

            TextField("Workspace name", text: $draft)
                .textFieldStyle(.plain)
                .font(Typo.title)
                // Said rather than inherited, for the reason the sidebar's field says it: an
                // editing field paints its own light background while focused.
                .foregroundStyle(Palette.textPrimary)
                .focused($fieldFocused)
                .onSubmit { end(.submitted) }
                .onExitCommand { end(.escaped) }
                // Clicking away commits, which is what Finder, Xcode and Mail do. Guarded on
                // having had the focus, so the false this starts at is not read as having lost it.
                .onChange(of: fieldFocused) { had, has in
                    guard had, !has else { return }
                    end(.focusLost)
                }
        }
        .frame(minWidth: 80, maxWidth: Self.maximumWidth, alignment: .leading)
        .task(id: workspace.id) {
            // A beat, so the field exists before focus moves to it.
            try? await Task.sleep(for: .milliseconds(30))
            fieldFocused = true
        }
    }

    private func begin(_ workspace: Workspace) {
        // The workspace's name, never `WindowTitleText`, so a "[DEV] " prefix cannot be typed
        // into a stored name by a reader who never asked to edit it.
        draft = workspace.name
        hasEnded = false
        renaming = workspace
    }

    /// One door out of the field, for every way of leaving it, and the same one the sidebar and
    /// Home use: `InPlaceRename` decides, `AppModel.rename` writes, and there is one of each.
    private func end(_ ending: InPlaceRename.Ending) {
        guard let workspace = renaming, !hasEnded else { return }
        hasEnded = true
        renaming = nil
        guard case .commit(let name) = InPlaceRename.outcome(
            ending, draft: draft, current: workspace.name
        ) else { return }
        Task { await app.rename(workspace, to: name) }
    }
}
