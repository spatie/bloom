import Foundation

/// What a key press asks a list to do, once the event has been read.
///
/// Reading an `NSEvent` is the only part of a list's keyboard that has to happen in the app
/// target: a key code is a key code and there is nothing to decide about it. Everything after
/// that, which row the arrow lands on and what a typed prefix jumps to, is a rule, and a rule
/// taken inside a view is a rule nothing can test. So the view maps the event to one of these and
/// asks below what it means.
///
/// `character` carries the key as typed rather than as a code, because type-select is about what
/// the reader thinks they typed. Everything with a modifier on it belongs to somebody else and
/// never becomes one of these: see `TypeSelect.isTypeSelect`.
public enum ListKey: Equatable, Sendable {
    case up
    case down
    case home
    case end
    /// Collapse, or step out to the parent. Only a tree answers these two: see `TreeNavigation`.
    case left
    case right
    /// Return. Opens the row rather than moving to it.
    case activate
    case character(Character)
}

/// Where an arrow key, Home or End puts a flat list's selection.
///
/// **The arrows do not wrap, and that is the platform rather than an oversight.** Down on the last
/// row of an `NSTableView` stays on the last row; a list that jumped back to the top would move
/// the reader's eye the full height of the pane on a keystroke that means "one more". Bloom does
/// wrap in one place, `FileReview.step` behind Command+Option+J and K, and the reason is written
/// there: that one is a shortcut somebody holds down to walk a change repeatedly, not a caret.
///
/// With nothing selected, Down takes the first row and Up takes the last, which is what an empty
/// selection means in every Mac list: the arrow enters the list from the edge it came from.
public enum ListNavigation {
    /// The row the key moves to, or nil if the key moves nothing.
    ///
    /// Returning the row it is already on rather than nil at the ends is deliberate. The caller
    /// compares, and a caller that got nil at the last row could not tell "there is nowhere to go"
    /// from "this key is not mine" and would hand the key back to the responder chain, where the
    /// window scrolls something else instead.
    public static func destination(for key: ListKey, from current: Int?, count: Int) -> Int? {
        guard count > 0 else { return nil }

        switch key {
        case .down:
            return current.map { min($0 + 1, count - 1) } ?? 0
        case .up:
            return current.map { max($0 - 1, 0) } ?? count - 1
        case .home:
            return 0
        case .end:
            return count - 1
        case .left, .right, .activate, .character:
            return nil
        }
    }
}

/// What a key press turns out to mean for the list it was aimed at.
///
/// `handled` and `ignored` are not the same answer and the difference is load bearing. A key the
/// list ignored goes back up the responder chain, where the window may do something else with it;
/// a key the list handled and had nothing to do with is finished. Typing `zz` at a list with no
/// row starting with zz is the second: nothing moves, and the z must not also scroll the pane
/// behind it.
public enum ListKeyOutcome: Equatable, Sendable {
    case move(Int)
    case activate
    case handled
    case ignored
}

/// One list's whole keyboard: the arrows, Home and End, Return, and the prefix somebody is
/// typing.
///
/// Held as state by the list, because type-select has state and nothing else here does. Everything
/// it decides is above, and this is the small amount of glue that would otherwise be written three
/// times in three views, differently.
public struct ListKeyboard: Sendable, Equatable {
    private var typeSelect = TypeSelect()

    public init() {}

    /// `titles` is what type-select matches against, in the order the rows are drawn, so `current`
    /// indexes both it and the rows.
    public mutating func outcome(
        for key: ListKey,
        titles: [String],
        current: Int?,
        at now: Date = Date()
    ) -> ListKeyOutcome {
        switch key {
        case .character(let character):
            guard TypeSelect.isTypeSelect(character) else { return .ignored }
            let prefix = typeSelect.accept(character, at: now)
            guard let index = TypeSelect.match(prefix, in: titles, from: current) else {
                return .handled
            }
            return .move(index)

        case .activate:
            return current == nil ? .ignored : .activate

        // A flat list has no answer for these. A tree does, and asks `TreeNavigation` before it
        // gets here.
        case .left, .right:
            return .ignored

        case .up, .down, .home, .end:
            // A key that moves the selection is also the end of a word: somebody who arrowed away
            // from the row they typed their way to is not still spelling it.
            typeSelect.clear()
            guard let index = ListNavigation.destination(
                for: key, from: current, count: titles.count
            ) else {
                return .ignored
            }
            return index == current ? .handled : .move(index)
        }
    }

    /// For a list that has lost the keyboard. See `TypeSelect.clear`.
    public mutating func forgetTyping() {
        typeSelect.clear()
    }
}
