import AppKit
import SwiftUI
import BloomCore

/// What each of Bloom's windows is, as far as Escape and Cmd+W are concerned.
///
/// The rule the two keys follow is `WindowDismissal` in the core, with its tests. This is the half
/// that cannot be tested, because it is a table of live `NSWindow`s.
///
/// **The main window is the one that is never marked.** That is deliberate and it is the whole
/// reason the table works the way round it does. A missed mark on a secondary window leaves that
/// window with the bug this file exists to fix, which is a nuisance; a missed mark on the main
/// window would hand Cmd+W to its close button instead of to Close Session, which is the thing the
/// menu item was scoped to prevent. So an unknown window is `.workspace`, the cautious answer, and
/// only the four windows that are not the workspace say so.
///
/// Weak keys, because a window that has been closed and released must not be held alive by a
/// table of keyboard trivia, and because the About and welcome windows are reused: the same
/// `NSWindow` comes back on the second visit and keeps the mark it was given on the first.
@MainActor
enum WindowRoles {
    private static let marks = NSMapTable<NSWindow, NSString>.weakToStrongObjects()

    static func mark(_ window: NSWindow, as role: WindowDismissal.Role) {
        marks.setObject(role.rawValue as NSString, forKey: window)
    }

    /// Everything the rule in the core needs to know about a window, read off the window itself.
    static func target(_ window: NSWindow) -> WindowDismissal.Target {
        WindowDismissal.Target(
            role: role(of: window),
            // Not "does it draw a close button": AppKit draws one for a window whose style mask
            // lacks `.closable` and `performClose(_:)` on that window does nothing but beep.
            isClosable: window.styleMask.contains(.closable),
            isSheet: window.isSheet,
            hasAttachedSheet: window.attachedSheet != nil
        )
    }

    private static func role(of window: NSWindow) -> WindowDismissal.Role {
        guard let raw = marks.object(forKey: window) as String?,
              let role = WindowDismissal.Role(rawValue: raw)
        else { return .workspace }
        return role
    }
}

/// Marks the window a scene's content is in, for scenes SwiftUI builds the window for.
///
/// The two windows built by hand, About and welcome, call `WindowRoles.mark` on the window
/// themselves and have no use for this.
private struct WindowRoleMarker: ViewModifier {
    let role: WindowDismissal.Role

    @State private var window: NSWindow?

    func body(content: Content) -> some View {
        content
            .background(WindowAccessor(window: $window))
            .onChange(of: window, initial: true) { _, _ in
                guard let window else { return }
                WindowRoles.mark(window, as: role)
            }
    }
}

extension View {
    func windowRole(_ role: WindowDismissal.Role) -> some View {
        modifier(WindowRoleMarker(role: role))
    }
}
