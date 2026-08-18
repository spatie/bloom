import AppKit

/// The contextual menu a terminal pane offers on right click.
///
/// Built in AppKit rather than with SwiftUI's `.contextMenu`, because the pane is a SwiftTerm
/// `NSView` and it consumes the right mouse event before SwiftUI ever sees it. `NSView.menu(for:)`
/// is the hook AppKit itself asks, so this is the one place a menu can be returned from.
///
/// Every item routes through the same `TerminalPaneCommand` the keyboard uses, so the menu cannot
/// drift away from the shortcuts: there is one implementation of splitting and one of closing, and
/// the menu is a second way to reach them rather than a second copy of them.
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

        menu.addItem(item(
            "Split Right", symbol: PaneSymbol.splitRight, key: "d", modifiers: .command,
            command: .split(.horizontal), target: target
        ))
        menu.addItem(item(
            "Split Down", symbol: PaneSymbol.splitDown, key: "d", modifiers: [.command, .shift],
            command: .split(.vertical), target: target
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
        item.representedObject = Box(command)
        return item
    }

    /// `TerminalPaneCommand` is an enum, and `representedObject` is `Any?`, so it travels boxed.
    private final class Box: NSObject {
        let command: TerminalPaneCommand
        init(_ command: TerminalPaneCommand) { self.command = command }
    }

    @MainActor
    final class ActionTarget: NSObject {
        private let perform: @MainActor (TerminalPaneCommand) -> Void

        init(perform: @escaping @MainActor (TerminalPaneCommand) -> Void) {
            self.perform = perform
        }

        @objc func fire(_ sender: NSMenuItem) {
            guard let box = sender.representedObject as? Box else { return }
            perform(box.command)
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
