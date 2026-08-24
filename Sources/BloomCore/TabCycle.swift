import Foundation

/// Which tab Next Tab and Previous Tab land on.
///
/// This existed nowhere, in either sense: no function decided it and no keystroke asked. The
/// centre column's five kinds of tab can all be **opened** from the keyboard and none of them
/// could be **moved between** without the pointer. The full `keyboardShortcut` grep across the app
/// found 74 bindings and not one for `[`, `]`, Ctrl+Tab or Cmd+1, and there was no Next Tab menu
/// item to carry one. Safari, Terminal, Xcode and Finder all bind Cmd+Shift+[ and ].
///
/// It wraps, which is what every one of those four does and what makes a single shortcut enough to
/// reach any tab in a strip of three or four.
public enum TabCycle {
    /// The tab an offset away from the current one, wrapping at both ends.
    ///
    /// Nil only when there is nothing to move to: an empty strip, or a strip of one, where every
    /// answer is the tab you are already on and returning it would redraw for nothing.
    ///
    /// A current tab that is not in the strip lands on the first, which is the honest answer to a
    /// question about a tab that has just been closed underneath the shortcut.
    public static func next<Tab: Equatable>(
        from current: Tab?, in tabs: [Tab], offset: Int
    ) -> Tab? {
        guard tabs.count > 1 else { return nil }
        guard let current, let index = tabs.firstIndex(of: current) else { return tabs.first }

        let count = tabs.count
        // Modulo twice, because Swift's `%` keeps the sign of the dividend and a negative offset
        // on the first tab would index off the front.
        let moved = ((index + offset) % count + count) % count
        return moved == index ? nil : tabs[moved]
    }
}
