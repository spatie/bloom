import AppKit
import BatonCore

/// Turns text selected in any other app into a Baton workspace, through the system Services menu.
///
/// The interesting question is which project the workspace belongs to, because a Service arrives
/// with a string and nothing else: no window, no selection, no context at all. Silently guessing
/// and cutting a branch would be the wrong trade, since creating a workspace writes a worktree to
/// disk and is not undone by pressing Escape. So the Service confirms, in a small panel that shows
/// the text it captured and lets the project be changed, with the last project used here already
/// chosen. One extra keystroke, and nothing irreversible happens by accident.
///
/// The panel is AppKit rather than the app's own `CreateWorkspaceSheet`, because a Service can
/// arrive while Baton has no window on screen at all, and a sheet needs one to hang from.
@MainActor
final class BatonServicesProvider: NSObject {
    /// The project this Service was last pointed at. A Service has no other memory, and the
    /// realistic case is somebody sending several snippets to the same repository in a row.
    private static let lastRepoKey = "services.lastRepoID"

    /// Wide enough for a sentence of captured text without the panel reading as a window, and tall
    /// enough for the four or five lines somebody is likely to have selected.
    private static let width: CGFloat = 380
    private static let textHeight: CGFloat = 110
    private static let gap: CGFloat = 8

    private weak var app: AppModel?

    func attach(_ model: AppModel) {
        app = model
    }

    @objc(createWorkspaceFromSelection:userData:error:)
    func createWorkspaceFromSelection(
        _ pasteboard: NSPasteboard,
        userData: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString?>
    ) {
        guard let text = pasteboard.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            error.pointee = "There was no text to start a workspace from." as NSString
            return
        }

        guard let app, !app.repos.isEmpty else {
            error.pointee = "Add a project folder to Baton before starting a workspace." as NSString
            return
        }

        NSApp.activate(ignoringOtherApps: true)
        guard let (repo, prompt) = confirm(text: text, in: app) else { return }

        UserDefaults.standard.set(repo.id, forKey: Self.lastRepoKey)
        NSApp.windows.first?.makeKeyAndOrderFront(nil)
        Task { await app.createWorkspace(in: repo, prompt: prompt) }
    }

    // MARK: - The panel

    /// Nil when the user cancelled.
    ///
    /// Laid out with frames in a plain `NSView` rather than an `NSStackView`. An alert's accessory
    /// view is sized from its frame and never given a layout pass of its own, so a stack view sits
    /// there at its intrinsic size with the scroll view collapsed to nothing, which is what the
    /// first version of this panel showed: a project popup and an empty grey rectangle.
    private func confirm(text: String, in app: AppModel) -> (Repo, String)? {
        let projects = NSPopUpButton(
            frame: NSRect(x: 0, y: Self.textHeight + Self.gap, width: Self.width, height: 25),
            pullsDown: false
        )
        for repo in app.repos { projects.addItem(withTitle: repo.name) }
        projects.selectItem(at: defaultRepoIndex(in: app))

        let scroller = NSScrollView(frame: NSRect(x: 0, y: 0, width: Self.width, height: Self.textHeight))
        scroller.hasVerticalScroller = true
        scroller.borderType = .bezelBorder

        let field = NSTextView(frame: scroller.contentView.bounds)
        field.string = text
        field.font = .preferredFont(forTextStyle: .body)
        field.isRichText = false
        field.isVerticallyResizable = true
        field.autoresizingMask = [.width]
        field.textContainer?.containerSize = NSSize(
            width: scroller.contentView.bounds.width, height: .greatestFiniteMagnitude
        )
        field.textContainer?.widthTracksTextView = true
        scroller.documentView = field

        let accessory = NSView(frame: NSRect(
            x: 0, y: 0, width: Self.width, height: Self.textHeight + Self.gap + 25
        ))
        accessory.addSubview(projects)
        accessory.addSubview(scroller)

        let alert = NSAlert()
        alert.messageText = "Start a workspace from this text?"
        alert.informativeText = "Baton cuts a branch and a worktree, then sends this to the agent."
        alert.accessoryView = accessory
        alert.addButton(withTitle: "Create Workspace")
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }

        let index = projects.indexOfSelectedItem
        guard index >= 0, index < app.repos.count else { return nil }
        let prompt = field.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return nil }
        return (app.repos[index], prompt)
    }

    /// The project this Service used last, then whatever the window is showing, then the first one.
    private func defaultRepoIndex(in app: AppModel) -> Int {
        let remembered = UserDefaults.standard.string(forKey: Self.lastRepoKey)
        let selected = app.selectedWorkspace.flatMap { app.repo(for: $0) }?.id
        for candidate in [remembered, selected] {
            if let candidate, let index = app.repos.firstIndex(where: { $0.id == candidate }) {
                return index
            }
        }
        return 0
    }
}
