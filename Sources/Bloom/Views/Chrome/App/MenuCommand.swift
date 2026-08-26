import SwiftUI
import BloomCore

/// One row of the menu bar, drawn from `MenuBarCatalogue`.
///
/// **The title and the key come from the table, and this view supplies neither.** That is the
/// whole point of it: `BloomCommands` is a `Commands` body, which is a view, so a title written
/// there is a title nothing can check and a key written there is a key nothing can compare against
/// the rest of the bar. Two items on one keystroke is not a tie AppKit reports; it picks whichever
/// it finds first and the other never fires, which is how `Cmd+0` was lost once already.
///
/// What stays in the view is the closure, the greying and the separators, because all three depend
/// on state the core cannot hold.
struct MenuCommand: View {
    var action: MenuBarAction
    /// Which half of a two-state item to draw: already pinned, already unread. Ignored by every
    /// item that has one title.
    var alternate = false
    /// The glyph, for the handful of rows that wear one. It is not in the table because the
    /// symbols are `PaneSymbol`, which is the app target's and is shared with two AppKit menus.
    var symbol: String?
    var perform: @MainActor () -> Void

    /// Spelled out rather than left to the memberwise one, so a row reads as the action it is.
    init(
        _ action: MenuBarAction,
        alternate: Bool = false,
        symbol: String? = nil,
        perform: @escaping @MainActor () -> Void
    ) {
        self.action = action
        self.alternate = alternate
        self.symbol = symbol
        self.perform = perform
    }

    private var item: MenuBarItem { MenuBarCatalogue[action] }

    var body: some View {
        button
            // Nothing when the table says the key belongs to a row of this item's submenu, which
            // is what the two splits do: AppKit never fires an item that has a submenu, so a key
            // written here would be drawn beside a row that cannot answer it.
            .modifier(MenuKeyEquivalent(key: item.keyOnSameAgainRow ? nil : item.key))
    }

    @ViewBuilder
    private var button: some View {
        if let symbol {
            Button(item.title(alternate: alternate), systemImage: symbol, action: perform)
        } else {
            Button(item.title(alternate: alternate), action: perform)
        }
    }
}

/// A submenu whose title comes from the table, for the items that hang a list off themselves.
struct MenuCommandGroup<Content: View>: View {
    var action: MenuBarAction
    var symbol: String?
    @ViewBuilder var content: Content

    init(_ action: MenuBarAction, symbol: String? = nil, @ViewBuilder content: () -> Content) {
        self.action = action
        self.symbol = symbol
        self.content = content()
    }

    private var title: String { MenuBarCatalogue[action].title }

    var body: some View {
        if let symbol {
            Menu(title, systemImage: symbol) { content }
        } else {
            Menu(title) { content }
        }
    }
}

/// The key equivalent, or none, without the caller having to branch.
///
/// `keyboardShortcut` has no "no shortcut" argument, so an item with no key has to be a different
/// view. A modifier says that once rather than at every call site.
private struct MenuKeyEquivalent: ViewModifier {
    var key: MenuShortcut?

    func body(content: Content) -> some View {
        if let key {
            content.keyboardShortcut(key.equivalent, modifiers: key.eventModifiers)
        } else {
            content
        }
    }
}

extension MenuShortcut {
    /// The one place a key in the table becomes a key on the screen. Every spelling of every
    /// shortcut in this app passes through here, so there is exactly one of each.
    var equivalent: KeyEquivalent {
        switch trigger {
        case .character(let character): KeyEquivalent(character)
        case .upArrow: .upArrow
        case .downArrow: .downArrow
        case .leftArrow: .leftArrow
        case .rightArrow: .rightArrow
        // Backspace, which is what Archive Workspace takes and what `KeyEquivalent` spells
        // `.delete`. Forward delete is `.deleteForward` and is not used anywhere here.
        case .delete: .delete
        case .return: .return
        case .comma: KeyEquivalent(",")
        }
    }

    var eventModifiers: EventModifiers {
        var result: EventModifiers = []
        if modifiers.contains(.command) { result.insert(.command) }
        if modifiers.contains(.shift) { result.insert(.shift) }
        if modifiers.contains(.option) { result.insert(.option) }
        if modifiers.contains(.control) { result.insert(.control) }
        return result
    }
}
