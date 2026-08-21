import AppKit

/// How a menu item carries a Swift value to the action that fires.
///
/// `NSMenuItem.representedObject` is `Any?`, so anything at all goes in and the compiler has
/// nothing to say about what comes out. A `WorkspaceID` went into the menu bar item and the dock
/// menu and was read back `as? String`, a cast that can never succeed: both menus raised the
/// window and then selected nothing, with no crash and no log line to say so.
///
/// A struct or an enum can only cross `Any?` intact inside an object, which `TerminalPaneMenu`
/// already knew and solved with a box of its own. This is that box, made generic and moved
/// somewhere the other two menus can reach it, so the tree has one of them rather than one per
/// menu. `represented(_:)` names the type it wants, which is the closest AppKit lets this get to
/// the compiler holding the line.
final class MenuItemPayload<Value>: NSObject {
    let value: Value

    init(_ value: Value) { self.value = value }
}

extension NSMenuItem {
    /// Boxes `value` into `representedObject`. Pair it with `represented(_:)`, never with a bare
    /// cast of `representedObject`, which is where this went wrong.
    func represent<Value>(_ value: Value) {
        representedObject = MenuItemPayload(value)
    }

    /// The value `represent(_:)` put here, or nil if the item is carrying something else.
    func represented<Value>(_ type: Value.Type) -> Value? {
        (representedObject as? MenuItemPayload<Value>)?.value
    }
}
