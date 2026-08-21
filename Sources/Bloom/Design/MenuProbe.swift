#if DEBUG
import AppKit
import SwiftUI
import BloomCore

/// Photographs the centre pane's contextual menu, or the items one of its split submenus offers.
///
///     Bloom --menu-probe /tmp/menu.png [--menu-part menu|kinds]
///
/// It exists because a menu is the one part of this interface that cannot be captured any other
/// way. `ImageRenderer` draws SwiftUI's yellow placeholder for one, a menu only exists while it is
/// being tracked, and `screencapture -l` handed a menu window's number returns the whole display on
/// this machine, which would put whatever the owner happens to be doing into a PNG. So the menu is
/// built here, opened here, measured here, and the capture is a rectangle exactly the size of the
/// menu's own windows: opaque menu pixels and nothing else.
///
/// The menus are the real ones. `CenterPaneMenu` and `PaneKindItems` are the same two views
/// `CenterPaneView` hands to `.contextMenu`, built here with closures that do nothing, so a picture
/// taken by this probe cannot show an item the app does not have.
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

    /// Which menu to open: the pane's own, or the three items a split submenu is made of.
    private static var wantsKinds: Bool {
        value(for: "--menu-part") == "kinds"
    }

    static func schedule() {
        Task { @MainActor in
            // The same beat the window capture waits for, and for the same reason: the window has
            // to exist before a menu can be opened over it.
            try? await Task.sleep(for: .seconds(3))
            run()
        }
    }

    private static func run() {
        guard let window = NSApp.windows.first(where: {
            $0.isVisible && $0.contentView != nil && $0.parent == nil && $0.styleMask.contains(.titled)
        }) else {
            fail("no window to open a menu from")
        }

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)

        // Split, so the pane menu carries every item it can carry: Close Pane is only offered when
        // there is a pane to close back to.
        let menu: NSMenu = wantsKinds
            ? NSHostingMenu(rootView: PaneKindItems { _ in })
            : NSHostingMenu(rootView: CenterPaneMenu(isSplit: true, split: { _, _ in }, close: {}))

        // Over the app's own window, so the menu is the only thing in the rectangle below it.
        let origin = NSPoint(x: window.frame.minX + 260, y: window.frame.maxY - 220)

        // Tried more than once, because the owner is at this machine: a click anywhere else on the
        // desktop dismisses a menu this process opened, and a run that gave up on the first one
        // reported a failure that was really somebody typing.
        for _ in 0..<6 where !capturedOutput {
            // The capture has to run while the menu is tracking, and tracking is its own run loop
            // mode: `popUp` does not return until the menu closes. A timer added to the common
            // modes is delivered inside it, which is why it is scheduled before the menu opens
            // rather than written after it.
            let timer = after(0.4) {
                capturedOutput = capture(to: outputPath)
                menu.cancelTracking()
            }
            menu.popUp(positioning: nil, at: origin, in: nil)
            timer.invalidate()
        }

        guard capturedOutput else { fail("the menu would not stay open long enough to photograph") }
        print(outputPath)
        exit(0)
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
