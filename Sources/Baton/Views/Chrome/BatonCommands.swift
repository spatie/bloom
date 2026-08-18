import AppKit
import SwiftUI
import BatonCore

/// Keeps keyboard-driven navigation available even when focus is inside a transcript or terminal.
@MainActor
struct BatonCommands: Commands {
    private let model: AppModel

    init(model: AppModel) {
        self.model = model
    }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Workspace") {
                // The sheet lives in RootView, and the sidebar and Home already open it this way.
                // Setting a flag on the model instead would leave it stuck true with no sheet.
                NotificationCenter.default.post(name: .batonNewWorkspace, object: nil)
            }
            .keyboardShortcut("n", modifiers: .command)
            .disabled(model.repos.isEmpty)

            Button("New Session") {
                guard let workspace = model.selectedModel else { return }
                Task { await workspace.createSession() }
            }
            .keyboardShortcut("t", modifiers: .command)
            .disabled(model.selectedModel == nil)

            // Cmd+W belongs to the session, not the window. Baton has no Save item, so a group
            // anchored after `.saveItem` is dropped whole and Cmd+W falls through to the system
            // Close, which used to end the process and every agent with it.
            Button("Close Session") {
                guard let workspace = model.selectedModel,
                      let session = workspace.activeSession,
                      CloseSessionAlert.allowsClosing(session, in: workspace) else { return }
                Task { await workspace.closeSession(session) }
            }
            .keyboardShortcut("w", modifiers: .command)
            .disabled(model.selectedModel?.activeSession == nil)

            Divider()

            Button("Add Project Folder", action: addProjectFolder)
            .keyboardShortcut("o", modifiers: [.command, .shift])
        }

        CommandGroup(after: .pasteboard) {
            Button("Find Workspace") {
                model.selection = .search
            }
            .keyboardShortcut("f", modifiers: .command)
            .disabled(model.workspaces.isEmpty)
        }

        // Splitting the centre column. Cmd+D is deliberately not used: a terminal pane already
        // owns it for splitting shells, and one keystroke that splits two different things
        // depending on where the pointer last was is worse than two that each mean one thing.
        CommandGroup(after: .sidebar) {
            Button("Split Right") { splitCentre(.horizontal) }
                .keyboardShortcut("\\", modifiers: .command)
                .disabled(model.selectedModel == nil)

            Button("Split Down") { splitCentre(.vertical) }
                .keyboardShortcut("\\", modifiers: [.command, .shift])
                .disabled(model.selectedModel == nil)

            Button("Close Pane") { closeCentrePane() }
                .keyboardShortcut("w", modifiers: [.command, .control])
                .disabled(model.selectedModel == nil)

            Divider()
        }

        CommandGroup(after: .sidebar) {
            Button("Toggle Sidebar") {
                // `NavigationSplitView` owns the sidebar's visibility through the binding RootView
                // holds, not through `toggleSidebar(_:)` on the responder chain, so this goes to
                // RootView rather than to first responder.
                NotificationCenter.default.post(name: .batonToggleSidebar, object: nil)
            }
            .keyboardShortcut("s", modifiers: [.command, .control])

            Button("Toggle Inspector") {
                guard model.selectedModel != nil else { return }
                model.isInspectorVisible.toggle()
            }
            .keyboardShortcut("i", modifiers: [.command, .option])
            .disabled(model.selectedModel == nil)

            Button("Toggle Bottom Panel") {
                guard model.selectedModel != nil else { return }
                model.isBottomPanelVisible.toggle()
            }
            .keyboardShortcut("b", modifiers: [.command, .option])
            .disabled(model.selectedModel == nil)

            Divider()

            Button("Next Workspace") {
                model.selectNextWorkspace(offset: 1)
            }
            .keyboardShortcut(.downArrow, modifiers: [.command, .option])
            .disabled(model.workspaces.isEmpty)

            Button("Previous Workspace") {
                model.selectNextWorkspace(offset: -1)
            }
            .keyboardShortcut(.upArrow, modifiers: [.command, .option])
            .disabled(model.workspaces.isEmpty)

            Button("Next Unread") {
                model.selectNextUnread()
            }
            .keyboardShortcut("u", modifiers: [.command, .shift])
            .disabled(!model.workspaces.contains(where: \.unread))

            Button("Go to Home") {
                model.selection = .home
            }
            .keyboardShortcut("0", modifiers: .command)
            .disabled(model.selection == .home)
        }

        CommandMenu("Workspace") {
            Button("Archive Workspace") {
                archiveSelectedWorkspace()
            }
            .keyboardShortcut(.delete, modifiers: .command)
            .disabled(model.selectedWorkspace == nil)

            Divider()

            Button("Open in Editor") {
                guard let workspace = model.selectedWorkspace else { return }
                Reveal.inEditor(workspace.path)
            }
            .keyboardShortcut("e", modifiers: [.command, .shift])
            .disabled(model.selectedWorkspace == nil)

            Button("Reveal in Finder") {
                guard let workspace = model.selectedWorkspace else { return }
                Reveal.inFinder(workspace.path)
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .disabled(model.selectedWorkspace == nil)

            Button("Copy Branch Name") {
                guard let workspace = model.selectedWorkspace else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(workspace.branch, forType: .string)
            }
            .keyboardShortcut("c", modifiers: [.command, .shift])
            .disabled(model.selectedWorkspace == nil)

            Divider()

            Button("Stop Agent") {
                model.selectedModel?.activeTranscript?.stop()
            }
            .keyboardShortcut(".", modifiers: .command)
            .disabled(model.selectedModel?.activeTranscript?.isRunning != true)
        }

        CommandGroup(replacing: .help) {
            Button("Baton Help") {
                guard let url = URL(string: "https://github.com/spatie/Baton#readme") else { return }
                NSWorkspace.shared.open(url)
            }
            .keyboardShortcut("?", modifiers: .command)
        }
    }

    /// Splits the pane the user is in and shows the same tab in the half that opens, which is what
    /// splitting means in every editor: the same thing twice, and then you change one of them.
    private func splitCentre(_ axis: SplitAxis) {
        guard let workspace = model.selectedModel else { return }
        let panes = CenterPaneStore.shared
        let pane = panes.focusedPane(in: workspace.workspace.id)
        panes.split(
            workspace.workspace.id,
            pane: pane,
            axis: axis,
            showing: panes.content(of: pane, in: workspace)
        )
    }

    private func closeCentrePane() {
        guard let workspace = model.selectedModel else { return }
        let panes = CenterPaneStore.shared
        _ = panes.close(pane: panes.focusedPane(in: workspace.workspace.id), in: workspace.workspace.id)
    }

    private func addProjectFolder() {
        guard let path = ProjectFolderPicker.choose() else { return }
        Task { await model.addRepository(at: path) }
    }

    private func archiveSelectedWorkspace() {
        guard let workspace = model.selectedWorkspace else { return }

        let stored = UserDefaults.standard.object(forKey: "confirmBeforeArchiving") as? Bool
        if stored ?? true {
            let alert = NSAlert()
            alert.messageText = "Archive \(workspace.name)?"
            alert.informativeText = "The worktree will be removed."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Archive")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }

        Task { await model.archive(workspace) }
    }
}
