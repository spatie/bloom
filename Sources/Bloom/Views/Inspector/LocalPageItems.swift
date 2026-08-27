import SwiftUI
import BloomCore

/// The browser openings a file row offers, which for most files is nothing at all.
///
/// Its own view rather than three items written into both trees, for the reason `OpenInItems`
/// beside it is one: the changed file list and the worktree tree draw the same menu on a file, and
/// the rule about which files this appears for is only one rule while there is one place drawing
/// it.
///
/// **The words are `TranscriptLinkMenu`'s.** A link right clicked in the transcript already offers
/// exactly these three, `TabItemView` offers the last two on a tab, and a third vocabulary for the
/// same two directions is what `PaneSplitTool` says it is avoiding. What is new here is only the
/// thing being opened: a page out of the worktree rather than an address a server is behind.
///
/// No glyphs on any of them. The neighbours in this menu, `Reveal in Finder`, `Copy path` and
/// `Open Terminal Tab Here`, carry none, and three marked items in a menu of plain ones read as a
/// group that has been pasted in.
struct LocalPageItems: View {
    /// Where the file is on disk, which is what `LocalPage` is asked about.
    var path: String
    /// The workspace's browser tab, pointed here. See `BrowserTab.openFile`.
    var open: @MainActor () -> Void
    /// A fresh browser in the half a split opens. See `BrowserTab.splitFile`.
    var split: @MainActor (SplitAxis) -> Void

    var body: some View {
        // Asked at the right click rather than when the row was built, which is what `FileTreeRow`
        // already does with `FolderTerminal.canOpen` a line below. It costs a `stat` per menu, and
        // it is what takes the item away with a file the agent deleted since the list was drawn:
        // a row in the changed list is a name out of a diff and need not have any bytes behind it.
        if LocalPage.canOpen(file: path) {
            Button("Open in Browser Tab", action: open)
            Button("Open in Split Right") { split(.horizontal) }
            Button("Open in Split Down") { split(.vertical) }
        }
    }
}
