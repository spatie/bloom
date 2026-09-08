import AppKit
import SwiftUI
import BloomCore
import MarkdownEngine

/// The open-source editor owns Markdown styling, text layout and undo. This host only connects
/// native focus and toolbar edits to Bloom, keeping the same autosave and keyboard protections.
struct NotesMarkdownEditor: NSViewControllerRepresentable {
    @Binding var text: String
    var isEditing: FocusState<Bool>.Binding
    var workspaceID: WorkspaceID
    var isEditable: Bool
    var showsSource: Bool
    var commands: NotesFormattingCommands
    @Environment(\.colorScheme) private var colorScheme

    private var editor: NativeTextViewWrapper {
        var configuration = MarkdownEditorConfiguration.default
        configuration.textInsets = .init(horizontal: NotesPage.textPadding, vertical: 0)
        configuration.paragraph.lineHeightExtraSpacing = 3
        configuration.rawSourceMode = showsSource
        configuration.lists.autoClosePairsEnabled = false
        configuration.spellChecking = .init(continuousSpellChecking: false, grammarChecking: false, automaticSpellingCorrection: false)
        configuration.overscroll.percent = 0.15
        let font = showsSource ? NSFont.monospacedSystemFont(ofSize: 13, weight: .regular) : NSFont.systemFont(ofSize: 14)
        return NativeTextViewWrapper(
            text: $text, configuration: configuration, fontName: font.fontName, fontSize: font.pointSize,
            documentId: workspaceID.rawValue, isEditable: isEditable,
            placeholder: isEditable ? NSAttributedString(string: "Start writing…", attributes: [
                .font: font, .foregroundColor: NSColor.placeholderTextColor,
            ]) : nil
        )
    }

    func makeNSViewController(context: Context) -> NotesEditorController {
        let controller = NotesEditorController(rootView: editor)
        controller.sizingOptions = []
        configure(controller)
        return controller
    }

    func updateNSViewController(_ controller: NotesEditorController, context: Context) {
        controller.rootView = editor
        configure(controller)
    }

    private func configure(_ controller: NotesEditorController) {
        commands.controller = controller
        controller.onFocusChange = { isEditing.wrappedValue = $0 }
        let appearance: NSAppearance.Name = colorScheme == .dark ? .darkAqua : .aqua
        if controller.view.appearance?.name != appearance { controller.view.appearance = NSAppearance(named: appearance) }
        controller.requestFocus(isEditing.wrappedValue)
        controller.scheduleConnection()
    }

    static func dismantleNSViewController(_ controller: NotesEditorController, coordinator: ()) {
        controller.disconnect()
    }
}

@MainActor
final class NotesFormattingCommands {
    weak var controller: NotesEditorController?
    func apply(_ action: NoteFormatting.Action) { controller?.apply(action) }
}

@MainActor
final class NotesEditorController: NSHostingController<NativeTextViewWrapper> {
    private(set) weak var textView: NSTextView?
    private weak var observedWindow: NSWindow?
    private var observer: NSObjectProtocol?
    private weak var observedUndoManager: UndoManager?
    private var undoObservers: [NSObjectProtocol] = []
    private var connectionScheduled = false
    private var isDisconnected = false
    private var requestedFocus = false
    private var needsFocus = false
    private var reportedFocus = false
    var onFocusChange: (Bool) -> Void = { _ in }

    override func viewDidLayout() {
        super.viewDidLayout()
        scheduleConnection()
    }

    func requestFocus(_ value: Bool) {
        if value && !requestedFocus { needsFocus = true }
        requestedFocus = value
    }

    func scheduleConnection() {
        guard !connectionScheduled, !isDisconnected else { return }
        connectionScheduled = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.connectionScheduled = false
            self.connect()
        }
    }

    private func connect() {
        guard !isDisconnected else { return }
        let found = findTextView(in: view)
        if textView !== found {
            textView = found
            textView?.writingToolsBehavior = .none
            textView?.isAutomaticQuoteSubstitutionEnabled = false
            textView?.isAutomaticDashSubstitutionEnabled = false
            textView?.isAutomaticTextReplacementEnabled = false
            textView?.setAccessibilityLabel("Workspace notes")
        }
        connectUndoManager()
        if observedWindow !== view.window {
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            observedWindow = view.window
            if let window = view.window {
                let refresh: @MainActor @Sendable () -> Void = { [weak self] in self?.reportFocus() }
                observer = NotificationCenter.default.addObserver(
                    forName: NSWindow.didUpdateNotification, object: window, queue: .main
                ) { _ in
                    Task { @MainActor in refresh() }
                }
            }
        }
        if needsFocus, let textView, textView.isEditable, let window = view.window {
            needsFocus = false
            window.makeFirstResponder(textView)
        }
        reportFocus()
    }

    private func connectUndoManager() {
        let manager = textView?.undoManager
        guard observedUndoManager !== manager else { return }
        undoObservers.forEach(NotificationCenter.default.removeObserver)
        undoObservers = []
        observedUndoManager = manager
        guard let manager, let textView else { return }
        // AppKit can restore the text storage without the editor publishing its Markdown
        // binding. Refresh through the normal delegate path after the whole group settles.
        let refresh: @MainActor @Sendable () -> Void = { [weak self, weak textView, weak manager] in
            guard let self, let textView, let manager, !self.isDisconnected,
                  self.textView === textView, self.observedUndoManager === manager else { return }
            textView.didChangeText()
        }
        undoObservers = [Notification.Name.NSUndoManagerDidUndoChange, .NSUndoManagerDidRedoChange].map { name in
            NotificationCenter.default.addObserver(forName: name, object: manager, queue: .main) { _ in
                Task { @MainActor in refresh() }
            }
        }
    }

    private func reportFocus() {
        guard let textView else { return }
        let focused = view.window?.firstResponder === textView
        guard focused != reportedFocus else { return }
        reportedFocus = focused
        onFocusChange(focused)
    }

    func apply(_ action: NoteFormatting.Action) {
        guard let textView, textView.isEditable,
              let edit = NoteFormatting.edit(action, text: textView.string, selection: textView.selectedRange()) else { return }
        view.window?.makeFirstResponder(textView)
        let undo = textView.undoManager
        textView.breakUndoCoalescing()
        undo?.beginUndoGrouping()
        for replacement in edit.replacements {
            textView.insertText(replacement.text, replacementRange: replacement.range)
        }
        undo?.endUndoGrouping()
        textView.breakUndoCoalescing()
        textView.setSelectedRange(edit.selection)
        textView.scrollRangeToVisible(edit.selection)
        reportFocus()
    }

    func disconnect() {
        isDisconnected = true
        onFocusChange = { _ in }
        if let observer { NotificationCenter.default.removeObserver(observer) }
        undoObservers.forEach(NotificationCenter.default.removeObserver)
        undoObservers = []
        observedUndoManager = nil
        observer = nil
        observedWindow = nil
        textView = nil
    }

    private func findTextView(in root: NSView) -> NSTextView? {
        if let text = root as? NSTextView { return text }
        return root.subviews.lazy.compactMap { self.findTextView(in: $0) }.first
    }
}
