import SwiftUI
import BloomCore

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
    /// Which terminal tab the pointer is over, so only that one shows its close button. A row of
    /// permanent crosses is noise, and no tab strip on this platform draws one.
    @State private var hoveredTabID: String?

    /// Read here as well as in the terminal itself, because the selected tab takes its colour from
    /// the pane it opens and that pane is only the user's theme while this is on.
    @AppStorage(TerminalGhostty.defaultsKey) private var usesGhosttyTheme = true
    @Environment(\.colorScheme) private var colorScheme

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
        let isSelected = model.bottomTab == tab
        let pane = surface(of: tab)

        return Button {
            select(tab)
        } label: {
            HStack(spacing: Metrics.spacingSmall) {
                Image(systemName: icon)
                    .imageScale(.small)
                Text(title).lineLimit(1)
            }
            .font(Typo.label)
            .foregroundStyle(isSelected ? pane.ink : Palette.textSecondary)
            .tabChrome(isSelected: isSelected, fill: pane.fill)
        }
        .buttonStyle(.plain)
        .help(title)
    }

    private func terminalTabButton(_ tab: TerminalTab) -> some View {
        let isSelected = model.bottomTab == .terminal(tab.id)
        let pane = surface(of: .terminal(tab.id))

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

            // Kept in the layout at all times, so a tab does not change width under the pointer as
            // it arrives, which would walk the whole strip sideways.
            Button("Close this terminal", systemImage: "xmark") {
                Task { await close(tab) }
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.accessoryBar)
            .controlSize(.small)
            // The size the tab's own glyph is drawn at. Without it the cross came out larger than
            // the terminal mark it sits beside.
            .imageScale(.small)
            // `.accessoryBar` tints its glyph with the label colour, which is the one colour that
            // is guaranteed NOT to read once the selected tab is carrying a dark terminal's ground
            // in a light window.
            .foregroundStyle(isSelected ? pane.ink : Palette.textSecondary)
            .opacity(hoveredTabID == tab.id || isSelected ? 1 : 0)
            .help("Close this terminal")
        }
        .font(Typo.label)
        .foregroundStyle(isSelected ? pane.ink : Palette.textSecondary)
        .tabChrome(isSelected: isSelected, fill: pane.fill)
        .onHoverChange { inside in
            hoveredTabID = inside ? tab.id : (hoveredTabID == tab.id ? nil : hoveredTabID)
        }
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

    /// The glyph carries neither a font nor a colour of its own: `.accessoryBar` is the system's
    /// style for a control in a strip like this, and it sizes and tints the glyph, and draws the
    /// hover and pressed states, the way every other bar on the Mac does. Setting a font and then
    /// an `.imageScale(.small)` on top of it shrank the mark twice over.
    private func iconButton(_ symbol: String, help: String, run: @escaping () -> Void) -> some View {
        Button(help, systemImage: symbol, action: run)
            .labelStyle(.iconOnly)
            .buttonStyle(.accessoryBar)
            .frame(width: Metrics.barHeight, height: Metrics.barHeight)
            .help(help)
    }

    /// What the pane under the strip is actually painted with, and the ink that sits on it.
    ///
    /// A selected tab is the top of the pane it opens rather than a lid laid over it, which is
    /// what the fill is for. Every pane here draws the sunken surface except a terminal running
    /// the user's own Ghostty theme, which draws whatever that theme says: a light grey tab above
    /// a black shell is the seam that gave the panel away as two views stacked by accident.
    ///
    /// The pairing is taken whole or not at all. A theme that names a ground but no ink leaves
    /// nothing that is guaranteed to read on it, and a tab whose own name has disappeared is
    /// worse than one that does not match the shell below it.
    private func surface(of tab: BottomTab) -> (fill: Color, ink: Color) {
        let panel = (fill: Palette.surfaceSunken, ink: Palette.textPrimary)

        guard case .terminal = tab, usesGhosttyTheme else { return panel }

        let appearance = NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua)
        guard let appearance,
              let theme = TerminalGhostty.theme(for: appearance),
              let background = theme.background,
              let foreground = theme.foreground
        else { return panel }

        return (Color(nsColor: NSColor(background)), Color(nsColor: NSColor(foreground)))
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
                TerminalSplitView(
                    ownerID: tab.id,
                    workspace: model.workspace,
                    repo: model.repo,
                    port: model.port,
                    onCloseTab: { Task { await close(tab) } }
                )
                .id(tab.id)
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
    /// The colour of the pane this tab opens. See `BottomPanelView.surface(of:)`.
    var fill: Color

    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, Metrics.inset)
            .frame(height: Metrics.barHeight)
            .background(isSelected ? fill : (isHovered ? Palette.hover : .clear))
            .contentShape(Rectangle())
            .onHover { isHovered = $0 }
    }
}

private extension View {
    func tabChrome(isSelected: Bool, fill: Color) -> some View {
        modifier(BottomTabChrome(isSelected: isSelected, fill: fill))
    }
}
