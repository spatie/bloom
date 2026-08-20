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
    /// The strip's namespace, so the selected tab's fill is one view that moves between tabs
    /// rather than one that is destroyed here and built again over there.
    @Namespace private var selection

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
        // divider, and a second hairline under it reads as a double rule. The rule BELOW the strip
        // is `TabStrip`'s own, painted behind the tabs so the selected one breaks it.
        VStack(spacing: 0) {
            tabStrip
            if app.isBottomPanelVisible {
                content
            }
        }
        .background(Palette.surfaceSunken)
        .task(id: "\(model.workspace.id)|\(model.repo?.path ?? "")") {
            await load()
        }
    }

    // MARK: - Tab strip

    /// The bottom panel opens onto the recessed ground rather than the reading one, which is what
    /// its ordinary tabs are filled with and what the track under them is measured against.
    private static let pane = TabPane.sunken

    private var tabStrip: some View {
        // Collapse first, then the tabs, then the one control that adds to them. The chevron leads
        // because it acts on the whole panel rather than on any tab, and it stays put as tabs come
        // and go, which a control at the end of a scrolling row does not. The `+` goes in `append`
        // rather than at the end of the strip, so it follows the last tab the way it does in the
        // centre column.
        TabStrip(pane: Self.pane) {
            iconButton(
                app.isBottomPanelVisible ? "chevron.down" : "chevron.up",
                help: app.isBottomPanelVisible ? "Collapse the panel" : "Expand the panel"
            ) {
                app.isBottomPanelVisible.toggle()
            }

            // The rule between the chevron and the tabs, and it answers to the tabs rather than to
            // the chevron: it is the rule BEFORE the first tab, so it goes exactly the way every
            // other rule in this strip goes. Hidden against the first tab when that tab is the
            // selected one, whose own fill is its edge, and hidden when the strip has no first tab
            // at all.
            //
            // The empty case is the one that was wrong. `append` already hides its own rule when
            // there is no tab for the `+` to come after, but that condition guards a different
            // rule: this one belongs to the slot before the tabs and knew nothing about them. With
            // nothing between the two, this rule ended up hard against the `+` and fenced off
            // nothing from nothing, which is what a panel whose terminals have not arrived yet
            // opens with.
            TabStripSeparator(isHidden: order.first.map(isSelected(before:)) ?? true)
        } tabs: {
            tabRow
        } append: {
            // Against the last tab rather than out at the end of the panel, and behind the same
            // rule the tabs have between each other, which hides against the selected one and
            // when the strip has no tab for it to come after.
            TabStripSeparator(isHidden: order.last.map { $0 == model.bottomTab } ?? true)

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
    }

    /// A rule between neighbours and never before the first tab, and never beside the selected one,
    /// whose fill is the edge instead. The same arrangement as the centre column's strip.
    private var tabRow: some View {
        let hasSetup = settings.setupScript != nil
        let hasScripts = !settings.runScripts.isEmpty

        return HStack(spacing: 0) {
            if hasSetup {
                tabButton(.setup, title: "Setup", icon: "wrench.and.screwdriver")
            }

            ForEach(Array(settings.runScripts.enumerated()), id: \.element.id) { index, script in
                if hasSetup || index > 0 {
                    TabStripSeparator(isHidden: isSelected(before: .run(script.id)))
                }
                tabButton(.run(script.id), title: script.name, icon: "play")
            }

            ForEach(Array(terminalTabs.enumerated()), id: \.element.id) { index, tab in
                if hasSetup || hasScripts || index > 0 {
                    TabStripSeparator(isHidden: isSelected(before: .terminal(tab.id)))
                }
                terminalTabButton(tab)
            }
        }
    }

    /// Every tab in the strip, in the order it is drawn, which is what the separators either side
    /// of a selection are worked out from.
    private var order: [BottomTab] {
        (settings.setupScript == nil ? [] : [BottomTab.setup])
            + settings.runScripts.map { BottomTab.run($0.id) }
            + terminalTabs.map { BottomTab.terminal($0.id) }
    }

    /// Whether the rule immediately before `tab` sits next to the selected tab, on either side of
    /// it. A selected tab's own fill is its edge, so a rule against it reads as a box.
    private func isSelected(before tab: BottomTab) -> Bool {
        guard let index = order.firstIndex(of: tab) else { return false }
        if model.bottomTab == tab { return true }
        return index > 0 && model.bottomTab == order[index - 1]
    }

    private func tabButton(_ tab: BottomTab, title: String, icon: String) -> some View {
        TabItemView(
            title: title,
            icon: icon,
            isActive: model.bottomTab == tab,
            surface: surface(of: tab),
            isRenaming: false,
            editableTitle: title,
            // A setup log and a run script are the repository's, not the panel's: they come and go
            // with `.conductor/settings.toml` and there is nothing here to close or to rename.
            canClose: false,
            canRename: false,
            closeTitle: title,
            onSelect: { select(tab) },
            onStartRename: {},
            onCommitRename: { _ in },
            onCancelRename: {},
            onClose: {},
            namespace: selection
        )
    }

    private func terminalTabButton(_ tab: TerminalTab) -> some View {
        TabItemView(
            title: tab.title,
            icon: "terminal",
            isActive: model.bottomTab == .terminal(tab.id),
            surface: surface(of: .terminal(tab.id)),
            isRenaming: renamingTabID == tab.id,
            editableTitle: tab.title,
            canClose: true,
            closeTitle: "Close this terminal",
            onSelect: { select(.terminal(tab.id)) },
            onStartRename: { renamingTabID = tab.id },
            onCommitRename: { commitRename(tab, to: $0) },
            onCancelRename: { renamingTabID = nil },
            onClose: { Task { await close(tab) } },
            namespace: selection
        )
    }

    /// The glyph carries neither a font nor a colour of its own: `.accessoryBar` is the system's
    /// style for a control in a strip like this, and it sizes and tints the glyph, and draws the
    /// hover and pressed states, the way every other bar on the Mac does. Setting a font and then
    /// an `.imageScale(.small)` on top of it shrank the mark twice over.
    ///
    /// The slot it is drawn in is `tabStripControl`, which is also what keeps the plate
    /// `.accessoryBar` draws off the rule beside it. Handed the whole slot as a frame, the plate
    /// filled it and both of this strip's controls came to rest hard against a rule: the chevron
    /// against the one before the first tab, the `+` against the one after the last. See
    /// `TabStripControlBox`.
    private func iconButton(_ symbol: String, help: String, run: @escaping () -> Void) -> some View {
        Button(help, systemImage: symbol, action: run)
            .labelStyle(.iconOnly)
            .buttonStyle(.accessoryBar)
            .tabStripControl()
            .help(help)
    }

    /// One surface for every tab in the strip, whatever the pane behind it draws.
    ///
    /// A terminal tab used to take its ground and ink from the user's Ghostty theme, so the tab
    /// matched the shell under it. It read as a coloured tab in a row of grey ones, which is a
    /// strip that cannot be scanned: the eye sorts the tabs by colour before it reads any of them,
    /// and the colour means nothing except which pane happens to be open.
    ///
    /// The seam that idea was solving is real (a grey tab directly above a themed shell shows the
    /// join) but it belongs to the pane rather than to the tab, and a tab strip whose members
    /// disagree about their own colour is the worse of the two problems.
    private func surface(of tab: BottomTab) -> TabSurface { Self.pane.surface }

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

    private func commitRename(_ tab: TerminalTab, to name: String) {
        renamingTabID = nil
        Task { await sessions.rename(tab, to: name, store: model.store) }
    }

    /// Closes a terminal tab, whether the user asked or its shell ended by itself.
    ///
    /// A tab that was not the selected one leaves the selection alone. The selected one hands over
    /// to its neighbour: the tab that slid into its place, or the new last one when it was at the
    /// end. Falling back to the first tab, which is what this did, sent the user to the other end
    /// of the strip whenever they closed the tab they were working in.
    private func close(_ tab: TerminalTab) async {
        let index = terminalTabs.firstIndex { $0.id == tab.id }
        let wasSelected = model.bottomTab == .terminal(tab.id)
        let remaining = await sessions.closeTab(tab, store: model.store)

        guard wasSelected, !remaining.isEmpty else { return }
        let next = remaining[min(index ?? 0, remaining.count - 1)]
        model.bottomTab = .terminal(next.id)
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
