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
/// Retried on a clock rather than done once, and re-applied whenever a menu opens.
///
/// The first attempt was a plain chain of `DispatchQueue.main.async`, which is wrong in a way that
/// is easy to miss: ten async hops all run in the same handful of milliseconds, long before
/// SwiftUI has built the main menu, so all ten found nothing and the item shipped with no key.
/// Measured, by photographing the File menu of a build that had it. The retries are spaced now,
/// and the observer under them is the belt: SwiftUI rebuilds the main menu when the commands body
/// is re-evaluated, and a rebuilt Close arrives with AppKit's own key equivalent back on it.
@MainActor
enum WindowCloseShortcut {
    private static let attempts = 40
    private static let spacing: TimeInterval = 0.1

    static func apply() {
        apply(remaining: attempts)
        // AppKit takes the key back off this item every time the File menu updates. Measured, by
        // dumping the item before and after one opening: it goes from `w` with command and shift
        // to no key equivalent at all. That is AppKit's own management of the standard Close, and
        // it is the reason the item had no key to begin with, so setting it once at launch is not
        // enough and re-applying on `didBeginTracking` is not either: the strip happens after
        // tracking has begun.
        //
        // So the re-apply is queued into the tracking runloop mode, which is the earliest moment
        // that runs AFTER the update, and the menu is told the item changed so the row it has
        // already laid out is drawn again.
        NotificationCenter.default.addObserver(
            forName: NSMenu.didBeginTrackingNotification, object: nil, queue: nil
        ) { _ in
            RunLoop.main.perform(inModes: [.eventTracking, .default, .common]) {
                MainActor.assumeIsolated {
                    guard let item = closeItem() else { return }
                    item.keyEquivalent = "w"
                    item.keyEquivalentModifierMask = [.command, .shift]
                    item.menu?.itemChanged(item)
                }
            }
        }
    }

    private static func apply(remaining: Int) {
        if applyOnce() || remaining <= 1 { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + spacing) {
            apply(remaining: remaining - 1)
        }
    }

    /// Found by action rather than by title, because the title is localised and the action is not.
    /// `performClose(_:)` is what AppKit's own Close item sends and nothing else in the File menu
    /// sends it.
    private static func applyOnce() -> Bool {
        guard let item = closeItem() else { return false }
        guard item.keyEquivalentModifierMask != [.command, .shift] else { return true }
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
