import SwiftUI
import BloomCore

/// The one way an address gets into Bloom's own browser.
///
/// `FileReview` next door is the same shape and exists for the same reason: a row in the
/// transcript should not have to know how the centre column is arranged in order to put something
/// in it, and every route to a browser tab should produce exactly the tab a browser tab normally
/// is. This goes through `CenterTabStore.add` and `WorkspaceTabsStore.reveal`, which is the door
/// the strip's own `+` menu uses.
@MainActor
enum BrowserTab {
    /// Whether the in-app browser could show this at all.
    ///
    /// The rule itself is `BrowserAddress.shows` in the core, because `TranscriptLinkMenu` asks it
    /// too and two rules about what counts as an address would eventually disagree. Named here as
    /// well so that the callers reading "can this be opened as a tab" keep the sentence they had.
    static func canOpen(_ url: URL) -> Bool {
        BrowserAddress.shows(url)
    }

    /// Which of `TranscriptLinkMenu`'s three placements a transcript is in.
    ///
    /// Here rather than in the transcript for the reason the rest of this type is: a row should not
    /// have to know how the centre column is arranged. `pane` is nil for a transcript the window
    /// cannot place, which is the archive sheet; it is checked against the layout of the tab in
    /// front rather than trusted, because a tab that has been closed or rearranged since the
    /// transcript was drawn leaves a pane id naming nothing, and `WorkspaceTabsStore.split` would
    /// then do nothing at all rather than say so.
    static func placement(of pane: String?, in model: WorkspaceModel?) -> TranscriptLinkPlacement {
        guard let model else { return .detached }
        guard let pane, let tab = WorkspaceTabsStore.shared.selectedTab(in: model),
              WorkspaceTabsStore.shared.layout(of: tab).contains(pane) else { return .column }
        return .pane
    }

    /// Splits the pane the transcript is in and opens the address in the half that opens.
    ///
    /// **A fresh browser rather than the workspace's existing one, which is the whole difference
    /// from `open` above.** A `WKWebView` is one live view, so moving the tab `open` reuses into a
    /// second pane would take the page away from wherever it already was;
    /// `WorkspaceTabsStore.Arrangement.canHold` refuses that outright, and `PaneSplit` calls the
    /// same answer `.freshBrowser` when a browser pane is split. It is also what the reader asked
    /// for: a split is for reading the page beside the conversation that named it, not for moving
    /// a tab they were already using.
    ///
    /// Through `NewPane.open`, which is the door `CenterPaneMenu` and `pane_split` both use, so a
    /// browser opened from a link is the browser a split normally opens.
    ///
    /// There is nothing else for the menu to have gated on. A fresh tab is in no pane yet, so
    /// `canHold` cannot refuse it, and `SplitLayout` sets no ceiling on how many panes a tab may
    /// hold. The one way this could do nothing is a pane id naming nothing, which is what
    /// `placement` above rules out before the items are offered and what the guard below repeats
    /// for the moment between the menu opening and an item being chosen.
    static func split(_ url: URL, in model: WorkspaceModel, pane: String, axis: SplitAxis) {
        guard canOpen(url) else { return }
        let tabs = WorkspaceTabsStore.shared
        guard let tab = tabs.selectedTab(in: model), tabs.layout(of: tab).contains(pane) else {
            return
        }
        NewPane.open(.browser, in: model, url: url.absoluteString) { content in
            tabs.split(tab: tab, pane: pane, axis: axis, showing: content)
        }
    }

    /// Opens an address in the workspace's browser tab, in front.
    ///
    /// **In front, because the reader asked for it by name.** Every other route into this column
    /// puts what you chose where you can see it, and a menu item that opened a page behind the
    /// conversation would read as having done nothing.
    ///
    /// **The workspace's existing browser tab is pointed at the address rather than a second one
    /// being added.** A transcript is full of links, and a tab per press would bury the
    /// conversations the strip is mostly for. It is the same argument `CenterTab` already makes
    /// for the review tab, and the way to a second browser is unchanged: the strip's `+` menu
    /// still adds one, and this reuses whichever browser tab is last in the strip.
    /// Opens the window a page asked for, as a browser tab of the workspace's, in front.
    ///
    /// **A new tab every time, which is the one place this disagrees with `open` below.** That one
    /// is a reader choosing an address out of a transcript, where a tab per link would bury the
    /// conversations the strip is mostly for. This is a page that has said the document it is
    /// showing should stay where it is, so pointing the workspace's existing browser at somewhere
    /// else would be the single outcome `target="_blank"` rules out.
    ///
    /// Through `CenterTabStore.add` and `WorkspaceTabsStore.reveal` like everything else in this
    /// type, so a window a page opened is exactly the tab a browser tab normally is: closable,
    /// nameable, splittable, and with the same address field over it. How many of these a page may
    /// have is `BrowserPopups`, which has already answered by the time this is called.
    static func openWindow(_ url: URL, in model: WorkspaceModel) {
        guard canOpen(url) else { return }
        let tab = CenterTabStore.shared.add(
            kind: .browser, workspaceID: model.workspace.id, url: url.absoluteString
        )
        WorkspaceTabsStore.shared.reveal(.tool(tab.id), in: model)
    }

    static func open(_ url: URL, in model: WorkspaceModel) {
        guard canOpen(url) else { return }
        show(url.absoluteString, in: model)
    }

    /// Opens a page out of the worktree in the workspace's browser tab, in front.
    ///
    /// **Its own door rather than `open` above being handed a file URL, and `LocalPage` rather
    /// than `BrowserAddress.shows`.** That rule refuses every `file://` there is and has to keep
    /// refusing them, because `openWindow` above asks it before a page's own `window.open` is
    /// honoured: widening it would let a page from the network name a path on this Mac and have
    /// Bloom open it. A reader right clicking a row of their own worktree is the one caller that
    /// has named a file itself, so it is the only one given this.
    ///
    /// The workspace's existing browser tab is reused, for the reason `open` reuses it: the
    /// changed file list is where somebody clicks a dozen times in a row, and a tab per press
    /// would bury the conversations the strip is mostly for.
    ///
    /// - Parameter path: absolute, which is what `ChangedFileRow.fullPath` already carries.
    static func openFile(_ path: String, in model: WorkspaceModel) {
        guard let address = LocalPage.address(forFile: path) else { return }
        show(address, in: model)
    }

    /// The same page in the half a split opens.
    ///
    /// A fresh browser rather than the tab `openFile` reuses, for the reason `split` above gives:
    /// a `WKWebView` is one live view, so a tab cannot be in two panes.
    ///
    /// The pane divided is the focused pane of the tab in front, which is the pane the strip's own
    /// Open in Split Right divides. Unlike `split` above there is no pane for the caller to name:
    /// a file row is drawn in the inspector rather than inside the column, so it has no pane of
    /// its own to be beside.
    static func splitFile(_ path: String, in model: WorkspaceModel, axis: SplitAxis) {
        guard let address = LocalPage.address(forFile: path) else { return }
        let tabs = WorkspaceTabsStore.shared
        guard let tab = tabs.selectedTab(in: model) else { return }
        let pane = tabs.focusedPane(of: tab)
        NewPane.open(.browser, in: model, url: address) { content in
            tabs.split(tab: tab, pane: pane, axis: axis, showing: content)
        }
    }

    /// The workspace's browser tab, pointed at `address` and brought forward. Shared by the two
    /// doors above so that a page and a link land in the same tab, which is what stops a worktree
    /// full of reports from opening a strip full of browsers.
    private static func show(_ address: String, in model: WorkspaceModel) {
        let tabs = CenterTabStore.shared
        let existing = tabs.tabs(for: model.workspace.id).last { $0.kind == .browser }
        let tab: CenterTab
        if let existing {
            tabs.setURL(address, for: existing)
            tabs.browser(for: existing, root: model.workspace.path).load(address)
            tab = existing
        } else {
            tab = tabs.add(kind: .browser, workspaceID: model.workspace.id, url: address)
        }

        WorkspaceTabsStore.shared.reveal(.tool(tab.id), in: model)
    }
}
