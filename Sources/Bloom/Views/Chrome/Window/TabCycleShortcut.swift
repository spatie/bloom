import AppKit
import BloomCore

/// Option+Tab steps to the next tab of the strip in front, Shift+Option+Tab to the previous one.
///
/// A local monitor rather than a key on Next Tab, for two reasons. A menu item carries one key, and
/// Next Tab already carries Shift+Cmd+], which stays. And a menu key equivalent is offered to the
/// key window's view tree first, where an `NSTextView` spends Option+Tab on inserting a literal tab
/// and a terminal sends it on to the shell, so the composer and every terminal pane would have
/// kept it. A local monitor runs ahead of both.
///
/// Only in the main window, found by `canBecomeMain` as `MainWindow` does, and never while a sheet
/// is up: Settings, About and the panels have no strip, and Option+Tab in a field there is theirs.
///
/// **One monitor, for the life of the process**, holding the model weakly, the same shape as
/// `WindowCloseShortcut`.
@MainActor
enum TabCycleShortcut {
    private static var monitor: Any?
    private static weak var model: AppModel?

    private static let tabKeyCode: UInt16 = 48

    static func attach(_ model: AppModel) {
        self.model = model
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Off the key code, because Shift+Tab arrives as a back tab character rather than a tab.
            guard event.keyCode == tabKeyCode, let offset = TabCycle.offset(forTabWith: modifiers(of: event)) else {
                return event
            }
            return MainActor.assumeIsolated { cycle(by: offset) } ? nil : event
        }
    }

    /// True when the press was spent on the strip, so the monitor swallows it. It is spent even
    /// when there is only one tab, so Option+Tab does not fall through and type a tab into the
    /// composer on a strip that happens to have nowhere to go.
    private static func cycle(by offset: Int) -> Bool {
        guard let model,
              let window = NSApp.keyWindow,
              window.canBecomeMain, !window.isSheet, window.attachedSheet == nil
        else { return false }
        model.cycleCentreTab(by: offset)
        return true
    }

    private static func modifiers(of event: NSEvent) -> MenuShortcut.Modifiers {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var modifiers: MenuShortcut.Modifiers = []
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.control) { modifiers.insert(.control) }
        return modifiers
    }
}
