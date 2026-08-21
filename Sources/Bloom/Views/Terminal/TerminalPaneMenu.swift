import AppKit
import BloomCore

/// The contextual menu a terminal pane offers on right click.
///
/// Built in AppKit rather than with SwiftUI's `.contextMenu`, because the pane is a SwiftTerm
/// `NSView` and it consumes the right mouse event before SwiftUI ever sees it. `NSView.menu(for:)`
/// is the hook AppKit itself asks, so this is the one place a menu can be returned from.
///
/// Every item routes through the same `TerminalPaneCommand` the keyboard uses, so the menu cannot
/// drift away from the shortcuts: there is one implementation of splitting and one of closing, and
/// the menu is a second way to reach them rather than a second copy of them.
///
/// The two directions are submenus, the same three kinds the centre pane's own menu offers and
/// from the same `PaneKind`, so the direction and what goes in the half are one gesture. See
/// `CenterPaneMenu`.
@MainActor
enum TerminalPaneMenu {
    static func make(
        canClose: Bool,
        isZoomed: Bool,
        perform: @escaping @MainActor (TerminalPaneCommand) -> Void
    ) -> NSMenu {
        let target = ActionTarget(perform: perform)
        // A menu that owns its target, because `NSMenuItem.target` is weak and nothing else here
        // would hold it: without this the closures are gone before the user picks anything.
        let menu = OwningMenu(target: target)

        menu.addItem(splitItem(
            "Split Right", symbol: PaneSymbol.splitRight, axis: .horizontal,
            key: "d", modifiers: .command, target: target
        ))
        menu.addItem(splitItem(
            "Split Down", symbol: PaneSymbol.splitDown, axis: .vertical,
            key: "d", modifiers: [.command, .shift], target: target
        ))

        menu.addItem(.separator())

        menu.addItem(item(
            isZoomed ? "Zoom Out" : "Zoom Pane",
            symbol: isZoomed ? PaneSymbol.zoomOut : PaneSymbol.zoomIn,
            key: "\r", modifiers: [.command, .shift],
            command: .toggleZoom, target: target
        ))

        menu.addItem(.separator())

        // Closing the only pane closes the tab, which is a different and larger action than the
        // one this item names, so it is offered only when it really does close a pane.
        let close = item(
            "Close Pane", symbol: PaneSymbol.closePane, key: "w", modifiers: .command,
            command: .close, target: target
        )
        close.isEnabled = canClose
        menu.addItem(close)

        return menu
    }

    /// One direction, and the three things that can be put in the half that opens.
    ///
    /// The shortcut is drawn on Terminal rather than on the item this hangs off. AppKit never
    /// sends the action of an item that has a submenu, so a key equivalent written on the parent
    /// would be drawn beside a row that cannot fire, and Cmd+D would look like it belonged to a
    /// list rather than to one entry in it. Terminal is the entry it belongs to: `.split(axis,
    /// .terminal)` is the exact value `TerminalPaneCommand(key:modifiers:)` builds for Cmd+D, so
    /// the row and the keystroke are the same command and cannot come apart.
    ///
    /// The keystroke itself is unaffected either way. It is read in `BloomTerminalView.keyDown`,
    /// because that is the only place that knows a shell has the keyboard, and a contextual menu
    /// is neither the menu bar nor the view hierarchy: what is written here is a label.
    private static func splitItem(
        _ title: String,
        symbol: String,
        axis: SplitAxis,
        key: String,
        modifiers: NSEvent.ModifierFlags,
        target: ActionTarget
    ) -> NSMenuItem {
        let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        parent.image = PaneSymbol.image(symbol, label: title)

        let kinds = NSMenu(title: title)
        for kind in PaneKind.allCases {
            let carriesShortcut = kind == .terminal
            kinds.addItem(item(
                kind.title,
                symbol: kind.symbol,
                key: carriesShortcut ? key : "",
                modifiers: carriesShortcut ? modifiers : [],
                command: .split(axis, kind),
                target: target
            ))
        }
        parent.submenu = kinds
        return parent
    }

    private static func item(
        _ title: String,
        symbol: String,
        key: String,
        modifiers: NSEvent.ModifierFlags,
        command: TerminalPaneCommand,
        target: ActionTarget
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(ActionTarget.fire(_:)), keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        // `NSMenuItem` has no `Label`, so the glyph is set as the item's own image. It carries the
        // title as its accessibility description because VoiceOver reads the image before the
        // title, and an unnamed one is announced as "image".
        item.image = PaneSymbol.image(symbol, label: title)
        item.target = target
        // `TerminalPaneCommand` is an enum and `representedObject` is `Any?`, so it travels boxed.
        // See `MenuItemPayload`, which is this box after the same `Any?` swallowed a `WorkspaceID`
        // in two other menus.
        item.represent(command)
        return item
    }

    @MainActor
    final class ActionTarget: NSObject {
        private let perform: @MainActor (TerminalPaneCommand) -> Void

        init(perform: @escaping @MainActor (TerminalPaneCommand) -> Void) {
            self.perform = perform
        }

        @objc func fire(_ sender: NSMenuItem) {
            guard let command = sender.represented(TerminalPaneCommand.self) else { return }
            perform(command)
        }
    }
}

/// An `NSMenu` that keeps its items' action target alive.
///
/// A subclass rather than an associated object: the association would need a global key, which is
/// mutable global state and so not concurrency safe, and this says the same thing in the type.
private final class OwningMenu: NSMenu {
    private let target: TerminalPaneMenu.ActionTarget

    init(target: TerminalPaneMenu.ActionTarget) {
        self.target = target
        super.init(title: "")
    }

    required init(coder: NSCoder) {
        fatalError("OwningMenu is only ever built in code")
    }
}
