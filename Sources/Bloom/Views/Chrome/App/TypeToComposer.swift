import AppKit
import WebKit
import BloomCore

/// Typing or pasting with nothing taking it goes to the focused chat's composer. The event is
/// handed back rather than replayed, so dead keys and input methods still work.
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
                redirect(isPaste: ComposerTypeAhead.isPaste(characters: characters, modifiers: modifiers))
            }
            return event
        }
    }

    /// Keyed by session: one composer is reused across workspaces, and the previous column stays
    /// laid out out of sight.
    static func register(_ editor: ComposerEditorHandle, showing sessionKey: String) {
        editors.setObject(sessionKey as NSString, forKey: editor)
    }

    private static func redirect(isPaste: Bool) {
        guard let window = NSApp.keyWindow,
              window.canBecomeMain, !window.isSheet, window.attachedSheet == nil,
              !takesKeys(window.firstResponder, isPaste: isPaste),
              let sessionKey = (isPaste ? selectedConversation(in: window) : nil) ?? focusedChat()
        else { return }
        for case let editor as ComposerEditorHandle in editors.keyEnumerator()
        where editors.object(forKey: editor) as String? == sessionKey {
            if editor.takeKeyboard(in: window) { return }
        }
    }

    /// A side conversation is not the focused pane, so its selection names its own composer.
    private static func selectedConversation(in window: NSWindow) -> String? {
        guard let view = window.firstResponder as? NSView else { return nil }
        return SelectionToChat.transcript(containing: view)?.session?.rawValue
    }

    private static func focusedChat() -> String? {
        guard let workspace = model?.selectedModel else { return nil }
        let tabs = WorkspaceTabsStore.shared
        guard let tab = tabs.selectedTab(in: workspace),
              case .chat(let sessionID) = tabs.content(of: tabs.focusedPane(of: tab), in: tab)
        else { return nil }
        return sessionID.rawValue
    }

    /// A selected passage keeps typed keys too, because R quotes it into the reply. See
    /// `ComposerTypeAhead.isPaste` for why it does not keep Command+V.
    private static func takesKeys(_ responder: NSResponder?, isPaste: Bool) -> Bool {
        var current = responder
        while let each = current {
            if let text = each as? NSTextView,
               text.isEditable || (!isPaste && text.selectedRange().length > 0) {
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
