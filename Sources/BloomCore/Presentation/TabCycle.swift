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

    /// The tab a number reaches: Cmd+1 to Cmd+8 are the first eight, and Cmd+9 is the last one
    /// whatever the count.
    ///
    /// Safari, Terminal and Xcode all bind these and all give 9 to the last tab rather than to the
    /// ninth, which is the half of the convention that is easy to miss and the half that makes it
    /// worth having: the two ends of the strip are one keystroke away from anywhere in it. In a
    /// strip of five tabs, reaching the fifth was four presses of Cmd+Shift+].
    ///
    /// Nil for a number past the end of a short strip, so the item greys rather than landing
    /// somewhere arbitrary.
    public static func tab<Tab>(at ordinal: Int, in tabs: [Tab]) -> Tab? {
        guard (1...9).contains(ordinal), !tabs.isEmpty else { return nil }
        if ordinal == lastOrdinal { return tabs.last }
        return ordinal <= tabs.count ? tabs[ordinal - 1] : nil
    }

    /// The strip with the number each tab answers to, for the menu that draws them.
    ///
    /// Every tab is listed, because a menu that hid the tenth would be lying about what is open.
    /// Only the ones a key can reach carry a number: the first eight, and the last, which takes 9
    /// away from a ninth tab whenever there are more than nine.
    public static func numbered<Tab: Hashable>(_ tabs: [Tab]) -> [Numbered<Tab>] {
        tabs.enumerated().map { index, tab in
            if index == tabs.count - 1, tabs.count >= lastOrdinal {
                return Numbered(tab: tab, ordinal: lastOrdinal)
            }
            return Numbered(tab: tab, ordinal: index < lastOrdinal - 1 ? index + 1 : nil)
        }
    }

    /// A tab and the number that reaches it, if any.
    ///
    /// A type rather than a tuple because the menu draws these in a `ForEach` and Swift has no key
    /// path to a tuple element. It is identified by the tab, which is a strip entry and therefore
    /// already unique in the list it came from.
    public struct Numbered<Tab: Hashable>: Hashable, Identifiable, Sendable where Tab: Sendable {
        public let tab: Tab
        public let ordinal: Int?

        public var id: Tab { tab }
    }

    private static let lastOrdinal = 9
}
