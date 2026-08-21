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
    /// A `WKWebView` speaks http and https. A `mailto:` is a perfectly good link for a plain
    /// click and is not something to open a blank tab onto, so the menu item that would do that
    /// is absent rather than present and useless. `BrowserSession.address` is asked the rest,
    /// because it is what will actually be handed the string a moment later, and two rules about
    /// what counts as an address would eventually disagree.
    static func canOpen(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return false
        }
        return BrowserSession.address(from: url.absoluteString) != nil
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
