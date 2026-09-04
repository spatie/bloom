import Foundation

/// A key press the panel has to answer, once the event has been read.
///
/// Reading an `NSEvent` is the only part that has to happen in the app target. What each key means
/// is a rule, and a rule taken inside a view is a rule nothing can test.
public enum SearchPanelKey: Equatable, Sendable {
    case up
    case down
    /// Next scope chip.
    case tab
    /// Previous scope chip.
    case backTab
    case returnKey
    /// Cmd+Return, which pushes into the highlighted row's own menu.
    case commandReturn
    /// The right arrow, which means the same as Cmd+Return but only from the end of the field.
    case right
    case escape
    /// Backspace with nothing in the field.
    case backspaceOnEmpty
}

/// What a key press turns out to mean.
///
/// `handled` and `ignored` are not the same answer, for the reason `ListKeyOutcome` gives: a key
/// the panel ignored goes back to the field editor, where it still moves the caret or types a
/// character, and a key the panel handled and had nothing to do with is finished.
public enum SearchPanelOutcome: Equatable, Sendable {
    case move(Int)
    /// Open the highlighted row: a workspace, a transcript hit at its own line, or a fallback.
    case open
    /// Push into the highlighted row's own menu.
    case drill
    case scope(HomeScope)
    /// Backspace out of commands, or out of an action list, back to searching things.
    case leaveMode
    /// Escape's first press with something in the field.
    case clearQuery
    case close
    case handled
    case ignored
}

/// Everything a key handler needs to know about the panel, as a value, so the whole keyboard can
/// be asserted without a window.
public struct SearchPanelKeyContext: Equatable, Sendable {
    public var mode: SearchPanelMode
    public var rowCount: Int
    public var highlighted: Int?
    public var isQueryEmpty: Bool
    public var scope: HomeScope
    /// The chips on offer, which is `HomeScope.offered(searching:)`. Handed in rather than derived
    /// so the panel and the strip cannot be offered two different sets.
    public var scopes: [HomeScope]
    /// Whether the highlighted row has a menu of its own. See `SearchPanelRow.drillable`.
    public var canDrill: Bool
    /// Whether the caret is at the end of the field, which is what makes the right arrow mean
    /// "push in" rather than "move the caret one character".
    public var caretAtEnd: Bool

    public init(
        mode: SearchPanelMode = .things,
        rowCount: Int = 0,
        highlighted: Int? = nil,
        isQueryEmpty: Bool = true,
        scope: HomeScope = .all,
        scopes: [HomeScope] = HomeScope.offered(searching: true),
        canDrill: Bool = false,
        caretAtEnd: Bool = true
    ) {
        self.mode = mode
        self.rowCount = rowCount
        self.highlighted = highlighted
        self.isQueryEmpty = isQueryEmpty
        self.scope = scope
        self.scopes = scopes
        self.canDrill = canDrill
        self.caretAtEnd = caretAtEnd
    }
}

/// The panel's whole keyboard.
///
/// **The arrows stop at both ends rather than wrapping**, which is `ListNavigation`'s rule and the
/// platform's: Down on the last row of a table stays on the last row. `MenuRows` wraps and is not
/// what this is, because this list is three sections of results a person is reading down rather
/// than a menu of six items they are cycling.
///
/// **Escape clears before it closes.** Somebody who typed a query and wants a different one should
/// not have to reopen the panel to get an empty field, and somebody who wants out presses it
/// twice. Every editor on the platform does the first half of this.
public enum SearchPanelKeys {
    public static func outcome(
        for key: SearchPanelKey, in context: SearchPanelKeyContext
    ) -> SearchPanelOutcome {
        switch key {
        case .up, .down:
            guard let index = ListNavigation.destination(
                for: key == .down ? .down : .up,
                from: context.highlighted,
                count: context.rowCount
            ) else {
                // Nothing to move to, and the key is still the panel's: an arrow handed back would
                // scroll whatever is behind the card.
                return .handled
            }
            return index == context.highlighted ? .handled : .move(index)

        case .tab, .backTab:
            // The chips split an answer about workspaces and transcripts. Commands and an action
            // list have no such answer, so Tab goes back to the field editor and moves the focus
            // the way it does everywhere else.
            guard context.mode.showsScopes, !context.scopes.isEmpty else { return .ignored }
            let step = key == .tab ? 1 : -1
            let current = context.scopes.firstIndex(of: context.scope) ?? 0
            // Wrapped, unlike the arrows, because a row of four chips is a cycle rather than a
            // list being read: Tab off the end of it has nowhere else to go.
            let next = (current + step + context.scopes.count) % context.scopes.count
            return .scope(context.scopes[next])

        case .returnKey:
            return context.highlighted == nil ? .handled : .open

        case .commandReturn:
            return context.canDrill ? .drill : .handled

        case .right:
            // Only from the end of the field. Mid word the right arrow is the caret's, and a
            // panel that took it would make the field unusable for correcting a typo.
            guard context.caretAtEnd else { return .ignored }
            return context.canDrill ? .drill : .ignored

        case .escape:
            return context.isQueryEmpty ? .close : .clearQuery

        case .backspaceOnEmpty:
            return context.mode == .things ? .ignored : .leaveMode
        }
    }

    /// The keys printed in the footer, which change with the mode because the two that matter
    /// most do.
    public static func footer(
        for mode: SearchPanelMode, isSearching: Bool
    ) -> [SearchPanelFooterKey] {
        switch mode {
        case .things:
            var keys = [
                SearchPanelFooterKey(key: "\u{21A9}", label: "Open"),
                SearchPanelFooterKey(key: "\u{2318}\u{21A9}", label: "Actions"),
            ]
            // The prefix is advertised at rest and the chips are advertised in a search, because
            // at rest there are no chips and in a search the reader has already found the field.
            keys.append(
                isSearching
                    ? SearchPanelFooterKey(key: "\u{21E5}", label: "Scope")
                    : SearchPanelFooterKey(key: ">", label: "Commands")
            )
            keys.append(SearchPanelFooterKey(key: "esc", label: "Close"))
            return keys
        case .commands:
            return [
                SearchPanelFooterKey(key: "\u{21A9}", label: "Run"),
                SearchPanelFooterKey(key: "\u{232B}", label: "Leave commands"),
                SearchPanelFooterKey(key: "esc", label: "Close"),
            ]
        case .actions:
            return [
                SearchPanelFooterKey(key: "\u{21A9}", label: "Run"),
                SearchPanelFooterKey(key: "\u{232B}", label: "Back"),
                SearchPanelFooterKey(key: "esc", label: "Close"),
            ]
        }
    }
}

/// One pair in the footer: the glyph, and what pressing it does.
public struct SearchPanelFooterKey: Equatable, Sendable, Identifiable {
    public var key: String
    public var label: String

    public var id: String { label }

    public init(key: String, label: String) {
        self.key = key
        self.label = label
    }
}
