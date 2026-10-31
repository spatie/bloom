import AppKit
import WebKit
import BloomCore

/// Typing or pasting with nothing taking it goes to the focused chat's composer. The event is
/// handed back rather than replayed, so dead keys and input methods still work. A file dropped on
/// a part of the window with nothing to take it goes there too: see `dropTarget(in:)`.
@MainActor
enum TypeToComposer {
    private static var monitor: Any?
    private static weak var model: AppModel?
    private static let editors = NSMapTable<ComposerEditorHandle, NSString>(
        keyOptions: .weakMemory, valueOptions: .strongMemory
    )

    static func attach(_ model: AppModel) {
        self.model = model
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // File review handles Option+V after local monitors run. Moving focus first would
            // make its shortcut think somebody is typing and leave the file unmarked.
            if ViewedShortcutHostView.isViewedShortcut(event) { return event }
            let characters = event.characters?.isEmpty == false
                ? event.characters : event.charactersIgnoringModifiers
            let modifiers = modifiers(of: event)
            MainActor.assumeIsolated {
                guard ComposerTypeAhead.belongsToComposer(characters: characters, modifiers: modifiers) else { return }
                redirect()
            }
            return event
        }
    }

    /// Keyed by session: one composer is reused across workspaces, and the previous column stays
    /// laid out out of sight.
    static func register(_ editor: ComposerEditorHandle, showing sessionKey: String) {
        editors.setObject(sessionKey as NSString, forKey: editor)
    }

    private static func redirect() {
        guard let window = NSApp.keyWindow,
              window.canBecomeMain, !window.isSheet, window.attachedSheet == nil,
              !takesKeys(window.firstResponder),
              let sessionKey = focusedChat() else { return }
        for case let editor as ComposerEditorHandle in editors.keyEnumerator()
        where editors.object(forKey: editor) as String? == sessionKey {
            if editor.takeKeyboard(in: window) { return }
        }
    }

    private static func focusedChat() -> String? { focusedChatID()?.rawValue }

    private static func focusedChatID() -> SessionID? {
        guard let workspace = model?.selectedModel else { return nil }
        let tabs = WorkspaceTabsStore.shared
        guard let tab = tabs.selectedTab(in: workspace),
              case .chat(let sessionID) = tabs.content(of: tabs.focusedPane(of: tab), in: tab)
        else { return nil }
        return sessionID
    }

    /// The composer a file dropped on a part of the window with no drop target of its own goes to:
    /// the focused chat's, or the side conversation's when the drag is over its card. `point` is in
    /// window coordinates, like the card's frame.
    ///
    /// A sheet has one composer and takes the file whatever part of the window it is let go over,
    /// the sheet's own area and the window around it alike.
    static func dropTarget(in window: NSWindow, at point: CGPoint?) -> ComposerEditorHandle? {
        if let sheet = window.attachedSheet { return composer(in: sheet, keyed: nil) }
        if window.isSheet { return composer(in: window, keyed: nil) }
        guard let sessionKey = dropSessionKey(at: point) else { return nil }
        return composer(in: window, keyed: sessionKey)
    }

    /// The composer on screen in `window` for `sessionKey`, or the only one there when it is nil.
    private static func composer(in window: NSWindow, keyed sessionKey: String?) -> ComposerEditorHandle? {
        for case let editor as ComposerEditorHandle in editors.keyEnumerator()
        where (sessionKey == nil || editors.object(forKey: editor) as String? == sessionKey)
            && editor.dropEndpoint != nil && editor.isShown(in: window) {
            return editor
        }
        return nil
    }

    private static func dropSessionKey(at point: CGPoint?) -> String? {
        let focused = focusedChatID()
        let card = focused.flatMap { model?.selectedModel?.sideConversations[$0] }.flatMap { $0.isVisible ? $0 : nil }
        return FileDropTarget.resolve(
            focused: focused,
            sideConversation: card?.transcript?.session.id,
            cardFrame: card?.windowFrame ?? .zero,
            at: point
        )?.rawValue
    }

    /// A selected passage keeps its keys too, because R quotes it into the reply.
    private static func takesKeys(_ responder: NSResponder?) -> Bool {
        var current = responder
        while let each = current {
            if let text = each as? NSTextView, text.isEditable || text.selectedRange().length > 0 {
                return true
            }
            if each is BloomTerminalView || each is WKWebView
                || each is ListKeyboardHostView || each is MenuKeyHostView { return true }
            current = each.nextResponder
        }
        return false
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
