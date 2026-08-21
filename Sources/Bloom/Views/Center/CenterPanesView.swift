import SwiftUI
import BloomCore

/// The centre column's panes, laid out from the split tree.
///
/// Positioned absolutely from the frames the tree computes rather than by nesting stacks the way
/// the tree nests, for the same two reasons the terminal does it: a nested layout would have to be
/// built out of `AnyView` because the view type would be recursive, and every reshape would move a
/// live transcript, web view or shell into a different superview. Flat means a pane keeps its place
/// in the hierarchy however the tree is rearranged around it.
struct CenterPanesView: View {
    @Bindable var model: WorkspaceModel

    private var tabs: WorkspaceTabsStore { .shared }

    /// What a split takes out of the space its two panes share. One point, because the strip the
    /// pointer aims at is drawn over the panes rather than reserved between them.
    private static let dividerThickness: Double = 1

    /// What identifies a pane to `ForEach`, which is not the same question as what identifies it
    /// to the store.
    ///
    /// A tab nobody has split has one pane, and that pane carries the id of the content at its
    /// root. Used as the view's identity that means the identity of the centre column's whole
    /// contents changes every time the window moves to another workspace, AND every time it moves
    /// to another tab, so SwiftUI destroys the pane and builds a new one: the tab strip's tab, the transcript list, every row it has realised, the
    /// composer and its text view are made again from nothing, and none of the sizes SwiftUI had
    /// measured for the old one can be reused for the new. Measured on a release build at 1440 by
    /// 900 across four of the owner's own workspaces, forty eight warm switches interleaved
    /// between the two builds: the centre column's layout cost 30ms and its worst frame gap 55ms
    /// with the pane keyed this way, and 8ms and 30ms with it keyed the way below.
    ///
    /// So an unsplit tab is one pane called the same thing in every workspace and in every tab,
    /// and its view is reused and handed a different model and a different tab instead of being
    /// replaced. A split tab keeps the real pane ids, because there the identity has to survive
    /// the tree being rearranged around it: that is the whole reason these frames are positioned flat rather than nested, and a
    /// pane identified by its place in the list would hand a live shell or web view to the view
    /// that used to be its neighbour. Going from one pane to two, or back, rebuilds. That is a
    /// reshape the user asked for and can see, not something that happens on every switch.
    /// Nonisolated because `SplitPaneFrame.soloIdentity` is what reads it, and that lives on a
    /// value type from BloomCore that is on no actor at all. A `View` puts everything it declares
    /// on the main actor, and a name that never changes has no business being one of them.
    nonisolated static let soloPane = "solo"

    var body: some View {
        // Read here rather than inside the `GeometryReader`, so the dependency on the store is
        // registered while this body is being tracked. A read that only happens in the layout pass
        // is a redraw that only happens by luck.
        //
        // Nil is a workspace with neither a conversation nor a tool tab to be in. It still gets
        // one pane, so `CenterPaneView` can draw the empty states that offer a way out of it.
        let tab = tabs.selectedTab(in: model)
        let layout = tab.map { tabs.layout(of: $0) } ?? SplitLayout(pane: Self.soloPane)

        return GeometryReader { proxy in
            let geometry = layout.geometry(in: proxy.size, dividerThickness: Self.dividerThickness)

            ZStack(alignment: .topLeading) {
                if proxy.size.width > 1, proxy.size.height > 1 {
                    let isSolo = geometry.panes.count == 1
                    ForEach(geometry.panes, id: isSolo ? \.soloIdentity : \.pane) { item in
                        CenterPaneView(
                            model: model,
                            tab: tab,
                            pane: item.pane,
                            isSplit: layout.paneCount > 1
                        )
                        .frame(width: item.frame.width, height: item.frame.height)
                        // A pane whose content cannot fit the width it was given keeps the
                        // overflow to itself. Without this a composer wider than half the column
                        // draws over the pane beside it, and the two conversations bleed together.
                        .clipped()
                        .position(x: item.frame.midX, y: item.frame.midY)
                    }

                    ForEach(geometry.dividers, id: \.path) { divider in
                        SplitPaneDivider(
                            axis: divider.axis,
                            ratio: divider.ratio,
                            span: divider.span,
                            length: divider.axis == .horizontal
                                ? divider.frame.height
                                : divider.frame.width,
                            color: Palette.border
                        ) { ratio in
                            guard let tab else { return }
                            tabs.setRatio(ratio, at: divider.path, in: tab)
                        }
                        .position(x: divider.frame.midX, y: divider.frame.midY)
                    }
                }
            }
        }
        .background(Palette.windowBackground)
    }
}

extension SplitPaneFrame {
    /// The name every unsplit tab's only pane answers to. See `CenterPanesView.soloPane`.
    var soloIdentity: String { CenterPanesView.soloPane }
}
