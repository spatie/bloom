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
    /// Whether the pointer is resting on the grip that would pick this pane up. See
    /// `PaneGrabHandle`: the grip is seven points across and what it is about is half the column,
    /// so the pane is where that gets said.
    var isOffered = false

    @State private var size: CGSize = .zero
    @State private var isTargeted = false
    /// Which part of this pane a drag in flight is currently over, which is the part it would land
    /// in. Nil when no drag is over the pane at all.
    ///
    /// `isTargeted` alone cannot draw this. It says in or out and nothing else, so the highlight it
    /// used to drive was the whole pane whichever quarter the pointer was in, which says "something
    /// will happen here" and not "this is where it goes". `onDropSessionUpdated` carries the live
    /// location, in the same top left origin space as the point the drop itself arrives with:
    /// measured side by side against a hand built `NSDraggingInfo`, an AppKit point ten up from the
    /// bottom of a sixty point view reaches both of them as fifty down from the top, so the wash
    /// and the drop cannot disagree about which edge was meant.
    @State private var landing: Edge?

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
                if !$0 { landing = nil }
            }
            .onDropSessionUpdated { session in
                switch session.phase {
                case .entering, .active: landing = edge(at: session.location)
                default: landing = nil
                }
            }
            .overlay { dropHighlight }
            // The pane a grip would pick up, said on the pane rather than on the grip.
            .overlay { if isOffered { offeredHighlight } }
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

    /// The part of the pane a drag would land in, washed while the drag is over it.
    ///
    /// A `GeometryReader` rather than `size`, because this has to be right on the frame the pointer
    /// crosses into the pane and `size` is written by a layout pass that may not have happened yet.
    @ViewBuilder
    private var dropHighlight: some View {
        if isTargeted, let landing {
            GeometryReader { proxy in
                Rectangle()
                    .fill(Palette.accent.opacity(0.12))
                    .frame(
                        width: landing.width(of: proxy.size, share: Self.edgeShare),
                        height: landing.height(of: proxy.size, share: Self.edgeShare)
                    )
                    .offset(landing.offset(in: proxy.size, share: Self.edgeShare))
            }
            .allowsHitTesting(false)
        }
    }

    /// Fainter than the drop wash and in the same colour, because it is the same sentence said
    /// earlier: this pane is what the gesture is about. A grip is hovered before a drag, and a
    /// region is washed during one, so the two are never on screen at once.
    private var offeredHighlight: some View {
        Rectangle()
            .fill(Palette.accent.opacity(0.06))
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

    /// Something let go over this pane, which is one of two things.
    ///
    /// A TAB from the strip is content arriving: the middle shows it here, an edge opens it beside
    /// this pane on that side. A PANE of the tab already in front is the arrangement being changed:
    /// nothing arrives and nothing leaves, the same pane id ends up somewhere else in the tree, and
    /// so the shell or the page it was showing carries on running untouched.
    ///
    /// The two are told apart by the payload rather than by the id, because the id cannot tell
    /// them apart: an unsplit tab's only pane carries the id of the content at its root, and
    /// splitting that tab leaves the pane carrying it, so one string is legitimately both. See
    /// `PaneDrop`.
    ///
    /// Both read the same five regions, and deliberately: a user who has learned where to let a
    /// tab go has learned where to let a pane go. The middle is the one place they differ, and only
    /// because they must. A tab let go there replaces what the pane was showing, which is free
    /// because the thing replaced is still a tab of its own; a pane cannot be replaced that way,
    /// since the pane already there is a running shell or a loaded page and nothing about a drag
    /// says to end one. So the two exchange places instead.
    private func accept(_ droppedID: String?, at location: CGPoint) -> Bool {
        guard let tab, let droppedID else { return false }

        switch PaneDrop(encoded: droppedID) {
        case .pane(let moved): return move(moved, to: edge(at: location), in: tab)
        case .tab(let id): return show(id, at: edge(at: location), in: tab)
        }
    }

    /// A pane of this tab, put somewhere else in this tab.
    ///
    /// Only a pane of the tab in front, and there is no other tree on screen for one to have come
    /// from. A pane dropped anywhere else, the strip included, names nothing that anything there
    /// holds and is declined rather than half handled: moving a pane into another tab would mean
    /// grafting it into a second tree and taking it out of the first, which is a different
    /// operation and not this one.
    private func move(_ moved: String, to edge: Edge, in tab: PaneContent) -> Bool {
        guard tabs.layout(of: tab).contains(moved) else { return false }

        guard let placement = edge.placement else {
            return tabs.exchange(pane: moved, with: pane, in: tab, of: model)
        }
        return tabs.move(
            pane: moved, beside: pane,
            axis: placement.axis, before: placement.before,
            in: tab, of: model
        )
    }

    /// A tab from the strip, shown here or opened beside this pane.
    private func show(_ id: String, at edge: Edge, in tab: PaneContent) -> Bool {
        guard let dropped = droppedTab(named: id) else { return false }
        // A tab that carries a split arrangement of its own cannot be folded into this one:
        // grafting one tree into another is an operation `SplitLayout` does not have. See
        // `WorkspaceTabsStore.canAbsorb`.
        guard tabs.canAbsorb(dropped) else { return false }

        guard let placement = edge.placement else {
            tabs.replace(pane: pane, of: tab, with: dropped, in: model)
            return true
        }
        // A split always opens the new pane after the old one, so landing on the leading side is
        // the same split with the two contents the other way round. One call rather than a split
        // followed by an overwrite, so a tool is never momentarily in two panes at once.
        tabs.split(
            tab: tab, pane: pane,
            axis: placement.axis, showing: dropped, before: placement.before
        )
        return true
    }

    /// What a dragged id names in this workspace. Anything else let go over a pane, a line of text
    /// out of another app included, names nothing and the drop is refused.
    ///
    /// Not called `content`, which is the name of the pane's own body a few lines up. A `var` and a
    /// `func` may share a base name, and these two did, which reads as one thing with two forms
    /// where they are two unrelated questions.
    private func droppedTab(named id: String) -> PaneContent? {
        if model.sessions.contains(where: { $0.id.rawValue == id }) { return .chat(SessionID(id)) }
        if CenterTabStore.shared.tabs(for: model.workspace.id).contains(where: { $0.id == id }) {
            return .tool(id)
        }
        return nil
    }

    /// Which of the five regions of a pane a point is in.
    ///
    /// One vocabulary for both kinds of drop, and one place the geometry of it is written down, so
    /// the wash drawn while a drag is in flight cannot describe a different region from the one the
    /// drop then uses.
    private enum Edge {
        case none, leading, trailing, top, bottom

        /// Where the thing being dropped goes, or nil for the middle, which is not a placement at
        /// all: it is a replacement for a tab and an exchange for a pane.
        var placement: (axis: SplitAxis, before: Bool)? {
            switch self {
            case .none: nil
            case .leading: (.horizontal, true)
            case .trailing: (.horizontal, false)
            case .top: (.vertical, true)
            case .bottom: (.vertical, false)
            }
        }

        func width(of size: CGSize, share: CGFloat) -> CGFloat {
            switch self {
            case .leading, .trailing: size.width * share
            case .none, .top, .bottom: size.width
            }
        }

        func height(of size: CGSize, share: CGFloat) -> CGFloat {
            switch self {
            case .top, .bottom: size.height * share
            case .none, .leading, .trailing: size.height
            }
        }

        /// From the pane's top leading corner, which is where a `GeometryReader` puts what it holds.
        func offset(in size: CGSize, share: CGFloat) -> CGSize {
            switch self {
            case .none, .leading, .top: .zero
            case .trailing: CGSize(width: size.width * (1 - share), height: 0)
            case .bottom: CGSize(width: 0, height: size.height * (1 - share))
            }
        }
    }

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
