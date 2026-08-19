import SwiftUI
import BloomCore

/// One pane of the centre column: whichever tab it is pointing at, and the ways to change that.
///
/// A pane is a place to put a tab rather than a kind of view, so this is mostly a switch. What is
/// its own is the dropping: a tab dragged from the strip lands here, and where in the pane it is
/// let go decides whether it replaces what is showing or opens beside it. That is the whole
/// interaction, and it is the same one every editor on this platform uses.
struct CenterPaneView: View {
    @Bindable var model: WorkspaceModel
    var pane: String
    var isFocused: Bool
    /// Whether the column is split at all. A single pane has no neighbour to be told apart from
    /// and nothing to close back to, so it wears none of the chrome below.
    var isSplit: Bool

    @State private var size: CGSize = .zero
    @State private var isTargeted = false

    private var panes: CenterPaneStore { .shared }

    /// How much of the pane, on each side, counts as "open it beside this one" rather than "show it
    /// here". A quarter: wide enough to hit without aiming, narrow enough that the middle is still
    /// most of the pane.
    private static let edgeShare: CGFloat = 0.25

    var body: some View {
        content
            .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
            // Simultaneous rather than a plain tap: the transcript, the composer and the terminal
            // all want their own clicks, and this only needs to know that one happened.
            .simultaneousGesture(
                TapGesture().onEnded { panes.focus(pane, in: model.workspace.id) }
            )
            .dropDestination(for: String.self) { items, location in
                accept(items.first, at: location)
            } isTargeted: {
                isTargeted = $0
            }
            .overlay { if isTargeted { dropHighlight } }
            .overlay(alignment: .top) { if isSplit && isFocused { focusEdge } }
            .contextMenu { menu }
            .task(id: panes.content(of: pane, in: model)) { prepare() }
    }

    /// A pane can be pointed at any session, including one this launch has never opened, so the
    /// transcript it needs is built here rather than by whatever made the session active.
    private func prepare() {
        guard case .chat(let sessionID)? = panes.content(of: pane, in: model) else { return }
        model.prepareTranscript(for: sessionID)
    }

    @ViewBuilder
    private var content: some View {
        switch panes.content(of: pane, in: model) {
        case .chat(let sessionID):
            // The lookup only, never `transcript(for:)`: building one writes observed state, and a
            // body may not do that. `prepare` below is where it is built.
            if let transcript = model.existingTranscript(for: sessionID) {
                ChatPaneView(transcript: transcript, model: model)
            } else if model.sessions.contains(where: { $0.id == sessionID }) {
                LoadingView()
            } else {
                emptyState
            }

        case .tool(let tabID):
            if let tab = CenterTabStore.shared.tabs(for: model.workspace.id)
                .first(where: { $0.id == tabID }) {
                ToolPaneView(model: model, tab: tab)
            } else {
                emptyState
            }

        case nil:
            if model.isRunningSetup {
                setupState
            } else if model.sessions.isEmpty {
                noConversationState
            } else {
                emptyState
            }
        }
    }

    /// Which pane a click on a tab will fill. Only drawn while the column is split, because with
    /// one pane the answer is never in doubt.
    private var focusEdge: some View {
        Rectangle()
            .fill(Palette.accent)
            .frame(height: 2)
            .allowsHitTesting(false)
    }

    private var dropHighlight: some View {
        Rectangle()
            .fill(Palette.accent.opacity(0.12))
            .allowsHitTesting(false)
    }

    @ViewBuilder
    private var menu: some View {
        Button("Split Right", systemImage: PaneSymbol.splitRight) { split(.horizontal) }
        Button("Split Down", systemImage: PaneSymbol.splitDown) { split(.vertical) }
        if isSplit {
            Divider()
            Button("Close Pane", systemImage: PaneSymbol.closePane) {
                _ = panes.close(pane: pane, in: model.workspace.id)
            }
        }
    }

    // MARK: - Actions

    /// Opens a second pane showing the same tab, which is what splitting means everywhere else:
    /// the same thing twice, and then you change one of them.
    private func split(_ axis: SplitAxis) {
        panes.split(
            model.workspace.id,
            pane: pane,
            axis: axis,
            showing: panes.content(of: pane, in: model)
        )
    }

    /// A tab let go over this pane. The middle replaces what is showing, an edge opens the tab
    /// beside it on that side.
    private func accept(_ droppedID: String?, at location: CGPoint) -> Bool {
        guard let droppedID, let dropped = content(forTab: droppedID) else { return false }
        let workspaceID = model.workspace.id

        switch edge(at: location) {
        case .none:
            panes.show(dropped, in: pane, of: workspaceID)

        case .trailing:
            panes.split(workspaceID, pane: pane, axis: .horizontal, showing: dropped)

        case .bottom:
            panes.split(workspaceID, pane: pane, axis: .vertical, showing: dropped)

        // A split always opens the new pane after the old one, so landing on the leading side is
        // the same split with the two contents the other way round.
        case .leading, .top:
            let current = panes.content(of: pane, in: model)
            let axis: SplitAxis = edge(at: location) == .leading ? .horizontal : .vertical
            panes.split(workspaceID, pane: pane, axis: axis, showing: current)
            panes.show(dropped, in: pane, of: workspaceID)
        }
        return true
    }

    /// What the dragged id names. Anything else dropped on a pane, including text from another
    /// app, names nothing and the drop is refused.
    private func content(forTab id: String) -> CenterPaneContent? {
        if model.sessions.contains(where: { $0.id == id }) { return .chat(id) }
        if CenterTabStore.shared.tabs(for: model.workspace.id).contains(where: { $0.id == id }) {
            return .tool(id)
        }
        return nil
    }

    private enum Edge { case none, leading, trailing, top, bottom }

    private func edge(at location: CGPoint) -> Edge {
        guard size.width > 0, size.height > 0 else { return .none }
        let horizontal = size.width * Self.edgeShare
        let vertical = size.height * Self.edgeShare

        if location.x < horizontal { return .leading }
        if location.x > size.width - horizontal { return .trailing }
        if location.y < vertical { return .top }
        if location.y > size.height - vertical { return .bottom }
        return .none
    }

    // MARK: - Empty states

    /// A fresh workspace runs its setup script before anything else, and that can take minutes on a
    /// large repository. Saying so beats an empty rectangle that looks like a failure.
    private var setupState: some View {
        EmptyStateView(
            glyph: "gearshape.2",
            title: "Setting up the workspace",
            message: "The setup script is still running. The first session opens as soon as it finishes."
        )
        .background(Palette.surface)
    }

    /// Sessions are loaded asynchronously, so there is a moment with none, and archiving the last
    /// one leaves the workspace here for good.
    private var emptyState: some View {
        EmptyStateView(
            glyph: "bubble.left.and.bubble.right",
            title: "No session in this pane",
            message: "Sessions share the worktree but not the conversation, so a new one starts with a clean context.",
            actionTitle: "Start a session",
            action: { Task { await model.createSession() } }
        )
    }

    /// What a workspace that has no conversation at all falls back to.
    ///
    /// That is what "Opens with: Terminal" creates, and it is where its terminal tab lands when
    /// the shell in it ends: the tab closes like any other, and the pane behind it must not be a
    /// composer. Somebody who asked for a shell in this worktree is offered a shell in it. The
    /// other three kinds of tab are one click up, in the `+` the strip carries.
    private var noConversationState: some View {
        EmptyStateView(
            glyph: "apple.terminal",
            title: "Nothing open in this pane",
            message: "This workspace has no conversation. Open a terminal in the worktree, or pick another kind of tab from the plus above.",
            actionTitle: "Open a terminal",
            action: openTerminal
        )
    }

    private func openTerminal() {
        let tab = CenterTabStore.shared.add(kind: .terminal, workspaceID: model.workspace.id)
        panes.show(.tool(tab.id), in: model)
    }
}
