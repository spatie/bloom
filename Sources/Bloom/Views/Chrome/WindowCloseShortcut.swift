import AppKit

/// Gives File > Close the Shift+Cmd+W that Safari and Terminal give it when Cmd+W has gone to
/// something smaller than a window.
///
/// Bloom's Cmd+W closes the session, deliberately: the window lists every workspace and every
/// agent in the app, so closing it on the reflex that closes a tab everywhere else used to end the
/// process and every running turn with it. What that leaves behind is a File > Close with no key
/// at all, which is the item somebody actually wants when they do mean the window. Safari and
/// Terminal have both been in exactly this position for twenty years and both answer it the same
/// way, so this is the convention rather than an invention.
///
/// It is done in AppKit rather than in `BloomCommands` because SwiftUI has no command group that
/// names this item. It is contributed by the window scene itself, and `CommandGroupPlacement` has
/// no placement that replaces it: the closest, `.saveItem`, sits above it and is a different
/// group. Adding a second Close of Bloom's own would have meant two items called Close in one
/// menu, which is the fault the audit before this one had just finished removing from Window.
///
/// Retried rather than done once. The main menu is assembled by SwiftUI around the first scene,
/// and whether that has happened by `applicationDidFinishLaunching` is not something to depend on;
/// each attempt is cheap and the loop stops the moment it lands.
@MainActor
enum WindowCloseShortcut {
    private static let attempts = 10

    static func apply() {
        apply(remaining: attempts)
    }

    private static func apply(remaining: Int) {
        if applyOnce() || remaining <= 1 { return }
        DispatchQueue.main.async { apply(remaining: remaining - 1) }
    }

    /// Found by action rather than by title, because the title is localised and the action is not.
    /// `performClose(_:)` is what AppKit's own Close item sends and nothing else in the File menu
    /// sends it.
    private static func applyOnce() -> Bool {
        guard let item = closeItem() else { return false }
        item.keyEquivalent = "w"
        item.keyEquivalentModifierMask = [.command, .shift]
        return true
    }

    private static func closeItem() -> NSMenuItem? {
        for top in NSApp.mainMenu?.items ?? [] {
            for item in top.submenu?.items ?? []
            where item.action == #selector(NSWindow.performClose(_:)) {
                return item
            }
        }
        return nil
    }
}
