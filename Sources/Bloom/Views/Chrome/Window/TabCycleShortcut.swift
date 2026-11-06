import AppKit
import BloomCore

/// Option+Tab and Command+Option+Left or Right step through the strip in front, and Control+Tab
/// and Shift+Control+Tab walk Forward and Back through the navigation history.
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
    private static let leftArrowKeyCode: UInt16 = 123
    private static let rightArrowKeyCode: UInt16 = 124

    static func attach(_ model: AppModel) {
        self.model = model
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == tabKeyCode {
                let pressed = modifiers(of: event)
                if let offset = TabCycle.offset(forTabWith: pressed) {
                    return MainActor.assumeIsolated { cycle(by: offset) } ? nil : event
                }
                if let step = NavigationHistory.step(forTabWith: pressed) {
                    return MainActor.assumeIsolated { navigate(by: step) } ? nil : event
                }
            }

            guard let arrow = arrow(for: event.keyCode) else { return event }
            let handled = MainActor.assumeIsolated {
                guard let model = Self.model,
                      let window = eligibleWindow,
                      let workspace = model.selectedModel,
                      let offset = TabCycle.offset(
                          for: arrow,
                          modifiers: modifiers(of: event),
                          tabCount: WorkspaceTabsStore.shared.entries(in: workspace).count,
                          responderOwnsShortcut: responderOwnsArrow(window.firstResponder),
                          isComposing: isComposing(window.firstResponder)
                      ) else { return false }
                WorkspaceTabsStore.shared.selectNextTab(offset: offset, in: workspace)
                return true
            }
            return handled ? nil : event
        }
    }

    /// True when the press was spent on the strip, so the monitor swallows it. It is spent even
    /// when there is only one tab, so Option+Tab does not fall through and type a tab into the
    /// composer on a strip that happens to have nowhere to go.
    private static func cycle(by offset: Int) -> Bool {
        guard let model, eligibleWindow != nil else { return false }
        model.cycleCentreTab(by: offset)
        return true
    }

    /// Spent like `cycle`, even with nowhere to go, so Control+Tab never types into the composer or
    /// reaches a shell.
    private static func navigate(by step: Int) -> Bool {
        guard let model, eligibleWindow != nil else { return false }
        model.stepNavigation(by: step)
        return true
    }

    private static var eligibleWindow: NSWindow? {
        guard let window = NSApp.keyWindow,
              window.canBecomeMain, !window.isSheet, window.attachedSheet == nil else { return nil }
        return window
    }

    private static func arrow(for keyCode: UInt16) -> TabCycle.Arrow? {
        switch keyCode {
        case leftArrowKeyCode: .left
        case rightArrowKeyCode: .right
        default: nil
        }
    }

    /// A shell uses the same arrows to move among its own panes. An editable text view gets the
    /// event too, so AppKit can apply the current key-binding dictionary rather than Bloom
    /// guessing what that field's Command+Option arrow means.
    private static func responderOwnsArrow(_ responder: NSResponder?) -> Bool {
        var current = responder
        while let each = current {
            if each is BloomTerminalView { return true }
            if let text = each as? NSTextView, text.isEditable { return true }
            // WebKit keeps one private content view as first responder for both prose and form
            // fields. A real selection range is the public NSTextInputClient signal that an
            // editable element has the caret; NSNotFound is an ordinary page.
            if let input = each as? NSTextInputClient,
               input.selectedRange().location != NSNotFound { return true }
            current = each.nextResponder
        }
        return false
    }

    private static func isComposing(_ responder: NSResponder?) -> Bool {
        (responder as? NSTextInputClient)?.hasMarkedText() == true
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
