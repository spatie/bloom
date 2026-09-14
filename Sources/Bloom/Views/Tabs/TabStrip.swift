import SwiftUI

/// The colours a tab wears while it is the selected one.
///
/// The selected capsule uses its pane's background and text colours. Terminal tabs can carry a
/// custom Ghostty theme, so the background and foreground must stay together for readable labels.
struct TabSurface: Equatable {
    /// What the selected tab is filled with.
    var fill: Color
    /// The selected tab's title and glyph.
    var ink: Color
    /// A step under `ink`, for the close cross, which is a smaller mark and should not be the
    /// heaviest thing in the strip.
    var inkMuted: Color

    /// One of Bloom's own grounds, wearing Bloom's own label colours.
    static func pane(_ fill: Color) -> TabSurface {
        TabSurface(fill: fill, ink: Palette.textPrimary, inkMuted: Palette.textSecondary)
    }

    /// A pane painted by something outside the app, which therefore has to bring its own ink.
    ///
    /// The muted step is an opacity on that ink rather than Bloom's secondary label: over a cream
    /// terminal in a light window the secondary label is a mid grey that all but disappears, and
    /// over a near black one it disappears the other way.
    static func themed(fill: Color, ink: Color) -> TabSurface {
        TabSurface(fill: fill, ink: ink, inkMuted: ink.opacity(0.62))
    }
}

/// Which of Bloom's grounds a strip of tabs opens onto.
///
/// Determines the selected tab's background.
enum TabPane {
    /// The reading ground: the centre column's conversations, terminals, browsers and reviews.
    case content
    /// A recessed pane: the bottom panel's setup log, run scripts and shells.
    case sunken

    @MainActor var surface: TabSurface {
        switch self {
        case .content: .pane(Palette.surface)
        case .sunken: .pane(Palette.surfaceSunken)
        }
    }

}

/// Tabs share the pane's available width. Controls stay at the ends while crowded tabs scroll.
struct TabStrip<Leading: View, Tabs: View, Append: View, Trailing: View>: View {
    var pane: TabPane
    var tabCount: Int
    /// The id of the selected tab, if the caller tags its tabs with `.id`.
    ///
    /// The strip scrolls whichever tab this names fully into view, on selection and on every
    /// change of its own width. Without it the last tab in a strip that has run out of room is
    /// drawn half off the end: at the window's minimum width "All changes" rendered as "All
    /// change" with the s sliced down the middle, no ellipsis and no sign that there was anything
    /// to scroll to. The strip could always be scrolled, but only with a horizontal gesture and
    /// with `.scrollIndicators(.never)` there was nothing to say so, so a clipped tab read as a
    /// layout bug rather than as an edge.
    ///
    /// Optional, and nil for a strip that does not care: the bottom panel's tabs are few and
    /// short, and a strip that never overflows has nothing to scroll.
    var selection: AnyHashable?
    var leading: Leading
    var tabs: Tabs
    var append: Append
    var trailing: Trailing

    @Environment(\.appearsActive) private var appearsActive
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Available width for the tabs, rounded down so their combined width stays inside the track.
    @State private var width: CGFloat = 0
    /// Measured separately to suppress stale overflow fades while the tabs still fit.
    @State private var tabsWidth: CGFloat?
    /// Which ends of the strip have tabs beyond them. Rounded to whole points for the same reason
    /// as `width`: a drag must not write state once a frame.
    @State private var overflow = TabStripOverflow()

    init(
        tabCount: Int,
        pane: TabPane = .content,
        selection: AnyHashable? = nil,
        @ViewBuilder leading: () -> Leading,
        @ViewBuilder tabs: () -> Tabs,
        @ViewBuilder append: () -> Append,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.pane = pane
        self.tabCount = tabCount
        self.selection = selection
        self.leading = leading()
        self.tabs = tabs()
        self.append = append()
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 0) {
            leading

            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    tabs
                        .environment(\.tabItemWidth, itemWidth)
                        .background {
                            Capsule()
                                .fill(Palette.hover.opacity(appearsActive ? 1 : 0.8))
                                .frame(height: Metrics.barHeight - Metrics.spacingSmall)
                                .allowsHitTesting(false)
                        }
                        .onGeometryChange(for: CGFloat.self) { $0.size.width.rounded(.up) } action: {
                            tabsWidth = $0
                        }
                        // Keep existing tabs moving while the new or closing tab fades. Scoping
                        // this to the count leaves title updates and window resizing immediate.
                        .animation(reduceMotion ? nil : Motion.pane, value: tabCount)
                }
                .scrollIndicators(.never)
                .frame(maxWidth: .infinity)
                .onGeometryChange(for: CGFloat.self) { $0.size.width.rounded(.down) } action: { width = $0 }
                // A tab that runs off the end used to be sliced down the middle of a letter, which
                // reads as a layout bug rather than as an edge: "All changes" came out as "All
                // change" with the s cut in half, hard against the `+`. The strip could always be
                // scrolled and there was nothing at all to say so, because the scroller is hidden.
                // A fade at whichever end has more beyond it is that sign, and it costs the strip
                // no height and no control.
                .onScrollGeometryChange(for: TabStripOverflow.self, of: Self.measure) { _, new in
                    overflow = new
                }
                .mask { fade }
                // Both, because either alone leaves a case wrong: selecting a tab off the end has
                // to bring it in, and narrowing the window until the selected tab falls off the end
                // has to bring it back. `anchor: nil` scrolls the least it can to make the tab
                // whole, so a tab already in view does not move at all.
                .onChange(of: selection, initial: true) { _, _ in reveal(proxy) }
                .onChange(of: width) { _, _ in reveal(proxy) }
                .onChange(of: tabCount) { _, _ in reveal(proxy) }
            }

            append

            trailing
        }
        .padding(.leading, Metrics.spacingWide)
        .frame(height: Metrics.barHeight)
        .background(Palette.sidebar)
        // The busy signal belongs to the rule under the title bar and to nothing else. The centre
        // column's strip is the only one drawn on that rule: the bottom panel's is a `.sunken`
        // strip halfway down the window, and a second line brightening there would be a second
        // heartbeat in a window that is meant to have one.
        .tabStripMaterial(busy: pane == .content)
    }
}

extension TabStrip {
    private var itemWidth: CGFloat {
        guard tabCount > 0 else { return TabItemView.minimumWidth }
        let separators = CGFloat(tabCount - 1) * Metrics.hairline
        return max(TabItemView.minimumWidth, (width - separators) / CGFloat(tabCount))
    }

    @ViewBuilder
    private var fade: some View {
        // Scroll geometry can arrive before the tabs settle after a resize or count change.
        if let tabsWidth, tabsWidth <= width {
            Color.black
        } else {
            let step = width > 0 ? min(TabStripOverflow.fadeWidth / width, 0.5) : 0
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .black, location: overflow.leading ? step : 0),
                    .init(color: .black, location: overflow.trailing ? 1 - step : 1),
                    .init(color: .clear, location: 1),
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
        }
    }

    /// Whether there is anything past either end, from the scroll view's own geometry. A point of
    /// slack, so a strip resting exactly at an end does not fade over a rounding error.
    private static func measure(_ scroll: ScrollGeometry) -> TabStripOverflow {
        TabStripOverflow(
            leading: scroll.contentOffset.x > 1,
            trailing: scroll.contentOffset.x + scroll.containerSize.width
                < scroll.contentSize.width - 1
        )
    }

    /// Puts the selected tab fully in view, moving as little as possible.
    ///
    /// After the frame the change landed on, because the tab that was just opened does not exist
    /// in the scroll view's layout yet and scrolling to an id it has never laid out does nothing.
    private func reveal(_ proxy: ScrollViewProxy) {
        guard let selection else { return }
        Task { @MainActor in
            await Task.yield()
            proxy.scrollTo(selection, anchor: nil)
        }
    }
}

extension TabStrip where Leading == EmptyView {
    /// A strip whose leading end is the first tab.
    init(
        tabCount: Int,
        pane: TabPane = .content,
        selection: AnyHashable? = nil,
        @ViewBuilder tabs: () -> Tabs,
        @ViewBuilder append: () -> Append,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.init(
            tabCount: tabCount, pane: pane, selection: selection,
            leading: { EmptyView() }, tabs: tabs, append: append, trailing: trailing
        )
    }
}

extension TabStrip where Trailing == EmptyView {
    /// A strip that ends with whatever follows its tabs, which is the bottom panel: the `+` is the
    /// last thing in it and there is no control pinned past that.
    init(
        tabCount: Int,
        pane: TabPane = .content,
        selection: AnyHashable? = nil,
        @ViewBuilder leading: () -> Leading,
        @ViewBuilder tabs: () -> Tabs,
        @ViewBuilder append: () -> Append
    ) {
        self.init(
            tabCount: tabCount, pane: pane, selection: selection,
            leading: leading, tabs: tabs, append: append, trailing: { EmptyView() }
        )
    }
}

/// Which ends of a tab strip have tabs beyond them.
struct TabStripOverflow: Equatable {
    var leading = false
    var trailing = false

    /// How far the fade at an overflowing end runs. About a character and a half at the tab's own
    /// rung, which is enough to read as "this carries on" and short enough that it never eats a
    /// whole word.
    ///
    /// It lives here rather than on `TabStrip`, which is generic over three view types and so
    /// cannot hold a stored static of its own.
    static let fadeWidth: CGFloat = 16
}

/// The rule between two tabs, and between the tabs and the controls at either end.
///
/// Half the height of the strip and one point wide, measured off Safari, where the rule between
/// two unselected tabs is exactly half the bar and two device pixels across. It used to be a
/// hairline over a taller run, which read as a grid line.
///
/// Softened, because the same measurement covers the contrast: Safari's rule is about six per cent
/// darker than the strip it is on, and the separator colour at full strength was nearly twice that.
/// A rule between two tabs is there to be found, not to be seen.
///
/// It is kept in the layout when it is not wanted rather than removed, because a rule that came and
/// went as the selection moved would shift every tab beside it by half a point.
struct TabStripSeparator: View {
    var isHidden = false

    var body: some View {
        Rectangle()
            .fill(Palette.border.opacity(0.7))
            .frame(width: Metrics.hairline, height: Metrics.barHeight / 2)
            .opacity(isHidden ? 0 : 1)
    }
}
