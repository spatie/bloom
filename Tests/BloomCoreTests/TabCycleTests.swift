import Testing
@testable import BloomCore

/// Next Tab and Previous Tab, which the app had neither of.
///
/// Every kind of centre tab could be opened from the keyboard and none of them could be moved
/// between without the pointer: 74 keyboard shortcuts in the app and not one for `[`, `]`,
/// Ctrl+Tab or Cmd+1, and no menu item to carry one.
@Suite("Cycling the centre tabs")
struct TabCycleTests {
    private let tabs = ["chat", "diff", "terminal"]

    @Test("forwards and backwards move one")
    func movesOne() {
        #expect(TabCycle.next(from: "chat", in: tabs, offset: 1) == "diff")
        #expect(TabCycle.next(from: "diff", in: tabs, offset: -1) == "chat")
    }

    /// Wrapping is what makes one shortcut enough to reach any tab, and it is what Safari,
    /// Terminal, Xcode and Finder all do.
    @Test("both ends wrap")
    func bothEndsWrap() {
        #expect(TabCycle.next(from: "terminal", in: tabs, offset: 1) == "chat")
        #expect(TabCycle.next(from: "chat", in: tabs, offset: -1) == "terminal")
    }

    /// Swift's `%` keeps the sign of the dividend, so a negative offset on the first tab indexes
    /// off the front of the array unless it is taken twice.
    @Test("an offset larger than the strip still lands inside it")
    func largeOffsetsStayInBounds() {
        #expect(TabCycle.next(from: "chat", in: tabs, offset: 4) == "diff")
        #expect(TabCycle.next(from: "chat", in: tabs, offset: -4) == "terminal")
        #expect(TabCycle.next(from: "chat", in: tabs, offset: -100) != nil)
    }

    /// Nothing to move to is nil rather than the tab you are on, so the shortcut cannot make the
    /// centre column redraw for no change.
    @Test("a strip with nothing to move to answers nothing")
    func nothingToMoveTo() {
        #expect(TabCycle.next(from: "chat", in: ["chat"], offset: 1) == nil)
        #expect(TabCycle.next(from: nil, in: [String](), offset: 1) == nil)
        #expect(TabCycle.next(from: "chat", in: tabs, offset: 3) == nil)
    }

    /// A tab closed underneath the shortcut, which is the one case where the current tab is not
    /// in the strip at all.
    @Test("a tab that is gone lands on the first")
    func aClosedTabLandsSomewhere() {
        #expect(TabCycle.next(from: "gone", in: tabs, offset: 1) == "chat")
        #expect(TabCycle.next(from: nil, in: tabs, offset: -1) == "chat")
    }
}
