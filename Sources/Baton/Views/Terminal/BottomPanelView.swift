import SwiftUI
import BatonCore

/// The panel at the bottom of the inspector: setup output, run scripts and real shells, behind one
/// tab strip.
///
/// The tab strip is the only part of this file that owns anything. Everything a tab shows keeps
/// running whether or not the tab is selected, and whether or not the panel is expanded, because
/// all of it lives in `TerminalSessionStore`.
struct BottomPanelView: View {
    @Bindable var model: WorkspaceModel
    @Environment(AppModel.self) private var app

    @State private var settings = RepoSettings()
    @State private var renamingTabID: String?
    @State private var draftName = ""

    private var sessions: TerminalSessionStore { .shared }

    private var terminalTabs: [TerminalTab] {
        sessions.tabs(for: model.workspace.id)
    }

    var body: some View {
        // No rule above the strip: the boundary between the files and the panel is the inspector's
        // divider, and a second hairline under it reads as a double rule.
        VStack(spacing: 0) {
            tabStrip
            if app.isBottomPanelVisible {
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

    /// Wide enough for the names terminals actually get, and the same width for every tab so the
    /// strip does not jump as the rename editor opens.
    private static let renameWidth: CGFloat = 90

    private var tabStrip: some View {
        // Collapse first, then the tabs, then the one control that adds to them. The chevron leads
        // because it acts on the whole panel rather than on any tab, and it stays put as tabs come
        // and go, which a control at the end of a scrolling row does not.
        HStack(spacing: 0) {
            iconButton(
                app.isBottomPanelVisible ? "chevron.down" : "chevron.up",
                help: app.isBottomPanelVisible ? "Collapse the panel" : "Expand the panel"
            ) {
                app.isBottomPanelVisible.toggle()
            }

            Hairline(axis: .vertical)

            ScrollView(.horizontal) {
                tabRow
            }
            .scrollIndicators(.never)

            Hairline(axis: .vertical)

            iconButton("plus", help: "New terminal tab") {
                Task {
                    let tab = await sessions.addTab(
                        workspaceID: model.workspace.id, store: model.store
                    )
                    model.bottomTab = .terminal(tab.id)
                    app.isBottomPanelVisible = true
                }
            }
        }
        .frame(height: Metrics.barHeight)
        .headerMaterial()
    }

    /// A rule between neighbours and never before the first tab, which is what makes a run of
    /// labels read as tabs now that the selected one is no longer a coloured pill.
    private var tabRow: some View {
        let hasSetup = settings.setupScript != nil
        let hasScripts = !settings.runScripts.isEmpty

        return HStack(spacing: 0) {
            if hasSetup {
                tabButton(.setup, title: "Setup", icon: "wrench.and.screwdriver")
            }

            ForEach(Array(settings.runScripts.enumerated()), id: \.element.id) { index, script in
                if hasSetup || index > 0 { Hairline(axis: .vertical) }
                tabButton(.run(script.id), title: script.name, icon: "play")
            }

            ForEach(Array(terminalTabs.enumerated()), id: \.element.id) { index, tab in
                if hasSetup || hasScripts || index > 0 { Hairline(axis: .vertical) }
                terminalTabButton(tab)
            }
        }
    }

    private func tabButton(_ tab: BottomTab, title: String, icon: String) -> some View {
        Button {
            select(tab)
        } label: {
            HStack(spacing: Metrics.spacingSmall) {
                Image(systemName: icon)
                    .imageScale(.small)
                Text(title).lineLimit(1)
            }
            .font(Typo.label)
            .foregroundStyle(model.bottomTab == tab ? Palette.textPrimary : Palette.textSecondary)
            .tabChrome(isSelected: model.bottomTab == tab)
        }
        .buttonStyle(.plain)
        .help(title)
    }

    private func terminalTabButton(_ tab: TerminalTab) -> some View {
        let isSelected = model.bottomTab == .terminal(tab.id)

        return HStack(spacing: Metrics.spacingSmall) {
            Image(systemName: "terminal")
                .imageScale(.small)

            if renamingTabID == tab.id {
                TextField("Name", text: $draftName)
                    .textFieldStyle(.plain)
                    .frame(width: Self.renameWidth)
                    .onSubmit { commitRename(tab) }
                    .onExitCommand { renamingTabID = nil }
            } else {
                Text(tab.title).lineLimit(1)
            }

            Button {
                Task { await close(tab) }
            } label: {
                Image(systemName: "xmark")
                    .imageScale(.small)
                    .foregroundStyle(Palette.textTertiary)
                    .frame(width: Metrics.glyph, height: Metrics.glyph)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help("Close this terminal")
        }
        .font(Typo.label)
        .foregroundStyle(isSelected ? Palette.textPrimary : Palette.textSecondary)
        .tabChrome(isSelected: isSelected)
        .onTapGesture { select(.terminal(tab.id)) }
        .help(tab.title)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(tab.title)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
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
                .font(Typo.labelEmphasis)
                .imageScale(.small)
                .foregroundStyle(Palette.textSecondary)
                .frame(width: Metrics.barHeight, height: Metrics.barHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
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
                EmptyStateView(
                    glyph: "play.slash",
                    title: "That run script is gone",
                    message: "It is no longer listed in this repository's settings."
                )
                .background(Palette.surfaceSunken)
            }

        case .terminal(let id):
            // Falling back to the first tab matters because `WorkspaceModel` selects terminals by
            // a placeholder id before any tab exists. Reconciling only on load left the panel
            // stuck on the spinner whenever the selection was set again afterwards.
            if let tab = terminalTabs.first(where: { $0.id == id }) ?? terminalTabs.first {
                // SwiftTerm draws its first glyph on the view's own edge, so without this the
                // shell's prompt sits flush against the tab strip above it and the window edge to
                // its left. Every terminal on this platform insets its text.
                TerminalView(
                    tab: tab,
                    workspace: model.workspace,
                    repo: model.repo,
                    port: model.port
                )
                .id(tab.id)
                .padding(Metrics.spacing)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Palette.surfaceSunken)
            } else {
                LoadingView("Opening a terminal")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Palette.surfaceSunken)
            }
        }
    }

    // MARK: - Actions

    private func select(_ tab: BottomTab) {
        model.bottomTab = tab
        app.isBottomPanelVisible = true
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
        if model.port == 0 { model.port = (try? PortAllocator.allocate(taken: [])) ?? 0 }

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

/// The shape every tab in this strip shares: the full height of the bar, the panel's own colour
/// when it is the selected one, and nothing at all when it is not.
///
/// A rounded rectangle of selection grey floating inside the strip is a browser idiom. Filling the
/// bar and taking the colour of the surface below is what an editor tab does on this platform, and
/// it is what stops the selected tab reading as a painted block.
private struct BottomTabChrome: ViewModifier {
    var isSelected: Bool

    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, Metrics.inset)
            .frame(height: Metrics.barHeight)
            .background(isSelected ? Palette.surfaceSunken : (isHovered ? Palette.hover : .clear))
            .contentShape(Rectangle())
            .onHover { isHovered = $0 }
    }
}

private extension View {
    func tabChrome(isSelected: Bool) -> some View {
        modifier(BottomTabChrome(isSelected: isSelected))
    }
}
