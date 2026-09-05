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

    /// How big the pane is, read by the two drop closures below and by nothing that is drawn.
    ///
    /// In a box rather than in `@State` for the reason `GeometryBox` sets out: the probe writes
    /// this on every frame of a window or divider drag, and as `@State` every one of those frames
    /// invalidated this body, and with it whichever transcript, terminal or page the pane is
    /// holding, to store a number the body never reads.
    @State private var size = GeometryBox(CGSize.zero)
    @State private var isTargeted = false
    /// Which part of this pane a tab being dragged is currently over, which is the part it would
    /// land in. Nil when no drag is over the pane at all.
    ///
    /// `isTargeted` alone cannot draw this. It says in or out and nothing else, so the highlight it
    /// used to drive was the whole pane whichever quarter the pointer was in, which says "something
    /// will happen here" and not "this is where it goes". `onDropSessionUpdated` carries the live
    /// location, in the same top left origin space as the point the drop itself arrives with:
    /// measured side by side against a hand built `NSDraggingInfo`, an AppKit point ten up from the
    /// bottom of a sixty point view reaches both of them as fifty down from the top, so the wash
    /// and the drop cannot disagree about which edge was meant.
    @State private var landing: PaneRegion?

    private var tabs: WorkspaceTabsStore { .shared }

    /// What this pane is showing, or nothing when there is no tab for it to belong to.
    private var showing: PaneContent? {
        tab.map { tabs.content(of: pane, in: $0) }
    }

    /// What every pane of this tab is showing, this one included, and empty when there is no tab
    /// to be in. A tab nobody has split is one entry.
    ///
    /// Only the review reads it, to decide whether the conversation it would send to is already on
    /// screen and therefore whether it draws a composer of its own. See `ReviewComposer`. It costs
    /// no dependency this body did not already have: `showing` reads the same arrangement.
    private var paneContents: [PaneContent] {
        guard let tab else { return [] }
        return tabs.layout(of: tab).panes.map { tabs.content(of: $0, in: tab) }
    }

    /// Nil whenever the pane has something to draw, which is the ordinary case and the one this
    /// must be cheap in.
    ///
    /// **A transcript that exists and is still reading is deliberately not here, and that is a fix
    /// rather than a tidying.** This is drawn as an overlay on the whole pane, and a pane drawing
    /// a conversation is a transcript with a composer under it, so the wait was centred in the two
    /// together: it sat half the composer's height below the middle of the transcript, which with
    /// the divider dragged out to 348 points put it 174 points low and a couple of inches off the
    /// bottom rule. Worse, it moved every time that divider did. `ChatPaneView` draws that one
    /// over its own transcript now, which is where the missing content is. What is left here is a
    /// pane with nothing in it at all, and the whole pane is exactly what that wait is about.
    ///
    /// `existingTranscript` is a plain dictionary lookup and `isLoaded` is not read here at all
    /// any more, so a pane that is drawing a conversation depends on nothing that moves.
    private var waiting: PaneWait? {
        switch showing {
        case .chat(let sessionID):
            // The transcript exists, so the pane has a composer to draw and the wait belongs to
            // the transcript rather than to the pane. See `ChatPaneView.waiting`.
            //
            // Handing one wait to the other costs nothing that can be seen: `prepare` builds the
            // transcript on the next turn of the run loop, which is well inside the half second
            // either of them stays quiet for, so only one of the two is ever drawn.
            if model.existingTranscript(for: sessionID) != nil { return nil }
            if model.sessions.contains(where: { $0.id == sessionID }) {
                return .conversation(sessionID)
            }
            // A pane restored from a saved arrangement can name a session before the store has
            // said whether it still exists. Unknown and not-asked-yet are different answers, and
            // only the second of them is a wait.
            return model.hasReadSessions ? nil : .sessions(model.workspace.id)
        case .tool:
            // A terminal says so for itself while its shell starts, and a browser draws the page's
            // own progress. Neither is this pane's wait to announce.
            return nil
        case nil:
            // A workspace still running its setup script has a sentence of its own that says more
            // than a spinner would, so it is not a wait either.
            guard !model.isRunningSetup, !model.hasReadSessions else { return nil }
            return .sessions(model.workspace.id)
        }
    }

    var body: some View {
        content
            // Over the content rather than in place of it, so the pane that is being built keeps
            // its background, its size and its place in the hierarchy while the wait is drawn.
            // Nothing to hit: it is a readout, and the pane underneath still takes clicks.
            //
            // The whole pane is the right frame for the waits that are left here, because every
            // one of them is a pane with nothing in it: `waitingSurface` fills it edge to edge and
            // has no composer of its own. A conversation being read is not one of them any more.
            .overlay {
                SlowLoadingView(subject: waiting, label: waiting?.label)
                    .allowsHitTesting(false)
            }
            .onGeometryChange(for: CGSize.self) { $0.size } action: { size.value = $0 }
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
                case .entering, .active: landing = PaneRegion.at(session.location, in: size.value)
                default: landing = nil
                }
            }
            .overlay { dropHighlight }
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
        // The first thing a tab switch rebuilds, and therefore the start of everything `TabProbe`
        // is timing. Off unless a probe run turned the trace on, and stamped once per timeline.
        let _ = SwitchTrace.mark("pane.body", workspace: model.workspace.id)
        let _ = SwitchTrace.markOnScreen("pane.body", workspace: model.workspace.id)

        switch showing {
        case .chat(let sessionID):
            // The lookup only, never `transcript(for:)`: building one writes observed state, and a
            // body may not do that. `prepare` below is where it is built.
            if let transcript = model.existingTranscript(for: sessionID) {
                ChatPaneView(transcript: transcript, model: model, pane: pane)
            } else if model.sessions.contains(where: { $0.id == sessionID }) {
                // Nothing, rather than the `LoadingView` that used to be here. This branch is the
                // gap between a session being known and its transcript being built, which is one
                // turn of the run loop on almost every switch: a spinner drawn for it flickered.
                // The wait is `waiting` above, and it is only drawn if it lasts.
                waitingSurface
            } else if !model.hasReadSessions {
                // Same rule as the `nil` case below: a session this pane was restored pointing at
                // is not missing until the store has been asked.
                waitingSurface
            } else {
                emptyState
            }

        case .tool(let tabID):
            if let tab = CenterTabStore.shared.tabs(for: model.workspace.id)
                .first(where: { $0.id == tabID }) {
                ToolPaneView(
                    model: model, tab: tab,
                    siblings: paneContents,
                    splitColumn: { split($0, opening: $1) },
                    paneMenu: hostedMenu
                )
            } else {
                emptyState
            }

        case nil:
            if model.isRunningSetup {
                setupState
            } else if !model.hasReadSessions {
                // **Not `noConversationState`, and this is the bug that made a switch feel wrong
                // rather than merely slow.** On the first visit of a launch the sessions have not
                // been read yet, so `sessions.isEmpty` was true and the pane confidently said
                // "This workspace has no conversation" about a workspace full of them, for as
                // long as the store took to answer. An empty list is not an answer until somebody
                // has asked. See `WorkspaceModel.hasReadSessions`.
                waitingSurface
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
                let frame = landing.frame(in: CGRect(origin: .zero, size: proxy.size))
                Rectangle()
                    .fill(Palette.accent.opacity(0.12))
                    .frame(width: frame.width, height: frame.height)
                    .offset(x: frame.minX, y: frame.minY)
            }
            .allowsHitTesting(false)
        }
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

    /// A tab let go over this pane: the middle shows it here, an edge opens it beside this pane on
    /// that side.
    ///
    /// Only a tab. A PANE is moved by a gesture on the divider rather than by a drop, and that is
    /// not a preference: `.dropDestination` installs an `NSView` drawn BEHIND the content it is
    /// applied to, and a `WKWebView` registers seventeen dragged types of its own and sits on top
    /// of it, so AppKit offers a drag over a browser pane to the page and never to us. See
    /// `CenterPaneDivider`, which is where that measurement is written down. The same fault means
    /// a TAB cannot be dropped on a browser pane either, which is older than any of this and is
    /// not fixed here.
    private func accept(_ droppedID: String?, at location: CGPoint) -> Bool {
        guard let tab, let droppedID, let dropped = droppedTab(named: droppedID) else { return false }
        // A tab that carries a split arrangement of its own cannot be folded into this one:
        // grafting one tree into another is an operation `SplitLayout` does not have. See
        // `WorkspaceTabsStore.canAbsorb`.
        guard tabs.canAbsorb(dropped) else { return false }

        guard let placement = PaneRegion.at(location, in: size.value).placement else {
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

    // MARK: - Empty states

    /// What a pane that has nothing to draw yet shows: the colour it is about to be, and no words.
    ///
    /// `Palette.windowBackground` because that is what `ChatPaneView` paints itself, so the
    /// conversation arriving changes what is in the pane and not the colour behind it. A sentence
    /// here would be a sentence that is wrong a beat later, which is what `noConversationState`
    /// was doing on the first visit of every launch.
    private var waitingSurface: some View {
        Palette.windowBackground
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

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
        VStack(spacing: Metrics.spacingWide) {
            EmptyStateView(
                glyph: "apple.terminal",
                title: "Nothing open in this pane",
                message: "Open one of these in the worktree."
            )

            // **All three, rather than one and a sentence pointing at the `+`.** It used to offer
            // a terminal and tell the reader that the other kinds were "one click up, in the plus
            // above", which is a screen explaining where its own controls are. The three kinds are
            // three buttons; the `+` is still there for the fourth thing and for a second tab.
            //
            // The nouns and the glyphs are `PaneKind`'s, the same ones the `+` menu and the split
            // menus take theirs from, so this cannot end up calling a browser something else.
            HStack(spacing: Metrics.spacing) {
                ForEach(PaneKind.allCases) { kind in
                    Button {
                        NewPane.open(kind, in: model) { tabs.reveal($0, in: model) }
                    } label: {
                        Label(kind.title, systemImage: kind.symbol)
                            .labelStyle(.titleAndIcon)
                    }
                    // Terminal is the prominent one because this pane exists for a workspace that
                    // opened with a terminal and whose shell has ended, so it is what the reader
                    // most likely wants back. It carries the system control accent, like every
                    // primary action in the app.
                    .buttonStyle(.borderedProminent)
                    .tint(kind == .terminal ? Palette.controlAccent : Palette.surfaceRaised)
                    .foregroundStyle(kind == .terminal ? Palette.selectedEmphasizedText : Palette.textPrimary)
                }
            }
        }
    }

    private func openTerminal() {
        NewPane.open(.terminal, in: model) { tabs.reveal($0, in: model) }
    }
}
