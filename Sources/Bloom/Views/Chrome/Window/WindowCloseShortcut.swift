import AppKit
import BloomCore

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
/// **Two halves, because the menu row and the keystroke are two different problems.** An earlier
/// version of this file had only the first half and claimed both, and the key did nothing at all
/// in a shipped build.
///
/// The first half is the row somebody reads. AppKit takes the key back off the standard Close
/// whenever the File menu is rebuilt, and SwiftUI rebuilds that whole menu every time the commands
/// body is re-evaluated, which on this app is several times a second while anything is moving. So
/// a chain of `DispatchQueue.main.async` at launch set the key onto an item that was replaced
/// milliseconds later, and stopped at the first success so it never noticed. Re-applying when the
/// menu begins tracking is what makes the row right, queued into the tracking runloop mode because
/// the strip happens after tracking has begun, and it was measured working: dumping the item over
/// accessibility before and after one opening of File shows it go from no key equivalent to `w`
/// with command and shift.
///
/// The second half is the keystroke, and it is why the first half is not enough on its own.
/// Opening a menu is the only thing that posts `didBeginTracking`, so until the user had pulled
/// File down once in that launch the item genuinely had no key and Shift+Cmd+W did nothing.
/// Measured the same way: on a fresh launch the key press was swallowed, and after one opening of
/// the File menu the same key press closed the front window. Nobody opens a menu to find out
/// whether its shortcut works, so the keystroke is caught before the menu is consulted at all. A
/// local monitor runs ahead of key equivalent dispatch, so once the row has its key back the two
/// cannot both fire: this one takes the event and returns nothing.
///
/// **The monitor also carries plain Cmd+W and Escape, and that is a repair rather than an
/// extra.** Moving the standard Close to Shift+Cmd+W above took Cmd+W off every window in the
/// app, because there is one standard Close and every window shares it. Close Session greys out
/// in every window but the workspace one, and a disabled item does not consume its key, so the
/// press fell through to a standard Close that was answering to a different key, and beeped. The
/// About window, Discovered Seas, Settings and each project's settings window all had a dead
/// Cmd+W, and the owner reported the first two. Escape is the other half and had never been
/// wired at all: a plain `NSWindow` does not close on Escape on this platform, only a panel with
/// a cancel button does. Which key may close which window is `WindowDismissal` in the core, with
/// its tests, and which window is which is `WindowRoles`.
///
/// **One monitor, for the life of the process, and nothing to tear down.** It is not attached to
/// a window: it resolves `NSApp.keyWindow` at the moment a key is pressed, so it cannot outlive
/// a window or fire at one that has gone. The role table it consults holds its windows weakly for
/// the same reason.
@MainActor
enum WindowCloseShortcut {
    private static let attempts = 40
    private static let spacing: TimeInterval = 0.1
    private static var monitor: Any?

    static func apply() {
        watchForTheKey()
        apply(remaining: attempts)
        // A process-lifetime observer on an enum with no instances, so there is no owner whose
        // deinit would remove it and no token worth keeping.
        // swiftlint:disable:next discarded_notification_center_observer
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

    /// The keystrokes themselves, independent of what any menu currently says.
    private static func watchForTheKey() {
        guard monitor == nil else { return }
        // The event never crosses into the main actor closure below, only the answer does. An
        // `NSEvent` is not `Sendable`, and a local monitor's handler is already called on the main
        // thread, so what is asserted is where this is running rather than that an event may move.
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard let stroke = stroke(for: event) else { return event }
            return MainActor.assumeIsolated { closeKeyWindow(on: stroke) } ? nil : event
        }
    }

    /// Which of the three this press is, or nothing, which is the answer for nearly every press
    /// the app will ever see and is why it is the first thing the monitor asks.
    ///
    /// Escape is read off the key code rather than off its character. `charactersIgnoringModifiers`
    /// for Escape is the escape character itself, which is a literal nothing wants to see in a
    /// source file and which a Ctrl+[ pressed in a terminal compares equal to.
    ///
    /// The W is the other way round, off the character rather than off a key code, and that is
    /// the layout the owner is actually on rather than a preference. This Mac is set to
    /// ABC-AZERTY: the key labelled W is virtual key 6 and virtual key 13 is Z. Matching the key
    /// code would have made Cmd+W the wrong key on his keyboard and stolen Cmd+Z from a window
    /// that has an undo in it. AppKit's own key equivalents match both, which is why the standard
    /// Close still answers to the ASCII position as well; nothing here needs to.
    private static func stroke(for event: NSEvent) -> WindowDismissal.Stroke? {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        // Bare Escape only. Anything held with it is somebody else's key, and a window that
        // vanished on Command+Escape would be swallowing a press aimed past the app entirely.
        if event.keyCode == escapeKeyCode { return modifiers.isEmpty ? .escape : nil }

        guard event.charactersIgnoringModifiers?.lowercased() == "w" else { return nil }
        if modifiers == [.command, .shift] { return .shiftCommandW }
        if modifiers == [.command] { return .commandW }
        return nil
    }

    private static let escapeKeyCode: UInt16 = 53

    /// True when the key press was spent on a window, so the caller knows to swallow it.
    ///
    /// It sends `performClose(_:)` rather than `close()`, so a window that has something to ask
    /// before it goes still gets to ask, and a window that refuses still gets to refuse with the
    /// same shudder Cmd+W would have drawn. A sheet is left alone by the rule it consults: the key
    /// window while a sheet is up is the sheet, and closing one from underneath its host is not
    /// what anybody meant.
    private static func closeKeyWindow(on stroke: WindowDismissal.Stroke) -> Bool {
        guard let window = NSApp.keyWindow,
              WindowDismissal.closes(stroke, WindowRoles.target(window))
        else { return false }
        window.performClose(nil)
        return true
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
