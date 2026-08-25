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

    // MARK: - Cmd+1 to Cmd+9

    /// Safari, Terminal and Xcode all give 9 to the LAST tab rather than to the ninth, which is
    /// the half of the convention that makes the two ends of a long strip one keystroke apart.
    @Test("a number reaches its tab, and nine reaches the last one")
    func numbersReachTabs() {
        let strip = (1...12).map { "tab\($0)" }
        #expect(TabCycle.tab(at: 1, in: strip) == "tab1")
        #expect(TabCycle.tab(at: 8, in: strip) == "tab8")
        #expect(TabCycle.tab(at: 9, in: strip) == "tab12")
        #expect(TabCycle.tab(at: 3, in: tabs) == "terminal")
        #expect(TabCycle.tab(at: 9, in: tabs) == "terminal")
    }

    @Test("a number past the end of a short strip reaches nothing")
    func numbersPastTheEnd() {
        #expect(TabCycle.tab(at: 4, in: tabs) == nil)
        #expect(TabCycle.tab(at: 1, in: [String]()) == nil)
        #expect(TabCycle.tab(at: 0, in: tabs) == nil)
        #expect(TabCycle.tab(at: 10, in: tabs) == nil)
    }

    /// The menu lists every tab, because one that hid the tenth would be lying about what is open.
    /// Only the ones a key can reach carry a number.
    @Test("the menu numbers the first eight and the last")
    func numberingForTheMenu() {
        let numbered = TabCycle.numbered((1...12).map { "tab\($0)" })
        #expect(numbered.count == 12)
        #expect(numbered.map(\.ordinal) == [1, 2, 3, 4, 5, 6, 7, 8, nil, nil, nil, 9])

        #expect(TabCycle.numbered(tabs).map(\.ordinal) == [1, 2, 3])
        #expect(TabCycle.numbered([String]()).isEmpty)
    }

    /// Nine tabs exactly: the ninth is the last, so it takes nine and nothing is unreachable.
    @Test("a strip of nine has no unreachable tab")
    func nineExactly() {
        #expect(TabCycle.numbered((1...9).map { "tab\($0)" }).map(\.ordinal)
            == [1, 2, 3, 4, 5, 6, 7, 8, 9])
    }
}
