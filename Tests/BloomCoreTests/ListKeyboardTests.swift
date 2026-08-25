import Foundation
import Testing
@testable import BloomCore

/// Where the arrow keys, Home and End put a list's selection, and what a typed prefix jumps to.
///
/// Three of Bloom's lists had no keyboard at all and were a stack of buttons. What they grew is
/// all here rather than in the three views, which is the whole reason these rules are answerable
/// without a window.
@Suite("A list's keyboard")
struct ListKeyboardTests {

    // MARK: - Arrows

    @Test("down from nothing enters at the top, up from nothing enters at the bottom")
    func entersFromTheEdge() {
        #expect(ListNavigation.destination(for: .down, from: nil, count: 5) == 0)
        #expect(ListNavigation.destination(for: .up, from: nil, count: 5) == 4)
    }

    @Test("the arrows step one row")
    func stepsOne() {
        #expect(ListNavigation.destination(for: .down, from: 2, count: 5) == 3)
        #expect(ListNavigation.destination(for: .up, from: 2, count: 5) == 1)
    }

    /// The bug this is here to stop is the tidier looking one: a list that wraps moves the eye the
    /// full height of the pane on a key that means "one more".
    @Test("the arrows stop at the ends rather than wrapping")
    func doesNotWrap() {
        #expect(ListNavigation.destination(for: .down, from: 4, count: 5) == 4)
        #expect(ListNavigation.destination(for: .up, from: 0, count: 5) == 0)
    }

    @Test("Home and End reach the ends from anywhere")
    func homeAndEnd() {
        #expect(ListNavigation.destination(for: .home, from: 3, count: 5) == 0)
        #expect(ListNavigation.destination(for: .end, from: 3, count: 5) == 4)
        #expect(ListNavigation.destination(for: .home, from: nil, count: 5) == 0)
        #expect(ListNavigation.destination(for: .end, from: nil, count: 5) == 4)
    }

    @Test("an empty list moves nowhere", arguments: [ListKey.up, .down, .home, .end])
    func emptyList(key: ListKey) {
        #expect(ListNavigation.destination(for: key, from: nil, count: 0) == nil)
    }

    /// A tree answers these two and a flat list does not, so the flat rule says nothing about them
    /// rather than guessing. See `TreeNavigation`.
    @Test("the keys a flat list has no answer for", arguments: [
        ListKey.left, .right, .activate, .character("a"),
    ])
    func notAMove(key: ListKey) {
        #expect(ListNavigation.destination(for: key, from: 1, count: 5) == nil)
    }
}

/// The driver the three lists actually hold, which is the two rules above plus the small amount
/// of glue that would otherwise have been written three times.
@Suite("A list's keyboard, driven")
struct ListKeyboardDriverTests {

    private let titles = ["Package.swift", "README.md", "Store.swift", "Settings.swift"]

    @Test("an arrow moves")
    func arrowMoves() {
        var keyboard = ListKeyboard()
        #expect(keyboard.outcome(for: .down, titles: titles, current: 0) == .move(1))
    }

    /// The distinction the outcome exists for: nothing moved, and the key is still finished. A
    /// Down at the last row that went back up the responder chain would scroll the pane behind it.
    @Test("an arrow at the end of the list is handled rather than passed on")
    func arrowAtTheEnd() {
        var keyboard = ListKeyboard()
        #expect(keyboard.outcome(for: .down, titles: titles, current: 3) == .handled)
        #expect(keyboard.outcome(for: .up, titles: titles, current: 0) == .handled)
    }

    @Test("an arrow at an empty list is not this list's key")
    func arrowAtNothing() {
        var keyboard = ListKeyboard()
        #expect(keyboard.outcome(for: .down, titles: [], current: nil) == .ignored)
    }

    @Test("Return on a row opens it, and Return on nothing is nobody's key")
    func returnKey() {
        var keyboard = ListKeyboard()
        #expect(keyboard.outcome(for: .activate, titles: titles, current: 2) == .activate)
        #expect(keyboard.outcome(for: .activate, titles: titles, current: nil) == .ignored)
    }

    @Test("left and right belong to a tree, not to a flat list")
    func treeKeys() {
        var keyboard = ListKeyboard()
        #expect(keyboard.outcome(for: .left, titles: titles, current: 1) == .ignored)
        #expect(keyboard.outcome(for: .right, titles: titles, current: 1) == .ignored)
    }

    @Test("typing jumps to the row, one character at a time")
    func typing() {
        var keyboard = ListKeyboard()
        let now = Date()
        #expect(keyboard.outcome(for: .character("s"), titles: titles, current: nil, at: now)
            == .move(2))
        #expect(keyboard.outcome(
            for: .character("e"), titles: titles, current: 2, at: now.addingTimeInterval(0.1)
        ) == .move(3))
    }

    @Test("a prefix nothing starts with is swallowed rather than passed on")
    func typingNoMatch() {
        var keyboard = ListKeyboard()
        #expect(keyboard.outcome(for: .character("z"), titles: titles, current: 0) == .handled)
    }

    @Test("the space bar is not this list's key, because it is Quick Look's")
    func space() {
        var keyboard = ListKeyboard()
        #expect(keyboard.outcome(for: .character(" "), titles: titles, current: 0) == .ignored)
    }

    /// Arrowing away ends the word. Without this, `s` then Down then `e` would search for `se`
    /// from wherever the arrow left the selection, which is not what either keystroke meant.
    @Test("an arrow ends the word being typed")
    func arrowEndsTheWord() {
        var keyboard = ListKeyboard()
        let now = Date()
        #expect(keyboard.outcome(for: .character("s"), titles: titles, current: nil, at: now)
            == .move(2))
        #expect(keyboard.outcome(for: .down, titles: titles, current: 2, at: now) == .move(3))
        // `e` alone, so it searches from after the current row rather than for `se`.
        #expect(keyboard.outcome(
            for: .character("e"), titles: titles, current: 3, at: now.addingTimeInterval(0.1)
        ) == .handled)
    }

    @Test("losing the keyboard ends the word too")
    func forgetsTyping() {
        var keyboard = ListKeyboard()
        let now = Date()
        _ = keyboard.outcome(for: .character("s"), titles: titles, current: nil, at: now)
        keyboard.forgetTyping()
        // `e` as a fresh word finds nothing after Settings, rather than continuing `se`.
        #expect(keyboard.outcome(
            for: .character("e"), titles: titles, current: 2, at: now.addingTimeInterval(0.1)
        ) == .handled)
    }
}

@Suite("Type-select")
struct TypeSelectTests {

    private let titles = ["Package.swift", "README.md", "Store.swift", "Settings.swift"]

    // MARK: - The buffer

    @Test("characters typed in quick succession make one prefix")
    func accumulates() {
        var select = TypeSelect()
        let now = Date()
        #expect(select.accept("s", at: now) == "s")
        #expect(select.accept("t", at: now.addingTimeInterval(0.2)) == "st")
        #expect(select.accept("o", at: now.addingTimeInterval(0.4)) == "sto")
    }

    @Test("a pause starts a new prefix")
    func expires() {
        var select = TypeSelect()
        let now = Date()
        _ = select.accept("s", at: now)
        let later = now.addingTimeInterval(TypeSelect.window + 0.1)
        #expect(select.accept("t", at: later) == "t")
    }

    @Test("a keystroke inside the window keeps the prefix alive")
    func staysAlive() {
        var select = TypeSelect()
        let now = Date()
        _ = select.accept("s", at: now)
        #expect(select.accept("t", at: now.addingTimeInterval(TypeSelect.window - 0.01)) == "st")
    }

    /// A system clock that moves backwards would otherwise leave a buffer that can never expire.
    @Test("a clock that goes backwards is a pause, not an extension")
    func clockGoesBackwards() {
        var select = TypeSelect()
        let now = Date()
        _ = select.accept("s", at: now)
        #expect(select.accept("t", at: now.addingTimeInterval(-5)) == "t")
    }

    @Test("losing the keyboard throws the prefix away")
    func cleared() {
        var select = TypeSelect()
        _ = select.accept("s", at: Date())
        select.clear()
        #expect(select.buffer.isEmpty)
        #expect(select.accept("t", at: Date()) == "t")
    }

    // MARK: - What counts as typing

    @Test("letters, digits and punctuation are type-select", arguments: [
        Character("a"), "Z", "7", ".", "-", "_", "+",
    ])
    func typeSelectCharacters(character: Character) {
        #expect(TypeSelect.isTypeSelect(character))
    }

    /// The space bar is Quick Look in these lists, the way Finder has it, so it never reaches the
    /// buffer. Return is `ListKey.activate`.
    @Test("space, tab and return are not", arguments: [Character(" "), "\t", "\n"])
    func notTypeSelectCharacters(character: Character) {
        #expect(TypeSelect.isTypeSelect(character) == false)
    }

    // MARK: - Matching

    @Test("a prefix finds the first row that starts with it")
    func matchesPrefix() {
        #expect(TypeSelect.match("re", in: titles, from: nil) == 1)
        #expect(TypeSelect.match("se", in: titles, from: nil) == 3)
    }

    @Test("case and accents are ignored")
    func caseInsensitive() {
        #expect(TypeSelect.match("ST", in: titles, from: nil) == 2)
        #expect(TypeSelect.match("re", in: ["Résumé.pdf"], from: nil) == 0)
    }

    @Test("a prefix that matches nothing moves nothing")
    func noMatch() {
        #expect(TypeSelect.match("zz", in: titles, from: 0) == nil)
        #expect(TypeSelect.match("a", in: [], from: nil) == nil)
        #expect(TypeSelect.match("", in: titles, from: nil) == nil)
    }

    /// The two gestures one letter and several letters mean, which is the whole of why the two
    /// searches start in different places.
    @Test("one letter pressed again walks to the next row that starts with it")
    func singleCharacterCycles() {
        let names = ["Store.swift", "Settings.swift", "Shell.swift"]
        #expect(TypeSelect.match("s", in: names, from: nil) == 0)
        #expect(TypeSelect.match("s", in: names, from: 0) == 1)
        #expect(TypeSelect.match("s", in: names, from: 1) == 2)
        #expect(TypeSelect.match("s", in: names, from: 2) == 0)
    }

    @Test("a longer prefix refines the row the first letter found")
    func longerPrefixStays() {
        let names = ["Store.swift", "Settings.swift", "Shell.swift"]
        // `s` landed on Store; `st` is still Store rather than the next thing beginning with st.
        #expect(TypeSelect.match("st", in: names, from: 0) == 0)
        // And it does move on when the row it is on stops matching.
        #expect(TypeSelect.match("sh", in: names, from: 0) == 2)
    }

    @Test("the search wraps to reach a row above the one it started at")
    func wraps() {
        let names = ["Store.swift", "Settings.swift", "Shell.swift"]
        #expect(TypeSelect.match("sto", in: names, from: 2) == 0)
    }
}
