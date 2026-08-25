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
    static func open(_ url: URL, in model: WorkspaceModel) {
        guard canOpen(url) else { return }
        let address = url.absoluteString
        let tabs = CenterTabStore.shared

        let existing = tabs.tabs(for: model.workspace.id).last { $0.kind == .browser }
        let tab: CenterTab
        if let existing {
            tabs.setURL(address, for: existing)
            tabs.browser(for: existing).load(address)
            tab = existing
        } else {
            tab = tabs.add(kind: .browser, workspaceID: model.workspace.id, url: address)
        }

        WorkspaceTabsStore.shared.reveal(.tool(tab.id), in: model)
    }
}
