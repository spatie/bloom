import SwiftUI
import BloomCore

/// Uses the same tab chrome as local workspaces; only the actions change their execution host.
struct RemoteWorkspaceTabsView: View {
    @Bindable var model: ServerWindowModel
    @Environment(AppModel.self) private var app
    @Namespace private var selection

    private var selectedID: String {
        switch model.activePane {
        case "terminal": "terminal-" + model.selectedTerminal
        case "preview": "preview"
        default: model.selectedSessionID?.rawValue ?? ""
        }
    }

    var body: some View {
        TabStrip(selection: AnyHashable(selectedID)) {
            Color.clear.frame(width: Metrics.spacingWide)
        } tabs: {
            HStack(spacing: 0) {
                ForEach(model.catalogue?.sessions.filter { $0.workspaceID == model.selectedWorkspace?.id } ?? []) { session in
                    tab(session.title.isEmpty ? "Chat" : session.title, id: session.id.rawValue, glyph: PaneGlyph.chat) {
                        app.selection = .remote(session.id)
                        model.activePane = "chat"
                    }
                }
                ForEach(model.availableTerminals) { pane in
                    tab(pane.title, id: "terminal-" + pane.id.rawValue, glyph: PaneGlyph.terminal) {
                        model.selectedTerminal = pane.id.rawValue
                        model.activePane = "terminal"
                    }
                }
                tab("Preview", id: "preview", glyph: PaneGlyph.browser) { model.activePane = "preview" }
            }
        } append: {
            Menu {
                Button("New Chat", systemImage: PaneGlyph.chat) { Task {
                    if let id = await model.newChat() { app.selection = .remote(id); model.activePane = "chat" }
                } }
                Button("New Terminal", systemImage: PaneGlyph.terminal) { model.newTerminal() }
                if !model.runScripts.isEmpty {
                    Divider()
                    ForEach(model.runScripts) { script in
                        Button(script.name, systemImage: "play") { Task { await model.runScript(script) } }
                    }
                }
            } label: { Image(systemName: "plus") }
                .menuStyle(.borderlessButton).fixedSize()
                .help("New tab").accessibilityLabel("New tab")
                .disabled(!model.isConnected || model.isPerformingCommand)
                .padding(.horizontal, 10)
        } trailing: {
            EmptyView()
        }
    }

    private func tab(_ title: String, id: String, glyph: String, action: @escaping @MainActor () -> Void) -> some View {
        TabItemView(title: title, icon: .symbol(glyph), isActive: selectedID == id,
            isRenaming: false, editableTitle: title, canClose: false, canRename: false,
            closeTitle: "Close tab", onSelect: action, onStartRename: {}, onCommitRename: { _ in },
            onCancelRename: {}, onClose: {}, namespace: selection)
            .id(id)
    }
}
