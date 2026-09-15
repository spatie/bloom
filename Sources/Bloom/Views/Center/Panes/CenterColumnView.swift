import SwiftUI
import BloomCore

/// The centre column: the workspace's tabs, and the panes they are shown in.
///
/// One view for every kind of tab, where there used to be two that each drew their own copy of the
/// strip and swapped places as the selection changed. That swap is what made every hop between a
/// conversation and a terminal rebuild the column and re-run the workspace's arrival work, and it
/// is also what made a chat and a terminal mutually exclusive. A pane holds a tab, so now they are
/// not.
struct CenterColumnView: View {
    @Bindable var model: WorkspaceModel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The tab whose name field is open in the strip. Here rather than in `SessionTabsView`
    /// because opening one is also a reason to draw the strip. See `TabStripVisibility`.
    @State private var renamingID: String?
    /// A tab being carried out of the strip. Here because two regions draw one drag: the strip
    /// slides its tabs, and the column washes the pane the tab would land in. See `TabCarry`.
    @State private var carry = TabCarry()
    /// Where the panes sit in `space`, read only when a carried tab asks which pane it is over.
    /// A box for the reason `GeometryBox` gives: nothing draws it.
    @State private var panesFrame = GeometryBox(CGRect.zero)

    /// The space a carried tab's pointer is reported in and its landing is washed in. The column
    /// rather than the window, because the strip, the panes and the overlay that washes them are
    /// all inside it, so the three can share one set of numbers.
    nonisolated static let space = "bloom.centreColumn"

    private var store: WorkspaceTabsStore { .shared }

    /// Whether the strip is drawn, which is Safari's rule. The reasoning, including why a split
    /// tab no longer keeps the strip up, is `TabStripVisibility`'s.
    private func isStripShown(entries: [PaneContent]) -> Bool {
        TabStripVisibility.isShown(tabCount: entries.count, isRenaming: renamingID != nil)
    }

    var body: some View {
        let entries = store.entries(in: model)
        let selected = store.selectedTab(in: model, entries: entries)
        let isStripShown = isStripShown(entries: entries)
        // One answer for the column's top edge and for every tab. See `BusySignalPlacement`.
        let busy = store.busySignal(
            in: model, entries: entries, selected: selected, isStripShown: isStripShown
        )
        VStack(spacing: 0) {
            if isStripShown {
                SessionTabsView(
                    model: model,
                    renamingID: $renamingID,
                    carry: carry,
                    busy: busy,
                    landing: { landing(for: $0, at: $1) },
                    drop: { place($0, at: $1) }
                )
                    // A fade rather than a slide. The strip sits hard under the title bar, and
                    // sliding it in from the top edge draws it over the title bar for the length
                    // of the animation; the panes below close or open the gap either way.
                    .transition(.opacity)
            }
            WorkspaceSettingsNotices(model: model)
            CenterPanesView(model: model)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.space)) } action: {
                    panesFrame.value = $0
                }
        }
        .coordinateSpace(.named(Self.space))
        // With no strip, a short segment slides along the top of the column, directly under the
        // title bar, with nothing drawn behind it. See `ColumnBusySignal`.
        //
        // `.identity` so it leaves at once when the strip arrives. The column animates the strip
        // in, and a default transition would fade this out over the same fifth of a second the
        // tab's own sweep fades in, which is both signals on screen at once.
        .overlay(alignment: .top) {
            if !isStripShown {
                ColumnBusySignal(isActive: busy.showsColumnTop).transition(.identity)
            }
        }
        // The title bar tells VoiceOver the one tab there is is running. The title is a toolbar
        // item and cannot see this column's strip, so the answer is published for it, under this
        // workspace's selection. Keyed on the id, so moving to another workspace clears this one's
        // claim before the next is made.
        .onChange(of: busy.showsColumnTop ? model.workspace.id : nil, initial: true) { was, now in
            if let was { WindowTitleText.shared.setBusy(false, for: .workspace(was)) }
            if let now { WindowTitleText.shared.setBusy(true, for: .workspace(now)) }
        }
        .onDisappear { WindowTitleText.shared.setBusy(false, for: .workspace(model.workspace.id)) }
        // Over the strip and the panes alike, and hit testing nothing, so the carried tab's wash
        // and ghost never take the release that lets it go.
        .overlay { TabCarryOverlay(carry: carry) }
        // On the column rather than on the strip, so the panes moving up into the space and the
        // strip fading out are one movement. Keyed on the answer alone: a tab being renamed or a
        // third tab arriving changes nothing here and must not animate the column. Only arriving
        // is animated: closing the second tab drops the strip at once, as Safari does, because
        // a strip fading out with a single tab left in it lingers on something already gone.
        .animation(reduceMotion || !isStripShown ? nil : Motion.pane, value: isStripShown)
        .background(Palette.windowBackground)
        // Rename Tab from the File menu. It renames the selected tab, which is the tab the menu
        // item was greyed against, and on a workspace with one tab that is a strip not drawn yet:
        // setting this is what draws it, with the field open.
        .onReceive(NotificationCenter.default.publisher(for: .bloomRenameTab)) { _ in
            guard let selected = store.selectedTab(in: model) else { return }
            // `PaneContent.id` is the same string the strip files an open field under, for both
            // kinds, which is what lets one notification carry no id of its own.
            renamingID = selected.id
        }
        // A field left open in one workspace is not one to carry into the next.
        .onChange(of: model.workspace.id) { _, _ in renamingID = nil }
        .task(id: model.workspace.id) {
            // The icons this Mac has already seen, read back once per launch. Here rather than at
            // startup because this is what needs them: a workspace reopening on a browser tab
            // should draw its icon on the first frame instead of asking the page for something
            // that is already on disk. Its own task, so it does not hold up the one below.
            await BrowserFaviconStore.shared.warm()
        }
        .task(id: model.workspace.id) {
            openStartingPane()
            await model.onAppear()
            // Last, and that ordering is the whole of it. `onAppear` does not return until the
            // first visit of a launch has the workspace's sessions in hand, and the tool tabs were
            // read back synchronously above, so this is the one place in the column where both
            // lists are answers rather than silence. Reconciling forgets every pane pointer
            // nothing accounts for, so it ran from the strip's own task and deleted the chat pane
            // of every terminal or browser tab somebody had split, on the first open after each
            // relaunch. `TabReconciliation` refuses an unread list as well, because an ordering
            // that is only correct by inspection is one edit away from being incorrect.
            WorkspaceTabsStore.shared.reconcile(in: model)
            // After the reconcile, because starting a run script may add a tab, and a tab added
            // before the strip has been squared with what is stored is one the reconcile judges.
            // Once per workspace per launch; see `RunScriptLauncher.considerAutostart`.
            await RunScriptLauncher.shared.considerAutostart(in: model)
        }
        // A settings file that changes while the workspace is open is settled again. Without
        // this, a file added to an open workspace never asked and never started anything until
        // the next launch. Unchanged autostart commands settle to nothing; see
        // `RunScriptAutostart.signature(of:)`.
        .onChange(of: model.settings.runScripts) { _, _ in
            Task { await RunScriptLauncher.shared.considerAutostart(in: model) }
        }
        // Settings are otherwise re-read only on a switch, so a file edited in another app, or
        // pulled from a terminal outside Bloom, did not reach the `+` menu, the notices or the quick
        // prompt panel of the workspace already on screen. Coming back to the window is the moment
        // somebody who just changed it expects to see the change. The read is off the main actor
        // and coalesced, so this costs a parse and nothing more.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshSettings()
        }
    }

    /// Which part of which pane a tab carried to `point` would land in, with the frame in `space`.
    ///
    /// The panes are laid out again from the selected tab's tree rather than each pane measuring
    /// itself, which is the same `SplitGeometry` `CenterPanesView` positions them with and so the
    /// same rectangles. That is what replaced a `.dropDestination` on every pane: a system drag no
    /// longer exists to be dropped, and one hit test in the column cannot disagree with itself
    /// about which pane is under the pointer. Nil over anywhere that would not take the tab, which
    /// is `canAbsorb`'s refusal of a tab with a split arrangement of its own, so no wash promises a
    /// drop that would be refused.
    private func landing(for content: PaneContent, at point: CGPoint) -> PaneLanding? {
        let frame = panesFrame.value
        guard frame.contains(point), let tab = store.selectedTab(in: model),
              store.canAbsorb(content) else { return nil }
        let geometry = store.layout(of: tab).geometry(
            in: frame.size, dividerThickness: CenterPanesView.dividerThickness
        )
        let local = CGPoint(x: point.x - frame.minX, y: point.y - frame.minY)
        guard var landing = geometry.landing(at: local) else { return nil }
        landing.frame = landing.frame.offsetBy(dx: frame.minX, dy: frame.minY)
        return landing
    }

    /// A carried tab let go over a pane: the middle shows it there, an edge opens it beside that
    /// pane on that side. The same two calls the pane's own drop made before the tab stopped being
    /// a system drag.
    private func place(_ content: PaneContent, at landing: PaneLanding) {
        guard let tab = store.selectedTab(in: model), store.canAbsorb(content) else { return }
        guard let placement = landing.region.placement else {
            return store.replace(pane: landing.pane, of: tab, with: content, in: model)
        }
        // A split always opens the new pane after the old one, so landing on the leading side is
        // the same split with the two contents the other way round. One call rather than a split
        // followed by an overwrite, so a tool is never momentarily in two panes at once.
        store.split(
            tab: tab, pane: landing.pane,
            axis: placement.axis, showing: content, before: placement.before
        )
    }

    /// Opens the tab a workspace created with "Start with: Terminal" or "Start with: Browser" was
    /// promised.
    ///
    /// This is the consumer `WorkspaceStartMode.consumeOpeningTab` never had. Creating a terminal
    /// workspace wrote the hint, skipped the session and the opening turn, and then nothing read
    /// the hint: the workspace opened on an empty conversation, which is not what the control said
    /// and not what anybody picking it wanted. The tab is opened here rather than at creation
    /// because a tab is a thing the centre column owns, and because the hint has to be consumed
    /// exactly once, on the first open, and never forced in front of an arrangement the user has
    /// since made for themselves.
    ///
    /// Through `NewPane`, which is the door the title bar's `+` and every split menu already use, so
    /// a tab a workspace is born on and a tab somebody opens a second later are the same tab.
    private func openStartingPane() {
        let workspaceID = model.workspace.id
        // Idempotent, and first: adding a tab to a workspace whose stored list has not been read
        // back yet would replace that list rather than extend it.
        CenterTabStore.shared.load(workspaceID: workspaceID)
        guard let opening = WorkspaceStartMode.consumeOpeningTab(workspaceID: workspaceID) else {
            return
        }
        // No address for a browser, where the title bar's `+` passes the workspace's own dev server.
        // The worktree was cut seconds ago and its setup script may still be running, so the port
        // is answering nothing: an opening tab on a refused connection would be an error page as
        // the first thing a new workspace shows. The address field is where somebody says.
        guard opening.cliAgentKind == nil else { return }
        NewPane.open(opening.pane, in: model) { WorkspaceTabsStore.shared.select($0, in: model) }
    }
}
