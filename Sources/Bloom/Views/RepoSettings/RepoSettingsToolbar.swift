import AppKit
import SwiftUI

/// The project settings window's panes, drawn as the toolbar macOS gives a preferences window:
/// icons with their words underneath, centred under the title.
///
/// **What was there before, and why it was not this.** The window held a SwiftUI `TabView`, which
/// is what the app's own Settings window holds, on the reasoning that the same construct in two
/// windows makes them read as one app. The reasoning was right and the construct is not what
/// decides it: what a `TabView` comes out as depends on the scene it is in. In the `Settings`
/// scene it is an `NSToolbar`, measured, and `SettingsView` carries that measurement. This window
/// is a `WindowGroup`, and there the same code drew a rounded strip inside the content with the
/// chosen pane in a darker pill, which is what the report that started this was a screenshot of.
/// Setting `NSWindow.toolbarStyle = .preference` beside it changed nothing, and could not: a
/// style is a statement about a toolbar, and asking for one without putting a toolbar on the
/// window leaves nothing for it to be about. So one app had two settings windows whose top rows
/// were drawn by two different things, and the report said exactly that: it looked like nothing
/// else in Bloom, and it did not look like the Mac either.
///
/// **Why the toolbar and not `PanelTabs`**, which is Bloom's own strip and would have been three
/// lines. `PanelTabs` is a control for the inside of a panel: it divides a width it is handed
/// between two or three words, and it is drawn in Bloom's own greys precisely because the things
/// around it are Bloom's. This row is not inside anything. It is the chrome at the top of a
/// window, next to a title, a proxy icon and the traffic lights, and the nearest thing to it in
/// this app is not a panel at all, it is the app's own Settings window one menu item away. Using
/// Bloom's strip here would have made the two settings windows differ in a second way rather than
/// stop them differing in the first, and it would have put a hand drawn control in the one row of
/// this window that belongs to the system. The place Bloom draws its own tabs is where it owns
/// what is around them.
///
/// **AppKit rather than SwiftUI, because SwiftUI models none of this.** There is no `.preference`
/// case in `windowToolbarStyle`, and no SwiftUI toolbar item can be *selected*: the whole
/// mechanism is `toolbarSelectableItemIdentifiers` plus `NSToolbar.selectedItemIdentifier`, which
/// AppKit exposes and SwiftUI does not wrap. `RepoSettingsTitleBar` reaches for the same window
/// for the same reason and says so at more length.
@MainActor
final class RepoSettingsToolbar: NSObject, NSToolbarDelegate {
    /// Told which pane was clicked. Set by the modifier below, which is where the selection lives.
    var onChoose: (RepoSettingsPane) -> Void = { _ in }

    private let preferenceToolbar = NSToolbar(identifier: "repo-settings")

    override init() {
        super.init()
        // Icons with their words under them. `.preference` asks for this shape anyway, but a
        // toolbar that says so itself cannot be talked out of it by a saved configuration.
        preferenceToolbar.displayMode = .iconAndLabel
        // There is nothing here a user could sensibly rearrange: the panes go in the order the
        // window's own sentence about them goes.
        preferenceToolbar.allowsUserCustomization = false
        preferenceToolbar.delegate = self
    }

    /// Mounts the toolbar and moves its selection to `pane`.
    ///
    /// Idempotent, and both halves are guarded, because this runs on every change the window or
    /// the selection reports. Assigning `window.toolbar` again rebuilds every item, and assigning
    /// `selectedItemIdentifier` the value it already holds is what turns a click into a loop:
    /// AppKit moves the selection itself when a selectable item is clicked, that tells the view,
    /// and the view comes straight back here to say so.
    func install(on window: NSWindow, showing pane: RepoSettingsPane) {
        if window.toolbar !== preferenceToolbar {
            window.toolbar = preferenceToolbar
        }
        // Set here rather than beside the title, because the style is a statement about this
        // toolbar: `.preference` is the one that puts the label under the icon and the whole row
        // under the title, instead of on the title's own line.
        window.toolbarStyle = .preference
        if preferenceToolbar.selectedItemIdentifier != pane.itemIdentifier {
            preferenceToolbar.selectedItemIdentifier = pane.itemIdentifier
        }
    }

    // MARK: - NSToolbarDelegate

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        RepoSettingsPane.allCases.map(\.itemIdentifier)
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    /// Every one of them, which is what makes the toolbar behave like a row of tabs rather than a
    /// row of buttons: one is lit at any moment, and clicking another moves the light.
    func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        guard let pane = RepoSettingsPane.allCases.first(where: { $0.itemIdentifier == itemIdentifier })
        else { return nil }

        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.label = pane.title
        item.paletteLabel = pane.title
        item.image = NSImage(
            systemSymbolName: pane.systemImage, accessibilityDescription: pane.title
        )
        item.target = self
        item.action = #selector(choose(_:))
        return item
    }

    /// The item is asked which pane it is rather than carrying an index in its `tag`, so nothing
    /// here depends on the order they were inserted in.
    @objc private func choose(_ sender: NSToolbarItem) {
        guard let pane = RepoSettingsPane.allCases
            .first(where: { $0.itemIdentifier == sender.itemIdentifier })
        else { return }
        onChoose(pane)
    }
}

/// Mounts the toolbar on the window this view is in, and keeps its selection and the view's the
/// same one.
private struct RepoSettingsToolbarInstaller: ViewModifier {
    @Binding var pane: RepoSettingsPane

    @State private var window: NSWindow?
    @State private var toolbar = RepoSettingsToolbar()

    func body(content: Content) -> some View {
        content
            .background(WindowAccessor(window: $window))
            // The window is attached a pass after the view exists, so the first of these is what
            // mounts the toolbar at all, and `initial` is what makes it fire for a window that
            // was already there. The second carries a selection this view moved, which is every
            // way into a pane except a click on the toolbar itself.
            .onChange(of: window, initial: true) { _, _ in apply() }
            .onChange(of: pane) { _, _ in apply() }
    }

    private func apply() {
        // Refreshed rather than set once, because the closure holds the binding it was made with
        // and a modifier is rebuilt on every update of the view above it.
        toolbar.onChoose = { pane = $0 }
        guard let window else { return }
        toolbar.install(on: window, showing: pane)
    }
}

extension View {
    /// Draws the project settings window's panes in its title bar, the way a Mac preferences
    /// window draws its own. See `RepoSettingsToolbar`.
    func choosesPaneInTheTitleBar(_ pane: Binding<RepoSettingsPane>) -> some View {
        modifier(RepoSettingsToolbarInstaller(pane: pane))
    }
}
