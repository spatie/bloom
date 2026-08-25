import Foundation

/// Where a link the reader chose should be opened.
///
/// It sat at the top of `TranscriptTextView` beside the menu that raises it, which is the one
/// place it could not stay once the list of items became a rule: `TranscriptLinkMenu` answers
/// with these, so they have to be somewhere the suite can see.
public enum TranscriptLinkTarget: Sendable, Hashable {
    /// The system's default browser, which is what a plain click does.
    case externalBrowser
    /// A browser tab in Bloom's own centre column.
    case browserTab
    /// A browser in the half a split opens: beside the transcript for `.horizontal` and below it
    /// for `.vertical`. The pane divided is the one the transcript is drawn in, not the column,
    /// because the point of the item is to read the page next to the conversation that named it.
    case split(SplitAxis)
}

/// One item of the menu a right click on a link raises.
///
/// The title travels with the target rather than being looked up beside the menu, so a test can
/// hold the words a reader sees. They are the words the rest of the app already uses: Split Right
/// and Split Down are what the View menu calls Cmd+\ and Shift+Cmd+\, and "Open in Split Right"
/// is the pair `TabItemView` offers on a tab. A third vocabulary for the same two directions is
/// exactly what `PaneSplitTool` says it is avoiding on the wire.
public struct TranscriptLinkItem: Sendable, Hashable, Identifiable {
    public var title: String
    public var target: TranscriptLinkTarget

    /// The target, because a menu never offers the same destination twice.
    public var id: TranscriptLinkTarget { target }

    public init(title: String, target: TranscriptLinkTarget) {
        self.title = title
        self.target = target
    }
}

/// How much of the centre column is behind the transcript a link was clicked in.
///
/// One value rather than two booleans, because the three states are ordered: a pane implies a
/// column, and a pair of flags would let a caller describe a pane of no column at all.
public enum TranscriptLinkPlacement: Sendable, Hashable, CaseIterable {
    /// A transcript with no centre column behind it. The archive sheet draws one and is gone, and
    /// the appearance sample in settings draws one belonging to no workspace. Neither has
    /// anywhere of its own to put a page.
    case detached
    /// A workspace's column, but no pane of it a split could divide: the transcript is drawn
    /// somewhere the window cannot name a pane for, or the tab it belonged to has been closed or
    /// rearranged out from under it.
    case column
    /// A pane of the tab in front, which is the pane a split divides.
    case pane
}

/// Which destinations a link in the transcript offers, and in which order.
///
/// **A rule rather than a menu, which is why it is here.** `LinkTextView.menu(for:)` used to
/// decide this inline, and a decision taken inside a view is a decision nothing can test: the one
/// condition it had, whether Bloom's browser could show the address at all, was a closure the view
/// called, and the reason that condition existed, that a menu item opening a blank tab is worse
/// than a menu item that is not there, holds just as much for the two split items that follow it.
/// The menu draws whatever this answers.
///
/// Copy Link is not in the list. It is on every link whatever the window is doing and it opens
/// nothing, so it stays the view's own item under the separator rather than becoming a target with
/// no destination that every switch over `TranscriptLinkTarget` would have to ignore.
public enum TranscriptLinkMenu {
    /// The openings a link offers, top to bottom.
    ///
    /// The external browser is always first and always there. It is the only destination needing
    /// nothing of Bloom's own, it is what a plain click already does, and an address refused
    /// everything else (a `mailto:`, most of all) is still a perfectly good thing to hand to the
    /// system.
    public static func items(
        for url: URL, placement: TranscriptLinkPlacement
    ) -> [TranscriptLinkItem] {
        var items = [TranscriptLinkItem(title: "Open in External Browser", target: .externalBrowser)]

        // Everything below opens a browser of Bloom's own, so everything below needs an address
        // one could show. Asked once here rather than per item, because an address that cannot
        // fill a tab cannot fill half a pane either.
        guard placement != .detached, BrowserAddress.shows(url) else { return items }
        items.append(TranscriptLinkItem(title: "Open in Browser Tab", target: .browserTab))

        // A split divides the pane the transcript is in, so it needs one. `.column` is the reader
        // looking at a transcript the window cannot place: the two items are dropped rather than
        // shown greyed, which is what `SessionTabsView.splitAction` does with the same pair.
        guard placement == .pane else { return items }
        items.append(TranscriptLinkItem(title: "Open in Split Right", target: .split(.horizontal)))
        items.append(TranscriptLinkItem(title: "Open in Split Down", target: .split(.vertical)))
        return items
    }
}
