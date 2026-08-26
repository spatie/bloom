import SwiftUI
import BloomCore

/// The centre column's panes, laid out from the split tree.
///
/// Positioned absolutely from the frames the tree computes rather than by nesting stacks the way
/// the tree nests, for the same two reasons the terminal does it: a nested layout would have to be
/// built out of `AnyView` because the view type would be recursive, and every reshape would move a
/// live transcript, web view or shell into a different superview. Flat means a pane keeps its place
/// in the hierarchy however the tree is rearranged around it.
///
/// That is also what makes a pane MOVE cheap. `SplitLayout.move` keeps every pane id, so a
/// rearranged tree changes the frame a pane is drawn at and never which view is drawing it: the
/// `ForEach` below is keyed by pane id, so SwiftUI moves the view it already has rather than
/// building a new one. A moved terminal keeps its shell and a moved browser keeps its page.
struct CenterPanesView: View {
    @Bindable var model: WorkspaceModel

    private var tabs: WorkspaceTabsStore { .shared }

    /// What a split takes out of the space its two panes share. One point, because the strip the
    /// pointer aims at is drawn over the panes rather than reserved between them.
    private static let dividerThickness: Double = 1

    /// The space a pane drag is measured in.
    ///
    /// Named rather than local, because the divider a drag starts from MOVES the moment a ratio
    /// changes, and a translation measured from an origin that the translation itself moved is a
    /// feedback loop. It is the column, so it is also the space the pane frames are already in and
    /// the space the wash is drawn in, which means the point the pointer is at, the pane it is
    /// over and the rectangle that says so are all one set of numbers rather than three.
    ///
    /// Nonisolated so `CenterPaneDivider` can name it without being on the main actor to do so.
    nonisolated static let space = "bloom.centrePanes"

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

    /// A pane being carried, and where it would land if it were let go now.
    ///
    /// `landing` is nil for a drag over somewhere that would not take it, which is the whole of
    /// how the gesture refuses: no wash appears, and letting go there does nothing. A drop that
    /// cannot be honoured says so while it is happening rather than after.
    private struct PaneMove: Equatable {
        var pane: String
        var point: CGPoint
        var landing: PaneLanding?
    }

    @State private var move: PaneMove?

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
                        let sides = layout.sides(at: divider.path)
                        CenterPaneDivider(
                            axis: divider.axis,
                            ratio: divider.ratio,
                            span: divider.span,
                            length: divider.axis == .horizontal
                                ? divider.frame.height
                                : divider.frame.width,
                            line: divider.frame,
                            first: sides?.first,
                            second: sides?.second,
                            onResize: { ratio in
                                guard let tab else { return }
                                tabs.setRatio(ratio, at: divider.path, in: tab)
                            },
                            onMoveChanged: { pane, point in
                                move = PaneMove(
                                    pane: pane,
                                    point: point,
                                    landing: landing(of: pane, at: point, in: geometry, of: layout)
                                )
                            },
                            onMoveEnded: { pane, point in
                                move = nil
                                guard let tab else { return }
                                commit(pane, at: point, in: geometry, of: layout, tab: tab)
                            }
                        )
                        .position(x: divider.frame.midX, y: divider.frame.midY)
                    }

                    if let move {
                        // Over everything, because it describes where a thing will go rather than
                        // being a thing in the column.
                        if let landing = move.landing {
                            Rectangle()
                                .fill(Palette.accent.opacity(0.12))
                                .frame(width: landing.frame.width, height: landing.frame.height)
                                .position(x: landing.frame.midX, y: landing.frame.midY)
                                .allowsHitTesting(false)
                        }
                        ghost(of: move, in: tab)
                    }
                }
            }
            .coordinateSpace(.named(Self.space))
        }
        .background(Palette.windowBackground)
    }

    // MARK: - Moving a pane

    /// Where a carried pane would land, or nil for somewhere that would not take it.
    ///
    /// It answers by trying the move on a copy of the tree rather than by listing the cases a view
    /// would have to keep in step with `SplitLayout`. A pane let go on its own middle, on the side
    /// of the divider it already sits against, or over a gap between panes all come back nil here
    /// for the same reason they would be refused a moment later, which is the point: the wash the
    /// user is looking at and the edit they are about to get are the same answer.
    private func landing(
        of pane: String, at point: CGPoint, in geometry: SplitGeometry, of layout: SplitLayout
    ) -> PaneLanding? {
        guard let landing = geometry.landing(at: point) else { return nil }
        var probe = layout
        return apply(pane, to: landing, in: &probe) ? landing : nil
    }

    @discardableResult
    private func apply(_ pane: String, to landing: PaneLanding, in layout: inout SplitLayout) -> Bool {
        guard let placement = landing.region.placement else {
            return layout.exchange(pane, with: landing.pane)
        }
        return layout.move(
            pane, beside: landing.pane, axis: placement.axis, before: placement.before
        )
    }

    private func commit(
        _ pane: String, at point: CGPoint, in geometry: SplitGeometry, of layout: SplitLayout,
        tab: PaneContent
    ) {
        guard let landing = landing(of: pane, at: point, in: geometry, of: layout) else { return }

        if let placement = landing.region.placement {
            tabs.move(
                pane: pane, beside: landing.pane,
                axis: placement.axis, before: placement.before,
                in: tab, of: model
            )
        } else {
            tabs.exchange(pane: pane, with: landing.pane, in: tab, of: model)
        }
    }

    /// The plate a carried pane is drawn as: wide enough to read as a pane rather than a chip,
    /// and small enough not to cover the drop target it is being moved onto. Named because it was
    /// two bare numbers in the middle of the stack below.
    private static let ghostSize = CGSize(width: 96, height: 56)

    /// The small plate under the pointer while a pane is being carried.
    ///
    /// Deliberately a token rather than a picture of the pane. A live shell or a loaded page cannot
    /// be snapshotted for a drag without stopping to render it, and a scaled copy of half the
    /// column is a lot of moving furniture to say one thing. Ghostty carries a small rounded
    /// rectangle for the same reason, and the wash is what actually says where it is going.
    @ViewBuilder
    private func ghost(of move: PaneMove, in tab: PaneContent?) -> some View {
        let symbol = tab.map { icon(of: tabs.content(of: move.pane, in: $0)) } ?? PaneKind.chat.symbol

        RoundedRectangle(cornerRadius: Metrics.corner, style: .continuous)
            .fill(Palette.surface)
            .overlay {
                RoundedRectangle(cornerRadius: Metrics.corner, style: .continuous)
                    .strokeBorder(Palette.border, lineWidth: Metrics.hairline)
            }
            .overlay { Image(systemName: symbol).foregroundStyle(Palette.textSecondary) }
            .frame(width: Self.ghostSize.width, height: Self.ghostSize.height)
            // Carried under the pointer, which is `lifted`. It had a fourth recipe of its own.
            .elevation(.lifted)
            .position(x: move.point.x, y: move.point.y)
            .allowsHitTesting(false)
    }

    private func icon(of content: PaneContent) -> String {
        switch content {
        case .chat:
            return PaneKind.chat.symbol
        case .tool(let id):
            let open = CenterTabStore.shared.tabs(for: model.workspace.id)
            return open.first { $0.id == id }?.icon ?? PaneKind.terminal.symbol
        }
    }
}

extension SplitPaneFrame {
    /// The name every unsplit tab's only pane answers to. See `CenterPanesView.soloPane`.
    var soloIdentity: String { CenterPanesView.soloPane }
}
