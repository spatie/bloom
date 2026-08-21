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
    /// The tab this pane belongs to, and nil when the workspace has no tab to be in at all. A
    /// pane belongs to a tab now rather than to the workspace, which is what stops picking a tab
    /// from rewriting whatever pane the user happened to be standing in.
    var tab: PaneContent?
    var pane: String
    /// Whether the column is split at all. A single pane has nothing to close back to, so its
    /// menu does not offer it.
    var isSplit: Bool

    @State private var size: CGSize = .zero
    @State private var isTargeted = false

    private var tabs: WorkspaceTabsStore { .shared }

    /// What this pane is showing, or nothing when there is no tab for it to belong to.
    private var showing: PaneContent? {
        tab.map { tabs.content(of: pane, in: $0) }
    }

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
                TapGesture().onEnded {
                    guard let tab else { return }
                    tabs.focus(pane, in: tab, of: model)
                }
            )
            .dropDestination(for: String.self) { items, location in
                accept(items.first, at: location)
            } isTargeted: {
                isTargeted = $0
            }
            .overlay { if isTargeted { dropHighlight } }
            .contextMenu { menu }
            .task(id: showing) { prepare() }
    }

    /// A pane can be pointed at any session, including one this launch has never opened, so the
    /// transcript it needs is built here rather than by whatever made the session active.
    private func prepare() {
        guard case .chat(let sessionID)? = showing else { return }
        model.prepareTranscript(for: sessionID)
    }

    @ViewBuilder
    private var content: some View {
        switch showing {
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
                ToolPaneView(
                    model: model, tab: tab,
                    splitColumn: { split($0, opening: $1) },
                    paneMenu: hostedMenu
                )
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

    private var dropHighlight: some View {
        Rectangle()
            .fill(Palette.accent.opacity(0.12))
            .allowsHitTesting(false)
    }

    private var menu: CenterPaneMenu {
        CenterPaneMenu(
            isSplit: isSplit,
            split: { axis, kind in split(axis, opening: kind) },
            close: {
                guard let tab else { return }
                tabs.close(pane: pane, in: tab, of: model.workspace.id)
            }
        )
    }

    /// The same menu, as an `NSMenu`, for a pane whose content answers the right click itself.
    ///
    /// `.contextMenu` above is how every other pane gets this, and it only works when SwiftUI sees
    /// the event. A browser does not let it: the page is a `WKWebView` and builds a menu of its
    /// own. So the same view is rendered to an `NSMenu` here and handed down, rather than a second
    /// list of the same items being written somewhere a browser can reach. See
    /// `BrowserPageWebView`.
    ///
    /// Built on each right click and not held, because `isSplit` and what the pane is showing can
    /// both have changed since the last one.
    private func hostedMenu() -> NSMenu {
        NSHostingMenu(rootView: menu)
    }

    // MARK: - Actions

    /// Splits this pane and opens a new chat, terminal or browser in the half that opens.
    ///
    /// The pane and the tab are captured rather than looked up again, because the split lands
    /// after an await for a chat, and by then the user may have clicked into another pane or
    /// picked another tab.
    ///
    /// There is no longer a write of this pane's own content first. That guard was here because a
    /// pane nobody had given anything to fell back to the workspace's ACTIVE conversation, and
    /// creating a chat makes the new one active, so Split Right then Chat used to put the new
    /// session in BOTH halves. A pane falls back to its tab now, and a tab does not move when a
    /// session is created.
    private func split(_ axis: SplitAxis, opening kind: PaneKind) {
        guard let tab else { return }
        let pane = pane

        NewPane.open(kind, in: model) { content in
            WorkspaceTabsStore.shared.split(tab: tab, pane: pane, axis: axis, showing: content)
        }
    }

    /// A tab let go over this pane. The middle replaces what is showing, an edge opens the tab
    /// beside it on that side.
    private func accept(_ droppedID: String?, at location: CGPoint) -> Bool {
        guard let tab, let droppedID, let dropped = content(forTab: droppedID) else { return false }
        // A tab that carries a split arrangement of its own cannot be folded into this one:
        // grafting one tree into another is an operation `SplitLayout` does not have. See
        // `WorkspaceTabsStore.canAbsorb`.
        guard tabs.canAbsorb(dropped) else { return false }

        switch edge(at: location) {
        case .none:
            tabs.replace(pane: pane, of: tab, with: dropped, in: model)

        case .trailing:
            tabs.split(tab: tab, pane: pane, axis: .horizontal, showing: dropped)

        case .bottom:
            tabs.split(tab: tab, pane: pane, axis: .vertical, showing: dropped)

        // A split always opens the new pane after the old one, so landing on the leading side is
        // the same split with the two contents the other way round. One call rather than a split
        // followed by an overwrite, so a tool is never momentarily in two panes at once.
        case .leading, .top:
            let axis: SplitAxis = edge(at: location) == .leading ? .horizontal : .vertical
            tabs.split(tab: tab, pane: pane, axis: axis, showing: dropped, before: true)
        }
        return true
    }

    /// What the dragged id names. Anything else dropped on a pane, including text from another
    /// app, names nothing and the drop is refused.
    private func content(forTab id: String) -> PaneContent? {
        if model.sessions.contains(where: { $0.id.rawValue == id }) { return .chat(SessionID(id)) }
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
        NewPane.open(.terminal, in: model) { tabs.reveal($0, in: model) }
    }
}
