import AppKit
import SwiftUI

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
                model.isCreatingWorkspace = true
            }
            .keyboardShortcut("n", modifiers: .command)
            .disabled(model.repos.isEmpty)

            Button("New Session") {
                guard let workspace = model.selectedModel else { return }
                Task { await workspace.createSession() }
            }
            .keyboardShortcut("t", modifiers: .command)
            .disabled(model.selectedModel == nil)

            Divider()

            Button("Add Project Folder") {
                addProjectFolder()
            }
            .keyboardShortcut("o", modifiers: [.command, .shift])
        }

        CommandGroup(after: .saveItem) {
            Button("Close Session") {
                guard let workspace = model.selectedModel,
                      let session = workspace.activeSession else { return }
                Task { await workspace.closeSession(session) }
            }
            .keyboardShortcut("w", modifiers: .command)
            .disabled(model.selectedModel?.activeSession == nil)
        }

        CommandGroup(after: .pasteboard) {
            Button("Find Workspace") {
                model.selection = .search
            }
            .keyboardShortcut("f", modifiers: .command)
            .disabled(model.workspaces.isEmpty)
        }

        CommandGroup(after: .sidebar) {
            Button("Toggle Sidebar") {
                NSApp.sendAction(#selector(NSSplitViewController.toggleSidebar(_:)), to: nil, from: nil)
            }
            .keyboardShortcut("s", modifiers: [.command, .control])

            Button("Toggle Inspector") {
                guard let workspace = model.selectedModel else { return }
                workspace.isInspectorVisible.toggle()
            }
            .keyboardShortcut("i", modifiers: [.command, .option])
            .disabled(model.selectedModel == nil)

            Button("Toggle Bottom Panel") {
                guard let workspace = model.selectedModel else { return }
                workspace.isBottomPanelVisible.toggle()
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

    private func addProjectFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Add Project"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await model.addRepository(at: url.path) }
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
