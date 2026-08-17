import SwiftUI
import BatonCore

/// The panel under the inspector: setup output, run scripts and real shells, behind one tab strip.
///
/// The tab strip is the only part of this file that owns anything. Everything a tab shows keeps
/// running whether or not the tab is selected, and whether or not the panel is expanded, because
/// all of it lives in `TerminalSessionStore`.
struct BottomPanelView: View {
    @Bindable var model: WorkspaceModel

    @State private var settings = RepoSettings()
    @State private var renamingTabID: String?
    @State private var draftName = ""

    private var sessions: TerminalSessionStore { .shared }

    private var terminalTabs: [TerminalTab] {
        sessions.tabs(for: model.workspace.id)
    }

    var body: some View {
        VStack(spacing: 0) {
            Hairline()
            tabStrip
            if model.isBottomPanelVisible {
                Hairline()
                content
            }
        }
        .background(Palette.surfaceSunken)
        .task(id: "\(model.workspace.id)|\(model.repo?.path ?? "")") {
            await load()
        }
    }

    // MARK: - Tab strip

    private var tabStrip: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal) {
                HStack(spacing: 2) {
                    if settings.setupScript != nil {
                        tabButton(.setup, title: "Setup", icon: "wrench.and.screwdriver")
                    }
                    ForEach(settings.runScripts) { script in
                        tabButton(.run(script.id), title: script.name, icon: "play")
                    }
                    ForEach(terminalTabs) { tab in
                        terminalTabButton(tab)
                    }
                }
                .padding(.horizontal, 6)
            }
            .scrollIndicators(.never)

            Divider().frame(height: 14)

            iconButton("plus", help: "New terminal tab") {
                Task {
                    let tab = await sessions.addTab(
                        workspaceID: model.workspace.id, store: model.store
                    )
                    model.bottomTab = .terminal(tab.id)
                    model.isBottomPanelVisible = true
                }
            }

            iconButton(
                model.isBottomPanelVisible ? "chevron.down" : "chevron.up",
                help: model.isBottomPanelVisible ? "Collapse the panel" : "Expand the panel"
            ) {
                model.isBottomPanelVisible.toggle()
            }
            .padding(.trailing, 6)
        }
        .frame(height: 30)
        .background(Palette.surface)
    }

    private func tabButton(_ tab: BottomTab, title: String, icon: String) -> some View {
        Button {
            select(tab)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 9, weight: .semibold))
                Text(title).font(Typo.label).lineLimit(1)
            }
            .foregroundStyle(model.bottomTab == tab ? Palette.textPrimary : Palette.textSecondary)
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(
                RoundedRectangle(cornerRadius: Metrics.cornerSmall)
                    .fill(model.bottomTab == tab ? Palette.selected : .clear)
            )
        }
        .buttonStyle(.plain)
    }

    private func terminalTabButton(_ tab: TerminalTab) -> some View {
        let isSelected = model.bottomTab == .terminal(tab.id)

        return HStack(spacing: 4) {
            Image(systemName: "terminal").font(.system(size: 9, weight: .semibold))

            if renamingTabID == tab.id {
                TextField("Name", text: $draftName)
                    .textFieldStyle(.plain)
                    .font(Typo.label)
                    .frame(width: 84)
                    .onSubmit { commitRename(tab) }
            } else {
                Text(tab.title).font(Typo.label).lineLimit(1)
            }

            Button {
                Task { await close(tab) }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Palette.textTertiary)
                    .frame(width: 14, height: 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Close this terminal")
        }
        .foregroundStyle(isSelected ? Palette.textPrimary : Palette.textSecondary)
        .padding(.leading, 8)
        .padding(.trailing, 3)
        .frame(height: 22)
        .background(
            RoundedRectangle(cornerRadius: Metrics.cornerSmall)
                .fill(isSelected ? Palette.selected : .clear)
        )
        .contentShape(Rectangle())
        .onTapGesture { select(.terminal(tab.id)) }
        .contextMenu {
            Button("Rename") {
                draftName = tab.title
                renamingTabID = tab.id
            }
            Button("Close") { Task { await close(tab) } }
        }
    }

    private func iconButton(_ symbol: String, help: String, run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Palette.textSecondary)
                .frame(width: 24, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch model.bottomTab {
        case .setup:
            SetupLogView(model: model)

        case .run(let id):
            if let script = settings.runScripts.first(where: { $0.id == id }) {
                RunScriptView(model: model, script: script)
            } else {
                placeholder("That run script is no longer in the repo settings.")
            }

        case .terminal(let id):
            if let tab = terminalTabs.first(where: { $0.id == id }) {
                TerminalView(
                    tab: tab,
                    workspace: model.workspace,
                    repo: model.repo,
                    port: model.port
                )
                .id(tab.id)
            } else {
                placeholder("Opening a terminal.")
            }
        }
    }

    private func placeholder(_ message: String) -> some View {
        Text(message)
            .font(Typo.label)
            .foregroundStyle(Palette.textTertiary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Palette.surfaceSunken)
    }

    // MARK: - Actions

    private func select(_ tab: BottomTab) {
        model.bottomTab = tab
        model.isBottomPanelVisible = true
        renamingTabID = nil
    }

    private func commitRename(_ tab: TerminalTab) {
        let name = draftName
        renamingTabID = nil
        Task { await sessions.rename(tab, to: name, store: model.store) }
    }

    private func close(_ tab: TerminalTab) async {
        let remaining = await sessions.closeTab(tab, store: model.store)
        if model.bottomTab == .terminal(tab.id), let next = remaining.first {
            model.bottomTab = .terminal(next.id)
        }
    }

    /// Settings come off disk, so they are read away from the main thread. The selected tab is
    /// reconciled afterwards because `WorkspaceModel` starts out pointing at a placeholder id.
    private func load() async {
        sessions.useStore(model.store)

        let path = model.repo?.path
        if let path {
            settings = await Task.detached(priority: .userInitiated) {
                SettingsLoader.load(repo: path)
            }.value
        }

        await sessions.load(workspaceID: model.workspace.id, store: model.store)
        if model.port == 0 { model.port = PortAllocator.allocate(taken: []) }

        reconcileSelection()
    }

    private func reconcileSelection() {
        switch model.bottomTab {
        case .setup:
            if settings.setupScript == nil { selectFirstTerminal() }
        case .run(let id):
            if !settings.runScripts.contains(where: { $0.id == id }) { selectFirstTerminal() }
        case .terminal(let id):
            if !terminalTabs.contains(where: { $0.id == id }) { selectFirstTerminal() }
        }
    }

    private func selectFirstTerminal() {
        guard let first = terminalTabs.first else { return }
        model.bottomTab = .terminal(first.id)
    }
}
