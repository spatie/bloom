#if DEBUG
import AppKit
import SwiftUI
import BloomCore

/// Performs a real menu item in a real window, and says which windows the app had before and
/// after.
///
///     Bloom --menu-action "Project settings…" [--menu-action-row 1]
///     Bloom --menu-action "Project Settings…" --menu-action-scope main
///     Bloom --menu-action "Project settings…" --menu-action-close commandW|escape
///     Bloom --menu-action "Project settings…" --menu-action-reopen
///     Bloom --menu-action "Project settings…" --menu-action-hide miniaturize|orderOut
///
/// **It exists because "the window did not open" is the one report the test suite cannot answer.**
/// `Tests/BloomCoreTests` links the core alone, so nothing there knows a scene exists;
/// `MenuProbe` builds a menu's items from the same views and photographs them, which says what a
/// menu offers and nothing about what an item DOES. Worse, a view built by hand sits in no scene,
/// so an `@Environment(\.openWindow)` read inside one resolves to an action with nothing to open:
/// the very failure somebody would reach for `MenuProbe` to investigate is a failure `MenuProbe`
/// would manufacture. So this goes the other way round. The menu is the app's own, hanging off the
/// app's own window, and the item is sent the way a click sends it.
///
/// **Contextual menus are read off `NSView.menu`, not off `menu(for:)`.** SwiftUI attaches a
/// `.contextMenu` to the cell's hosting view as a plain `NSMenu` with a delegate that fills it in
/// `menuNeedsUpdate`, so it has to be `update()`d before it has any rows, and asking the view what
/// menu a right click would produce answers nil. Both were measured: `menu(for:)` over the whole
/// hierarchy found one unrelated popup, and driving a synthetic right click caught a session whose
/// menu held a single empty placeholder and never filled.
///
/// `--menu-action-close` presses one of the two keys `WindowDismissal` rules on at the window the
/// item opened, through the local monitor a real press goes through, which is the other half of the
/// same question: a window that opens and cannot be closed again is no better than one that never
/// opened. **It only says anything while this app is the front one.** The monitor resolves
/// `NSApp.keyWindow` at the moment of the press and there is no key window in an app that is not
/// active, so a run alongside somebody else's session reports no window rather than a window that
/// refused, and the line above the verdict says which of the two it was. `--menu-action-reopen` is the cycle an owner performs rather than a single press: open it,
/// close it the way the app lets him close it, and ask for it again. `--menu-action-hide` is the
/// other half of the same worry, since `openWindow` with a value some window already carries opens
/// no second window: it hides the window first, by the two ways a window goes out of sight without
/// closing, and asks again.
///
/// Debug builds only, and it wants `BLOOM_DB_PATH` pointed at a scratch database with a project in
/// it, for the reason `MenuProbe`'s row parts want one.
@MainActor
enum MenuActionProbe {
    static var isRequested: Bool { CommandLine.arguments.contains("--menu-action") }

    static func schedule() {
        // The report is the whole output and a run that is killed for taking too long should still
        // have printed what it got to. Unbuffered, because a pipe is not a terminal and the first
        // run of this lost every line it had printed before it hung.
        setvbuf(stdout, nil, _IONBF, 0)

        Task { @MainActor in
            // The beat `Snapshot` waits for, for the same reason: the sidebar is drawn from the
            // database and a menu cannot be found on a row that is not there yet.
            try? await Task.sleep(for: .seconds(4))

            guard let window = mainWindow else {
                report("no main window; had \(NSApp.windows.map(\.title))")
                exit(1)
            }
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            try? await Task.sleep(for: .seconds(1))

            let before = secondaryWindows()
            report("windows before: \(windowTitles())")

            guard let (menu, index) = item(titled: wantedTitle) else {
                report("no \(scope.rawValue) menu carries an item called \(wantedTitle)")
                exit(2)
            }
            report("item: \(menu.items[index].title), enabled \(menu.items[index].isEnabled)")

            menu.performActionForItem(at: index)
            try? await Task.sleep(for: .seconds(2))
            report("windows after: \(windowTitles())")

            // Whichever secondary window is there now and was not before, so a copy that macOS
            // restored at launch is never mistaken for the one this press opened. A press that
            // brought a restored window forward opened nothing, and the two cycles below say so
            // rather than reporting on a window they did not cause.
            let after = secondaryWindows()
            let fresh = after.first { window in !before.contains { $0 === window } }
            report("opened: \(fresh?.title ?? "nothing new")")
            // A press that raised a window macOS had already restored opened nothing, and the
            // cycles below still have a window to ask about: the frontmost secondary one, which is
            // what the press just brought forward.
            opened = fresh ?? after.first
            report("acting on: \(opened?.title ?? "no window")")

            if let stroke = closingStroke { await close(with: stroke) }
            if let how = hiding { await askAgain(after: how, menu: menu) }
            if wantsReopen { await closeAndAskAgain(menu: menu) }
            exit(0)
        }
    }

    // MARK: - The three cycles

    /// Presses Escape or Cmd+W at the window the item opened, through the same local monitor a
    /// real press goes through. See `WindowCloseShortcut`, and `WindowDismissal` for which of them
    /// is supposed to close what.
    private static func close(with stroke: WindowDismissal.Stroke) async {
        guard let opened else { return report("nothing was opened to press a key at") }
        opened.makeKeyAndOrderFront(nil)
        try? await Task.sleep(for: .seconds(1))
        report("key window: \(NSApp.keyWindow?.title ?? "none")")

        let escape = stroke == .escape
        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            // The character and not the key code, which is the layout this Mac is really on. See
            // `WindowCloseShortcut.stroke(for:)`.
            modifierFlags: escape ? [] : (stroke == .commandW ? [.command] : [.command, .shift]),
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: opened.windowNumber,
            context: nil,
            characters: escape ? "\u{1B}" : "w",
            charactersIgnoringModifiers: escape ? "\u{1B}" : "w",
            isARepeat: false,
            keyCode: escape ? 53 : 13
        ) else { return report("could not build the key press") }

        NSApp.postEvent(event, atStart: true)
        try? await Task.sleep(for: .seconds(2))
        report("after \(stroke.rawValue): windows \(windowTitles())")
    }

    private static var closingStroke: WindowDismissal.Stroke? {
        value(for: "--menu-action-close").flatMap(WindowDismissal.Stroke.init(rawValue:))
    }

    // MARK: - The two reopening cycles

    /// Hides the window the item opened, then asks for it again.
    private static func askAgain(after hiding: String, menu: NSMenu) async {
        guard let opened = opened else { return report("nothing was opened to hide") }
        switch hiding {
        case "miniaturize": opened.miniaturize(nil)
        case "orderOut": opened.orderOut(nil)
        default: return report("unknown way of hiding a window: \(hiding)")
        }
        try? await Task.sleep(for: .seconds(2))
        report("hidden by \(hiding): visible \(opened.isVisible), miniaturized \(opened.isMiniaturized)")

        perform(wantedTitle, in: menu)
        try? await Task.sleep(for: .seconds(3))
        report("asked again: visible \(opened.isVisible), miniaturized \(opened.isMiniaturized)")
        report("windows now: \(windowTitles())")
    }

    /// Closes the window the item opened the way the app closes it, then asks for it again.
    private static func closeAndAskAgain(menu: NSMenu) async {
        guard let opened = opened else { return report("nothing was opened to close") }
        // `performClose(_:)` and not `close()`, because that is what Cmd+W and the red button both
        // send and it is the half a window is allowed to refuse. See `WindowCloseShortcut`.
        opened.performClose(nil)
        try? await Task.sleep(for: .seconds(2))
        report("windows after close: \(windowTitles())")

        perform(wantedTitle, in: menu)
        try? await Task.sleep(for: .seconds(3))
        report("windows after asking again: \(windowTitles())")
    }

    /// The window the press opened, or nothing when it opened none.
    private static var opened: NSWindow?

    /// Every window that is not the main one and not the menu bar's.
    private static func secondaryWindows() -> [NSWindow] {
        let main = mainWindow
        return NSApp.windows.filter {
            $0.isVisible && $0 !== main && $0.styleMask.contains(.titled) && $0.contentView != nil
        }
    }

    // MARK: - Finding the item

    private enum Scope: String {
        /// A contextual menu hanging off a view in the window.
        case context
        /// The app's own menu bar.
        case main
    }

    private static var scope: Scope {
        value(for: "--menu-action-scope").flatMap(Scope.init(rawValue:)) ?? .context
    }

    private static var wantedTitle: String { value(for: "--menu-action") ?? "Project settings…" }
    private static var wantsReopen: Bool { CommandLine.arguments.contains("--menu-action-reopen") }
    private static var hiding: String? { value(for: "--menu-action-hide") }

    private static func item(titled title: String) -> (NSMenu, Int)? {
        switch scope {
        case .main: mainMenuItem(titled: title)
        case .context: contextMenuItem(titled: title)
        }
    }

    private static func mainMenuItem(titled title: String) -> (NSMenu, Int)? {
        for top in NSApp.mainMenu?.items ?? [] {
            guard let submenu = top.submenu else { continue }
            submenu.update()
            if let index = submenu.items.firstIndex(where: { $0.title == title }) {
                return (submenu, index)
            }
        }
        return nil
    }

    private static func contextMenuItem(titled title: String) -> (NSMenu, Int)? {
        guard let content = mainWindow?.contentView else { return nil }
        var matches: [(NSMenu, Int)] = []
        walk(content) { view in
            guard let menu = view.menu else { return }
            menu.update()
            guard let index = menu.items.firstIndex(where: { $0.title == title }) else { return }
            matches.append((menu, index))
        }
        // Which row's menu, for a title several rows offer. The sidebar has one project header per
        // project and every one of them carries this item.
        let wanted = value(for: "--menu-action-row").flatMap(Int.init) ?? 0
        return wanted < matches.count ? matches[wanted] : matches.first
    }

    private static func perform(_ title: String, in menu: NSMenu) {
        menu.update()
        guard let index = menu.items.firstIndex(where: { $0.title == title }) else {
            return report("the item is no longer in the menu")
        }
        menu.performActionForItem(at: index)
    }

    // MARK: - Reading the app back

    private static var mainWindow: NSWindow? {
        NSApp.windows.first { $0.title == "Bloom" && $0.contentView != nil }
    }

    /// Front to back, which is the order the question is actually about. `NSApp.windows` is not
    /// ordered; `NSApp.orderedWindows` is, and a window that came back behind the one the owner is
    /// looking at is indistinguishable from a window that never came back at all.
    private static func windowTitles() -> [String] {
        NSApp.orderedWindows
            .filter { $0.isVisible && $0.contentView != nil }
            .map { "\($0.title.isEmpty ? "<untitled>" : $0.title)\($0.isKeyWindow ? " [key]" : "")" }
    }

    private static func report(_ line: String) {
        print("MENU ACTION: \(line)")
    }

    private static func walk(_ view: NSView, _ visit: (NSView) -> Void) {
        visit(view)
        for subview in view.subviews { walk(subview, visit) }
    }

    private static func value(for flag: String) -> String? {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else {
            return nil
        }
        return arguments[index + 1]
    }
}
#endif
