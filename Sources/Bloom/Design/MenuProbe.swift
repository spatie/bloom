#if DEBUG
import AppKit
import SwiftUI
import BloomCore

/// Photographs the centre pane's contextual menu, or the items one of its split submenus offers.
///
///     Bloom --menu-probe /tmp/menu.png [--menu-part menu|kinds|terminal|terminalKinds|row|colour|style] [--menu-project <path>]
///
/// It exists because a menu is the one part of this interface that cannot be captured any other
/// way. `ImageRenderer` draws SwiftUI's yellow placeholder for one, a menu only exists while it is
/// being tracked, and `screencapture -l` handed a menu window's number returns the whole display on
/// this machine, which would put whatever the owner happens to be doing into a PNG. So the menu is
/// built here, opened here, measured here, and the capture is a rectangle exactly the size of the
/// menu's own windows: opaque menu pixels and nothing else.
///
/// The menus are the real ones. `CenterPaneMenu`, `PaneKindItems` and `WorkspaceMenuItems` are the
/// same views the app hands to `.contextMenu`, built here with closures that do nothing, so a
/// picture taken by this probe cannot show an item the app does not have.
///
/// `terminal` is the odd one and is the reason `present` exists. It is `TerminalPaneMenu`, put up
/// through a real `BloomTerminalView`'s right mouse handling rather than through `NSMenu.popUp`,
/// because those two do not draw the same menu: AppKit merges the text input system's own items
/// into a contextual menu as it presents it, and they never appear in `NSMenu.items` at all. A
/// picture taken the easy way would be a picture of a menu the app never shows.
///
/// `row` and `colour` are a workspace row's menu and the colour submenu inside it. They need a
/// workspace, so they read one out of the database this instance was pointed at, which means they
/// want `BLOOM_DB_PATH` set at a seeded scratch copy rather than the owner's.
///
/// `style` is the composer's output style picker. Its list is read off disk rather than written
/// down, so `--menu-project` points it at a checkout whose `.claude/output-styles` should be in
/// the picture. Without one the shot is the built in styles alone, which is what almost every
/// machine has.
///
/// The two are photographed separately because AppKit tracks one menu at a time. A submenu cannot
/// be opened beside the item it hangs off from inside the process: popping the submenu up while its
/// parent is open ends the parent's session, and hovering is not available either, since AppKit
/// highlights on mouse MOVEMENT and the only pointer on this machine is the owner's. A menu that
/// merely appears under a stationary pointer highlights nothing, which is what the first attempt at
/// this photographed.
///
/// Nothing is clicked, nothing is typed and the pointer is never moved.
///
/// Debug builds only. A shipped copy has no business being able to open a menu nobody asked for.
@MainActor
enum MenuProbe {
    static var isRequested: Bool {
        CommandLine.arguments.contains("--menu-probe")
    }

    private static func value(for flag: String) -> String? {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else {
            return nil
        }
        return arguments[index + 1]
    }

    private static var outputPath: String {
        value(for: "--menu-probe") ?? (NSTemporaryDirectory() + "bloom-menu.png")
    }

    /// Which menu to open. `menu` is the pane's own and is the default.
    private enum Part: String {
        case menu
        /// The three items a split submenu is made of.
        case kinds
        /// A terminal pane's own menu, put up the way a right click puts it up.
        case terminal
        /// The three items one of its split submenus is made of.
        case terminalKinds
        /// A workspace row's context menu, as both lists offer it.
        case row
        /// The colour submenu inside it, on its own, because AppKit tracks one menu at a time.
        case colour
        /// The composer's output style picker, rows and describing footnote.
        case style
    }

    private static var part: Part {
        value(for: "--menu-part").flatMap(Part.init(rawValue:)) ?? .menu
    }

    static func schedule() {
        Task { @MainActor in
            // The same beat the window capture waits for, and for the same reason: the window has
            // to exist before a menu can be opened over it.
            try? await Task.sleep(for: .seconds(3))
            // A model of this probe's own, rather than the one the window is drawing from, which
            // no static can reach. It reads the same database, so the workspace it finds is a
            // workspace the sidebar is showing.
            var model: AppModel?
            if part == .row || part == .colour {
                let fresh = AppModel()
                await fresh.bootstrap()
                model = fresh
            }
            // Read before the menu is built, because building it is synchronous and the scan is a
            // walk of two directories. An empty catalogue would photograph as the built in list.
            if part == .style {
                await outputStyles.refreshIfStale(project: value(for: "--menu-project"))
            }
            run(model: model)
        }
    }

    private static func run(model: AppModel?) {
        guard let window = NSApp.windows.first(where: {
            $0.isVisible && $0.contentView != nil && $0.parent == nil && $0.styleMask.contains(.titled)
        }) else {
            fail("no window to open a menu from")
        }

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)

        let menu = build(model: model)

        // Over the app's own window, so the menu is the only thing in the rectangle below it.
        let origin = NSPoint(x: window.frame.minX + 260, y: window.frame.maxY - 220)

        // Tried more than once, because the owner is at this machine: a click anywhere else on the
        // desktop dismisses a menu this process opened, and a run that gave up on the first one
        // reported a failure that was really somebody typing.
        for _ in 0..<6 where !capturedOutput {
            // The capture has to run while the menu is tracking, and tracking is its own run loop
            // mode: presenting does not return until the menu closes. A timer added to the common
            // modes is delivered inside it, which is why it is scheduled before the menu opens
            // rather than written after it.
            let timer = after(0.4) {
                capturedOutput = capture(to: outputPath)
                menu.cancelTracking()
            }
            present(menu, at: origin, in: window)
            timer.invalidate()
        }

        guard capturedOutput else { fail("the menu would not stay open long enough to photograph") }
        print(outputPath)
        exit(0)
    }

    /// Puts the menu on screen, and does not return until it closes again.
    ///
    /// Two ways, because there are two menus. `NSMenu.popUp` is the plain one and is what every
    /// SwiftUI menu here is photographed with. The terminal's goes up the way a right click puts
    /// it up, through `BloomTerminalView`, because AppKit adds items of its own on that path and
    /// only on that path, and whether they are there is the whole question this picture answers.
    private static func present(_ menu: NSMenu, at origin: NSPoint, in window: NSWindow) {
        guard part == .terminal, let pane = terminalPane, let content = window.contentView else {
            menu.popUp(positioning: nil, at: origin, in: nil)
            return
        }

        // In the window, because a view outside one has no window number to put on the event, and
        // AppKit hit tests the contextual menu against the window the event names.
        if pane.superview == nil {
            pane.frame = content.bounds
            content.addSubview(pane)
        }

        let point = NSPoint(x: 260, y: content.bounds.height - 220)
        guard let event = NSEvent.mouseEvent(
            with: .rightMouseDown,
            location: point,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ) else { fail("could not build a right click to open the terminal's menu with") }

        pane.rightMouseDown(with: event)
    }

    /// The shell the terminal menu is photographed over. No process is ever started in it: it is
    /// here to be the `NSView` AppKit asks for a menu, and an empty one draws the same.
    private static let terminalPane: BloomTerminalView? = {
        guard MenuProbe.part == .terminal else { return nil }
        return BloomTerminalView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
    }()

    /// The menu this run photographs, built from the very views the app shows.
    private static func build(model: AppModel?) -> NSMenu {
        switch part {
        // Split, so the pane menu carries every item it can carry: Close Pane is only offered
        // when there is a pane to close back to.
        case .menu:
            NSHostingMenu(rootView: CenterPaneMenu(isSplit: true, split: { _, _ in }, close: {}))
        case .kinds:
            NSHostingMenu(rootView: PaneKindItems { _ in })
        case .terminal:
            terminalMenu()
        // The submenu on its own, for the reason the two centre menus are separate parts.
        case .terminalKinds:
            terminalSplitKinds()
        case .row, .colour:
            workspaceMenu(model: model)
        case .style:
            NSHostingMenu(rootView: outputStyleItems)
        }
    }

    /// The pane menu a split terminal offers, with every item it can carry: Close Pane is only
    /// offered when there is a pane to close back to.
    private static func terminalMenu() -> NSMenu {
        let menu = TerminalPaneMenu.make(canClose: true, isZoomed: false) { _ in }
        // The view answers with this one, which is what puts it through AppKit's own contextual
        // menu path rather than round it. See `present`.
        terminalPane?.onContextMenu = { menu }
        return menu
    }

    private static func terminalSplitKinds() -> NSMenu {
        let menu = TerminalPaneMenu.make(canClose: true, isZoomed: false) { _ in }
        guard let kinds = menu.items.first?.submenu else {
            fail("the terminal pane menu has no split submenu")
        }
        // The parent is kept, not just the submenu. It is the menu that owns the items' action
        // target, `NSMenuItem.target` is weak, and a menu whose target has gone validates every
        // row against the responder chain instead and draws the lot greyed out. That is what the
        // first picture of this submenu was.
        parentOfKinds = menu
        return kinds
    }

    private static var parentOfKinds: NSMenu?

    /// The output style picker's own rows, built from the same catalogue and the same item view
    /// the composer's footer uses. Selected on Concise, which is the style this menu was added
    /// for, so the picture shows both the tick and the sentence that goes with it.
    private static let outputStyles = ComposerOutputStyleCatalog()

    private static var outputStyleItems: ComposerOptionItems {
        let selection = "Concise"
        return ComposerOptionItems(
            options: outputStyles.options(includingCurrent: selection),
            footnote: outputStyles.detail(of: selection),
            selection: selection,
            heading: "Output style",
            help: "Choose the output style",
            onSelect: { _ in }
        )
    }

    private static func workspaceMenu(model: AppModel?) -> NSMenu {
        guard let model, let workspace = model.workspaces.first else {
            fail("no workspace in this database to draw a row menu for")
        }
        let menu = NSHostingMenu(
            rootView: WorkspaceMenuItems(workspace: workspace) { _ in }.environment(model)
        )
        guard part == .colour else { return menu }
        // The submenu on its own. Popping it up beside its open parent is not available: that ends
        // the parent's tracking session, which is the same limit the two pane menus are split for.
        guard let submenu = menu.items.first(where: { $0.title == "Colour" })?.submenu else {
            fail("the row menu has no Colour submenu")
        }
        return submenu
    }

    /// Whether a picture has been taken, which is what stops the retry loop above.
    private static var capturedOutput = false

    // MARK: - Capture

    /// The rectangle the open menu covers, in the coordinates `screencapture -R` speaks.
    ///
    /// Read from the window server rather than from `NSMenu.size`, because a menu is placed by
    /// AppKit as it opens and shifts itself off a screen edge without saying so. Only windows
    /// belonging to THIS process are considered, and only ones at the menu level, so the rectangle
    /// can never be larger than the menu itself.
    private static func menuBounds() -> CGRect? {
        let listed = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID)
        guard let windows = listed as? [[String: Any]] else { return nil }

        let menuLevel = CGWindowLevelForKey(.popUpMenuWindow)
        var union: CGRect?
        for window in windows {
            guard window[kCGWindowOwnerPID as String] as? pid_t == getpid(),
                  let level = window[kCGWindowLayer as String] as? Int, level >= menuLevel,
                  let raw = window[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: raw), !frame.isEmpty else { continue }
            union = union.map { $0.union(frame) } ?? frame
        }
        return union
    }

    private static func capture(to path: String) -> Bool {
        guard let bounds = menuBounds() else { return false }
        try? FileManager.default.removeItem(atPath: path)

        let capture = Process()
        capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        // `-R` is a rectangle rather than a display or a window, and this one is the menu's own
        // bounds, which the menu is painted over completely. `-x` keeps it silent.
        capture.arguments = [
            "-x",
            "-R\(Int(bounds.minX)),\(Int(bounds.minY)),\(Int(bounds.width)),\(Int(bounds.height))",
            path,
        ]
        do {
            try capture.run()
        } catch {
            return false
        }
        capture.waitUntilExit()
        return capture.terminationStatus == 0 && FileManager.default.fileExists(atPath: path)
    }

    // MARK: - Plumbing

    /// A timer in the common modes, which menu tracking is one of. `DispatchQueue.main.asyncAfter`
    /// is not: a block posted that way sits in the queue until the menu closes, which is exactly
    /// too late to photograph it.
    @discardableResult
    private static func after(
        _ seconds: TimeInterval, _ work: @escaping @MainActor () -> Void
    ) -> Timer {
        let timer = Timer(timeInterval: seconds, repeats: false) { _ in
            MainActor.assumeIsolated { work() }
        }
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("\(message)\n".utf8))
        exit(1)
    }
}
#endif
