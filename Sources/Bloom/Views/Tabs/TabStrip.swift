import SwiftUI

/// The colours a tab wears while it is the selected one.
///
/// A selected tab is the top of the pane it opens rather than a lid laid over it, so it is filled
/// with that pane's own ground. Usually the ground is one of Bloom's, and then the ink on it is
/// Bloom's own label colour. A terminal running the user's Ghostty theme is the exception: its
/// pane is whatever that theme says, and the only ink guaranteed to read on it is the foreground
/// the same theme names.
///
/// The pair is taken whole or not at all. A theme that gives a ground but no foreground leaves
/// nothing that is certain to be legible, and a tab whose own name has vanished is worse than one
/// that does not match the pane below it.
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
/// It settles two things at once and they are the same thing seen from either end: what an
/// ordinary tab in that strip is filled with when selected, and how far the strip's own track has
/// to be sunk below it.
enum TabPane {
    /// The reading ground: the centre column's conversations, terminals, browsers and reviews.
    case content
    /// A recessed pane: the bottom panel's setup log, run scripts and shells.
    case sunken

    var surface: TabSurface {
        switch self {
        case .content: .pane(Palette.surface)
        case .sunken: .pane(Palette.surfaceSunken)
        }
    }

    /// How far the track is tinted away from the tab selected on it, as an opacity on the primary
    /// label colour so it darkens in a light appearance and lightens in a dark one.
    ///
    /// Safari's strip sits about twelve units out of 255 off the tab selected on it, and that step,
    /// rather than the type, is the whole of how a selected tab is told from an unselected one.
    /// Both strips stand on `Palette.sidebar`; what differs is the pane, so what differs is the
    /// tint each of them needs to reach the same step.
    ///
    /// `.content`: `#FFFFFF` on `#F1F5F6` is already 14, 10 and 9 in a light appearance, which is
    /// Safari's figure with no tint at all, and 0.045 of black on top took it to 25, 21 and 20,
    /// roughly double, which read as a grey band rather than as a recess. In dark, `#0A1A25` on
    /// `#0E202D` is 4, 6 and 8, which is nothing, and 0.045 of white brings it back.
    ///
    /// `.sunken`: `#F7FAFA` is five units nearer the chrome than the reading ground is, so a light
    /// appearance has a step of 6, 5 and 4 to begin with and the difference has to be painted back
    /// on. In dark the pane is BELOW the track rather than above it, `#0C1E2A` on `#0E202D`, a step
    /// of 2, 2 and 3, and lightening the track moves it further away rather than nearer.
    ///
    /// Composited against the label colour these four resolve to a track of `#F1F5F6`, `#172935`,
    /// `#EAEEEF` and `#182936`, which stands 14, 10, 9 / 13, 15, 16 / 13, 12, 11 / 12, 11, 12 off
    /// the tab selected on it. Safari's figure in every one of them.
    ///
    /// A terminal carrying the user's own Ghostty theme is outside this: its tab is filled with
    /// whatever that theme says, so the step against the track is whatever the theme happens to be
    /// and can be almost nothing. `TabItemOutline` is what draws that tab's edge in that case, and
    /// it is why the outline is part of the shared chrome rather than the centre column's alone.
    ///
    /// Re-measure rather than trust these numbers if either ground moves: what is being kept is the
    /// twelve unit step, not the opacities.
    func recess(_ colorScheme: ColorScheme) -> Double {
        switch (self, colorScheme) {
        case (.content, .dark): 0.045
        case (.content, _): 0
        case (.sunken, .dark): 0.05
        case (.sunken, _): 0.035
        }
    }
}

/// The track a row of tabs sits in.
///
/// One component for both of Bloom's strips: the centre column's conversations and tools, and the
/// bottom panel's setup, scripts and shells. What they share is everything that makes a run of
/// labels read as tabs, which is the bar's height, the recess under it, the rule that closes it
/// off from the pane, and the fact that only the tabs scroll. What they do not share are the
/// controls around them, which is why those are slots rather than options: the centre column ends
/// in the inspector's toggle, the bottom panel begins with the chevron that collapses it.
///
/// There are three of those slots and the middle one is the interesting one. `leading` and
/// `trailing` are the ends of the strip and stay there. `append` rides the end of the TABS: it is
/// where the `+` goes, and it sits against the last tab while the tabs fit and against the end of
/// the strip once they do not. Both strips put their `+` there.
///
/// The slots carry their own separators. A strip knows whether a rule belongs before its first
/// control; this view does not, and guessing produced a stray hairline at one end or the other.
struct TabStrip<Leading: View, Tabs: View, Append: View, Trailing: View>: View {
    var pane: TabPane
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

    @Environment(\.colorScheme) private var colorScheme
    /// The width the tabs have to fit in. Only used to re-aim the scroll when the window is
    /// resized, so it is stored rounded to whole points and changes about as often as they do.
    @State private var width: CGFloat = 0
    /// What the tabs come to when nothing is holding them back, which is what the scrolling part
    /// of the strip is capped at. See `body`.
    ///
    /// Optional so that a strip with no tabs at all is told apart from one that has not been
    /// measured yet. They want opposite answers: no tabs means no room for tabs, so whatever
    /// follows them starts at the leading edge, while no measurement means carry on as before and
    /// let the scroller have the row.
    @State private var tabsWidth: CGFloat?
    /// Which ends of the strip have tabs beyond them. Rounded to whole points for the same reason
    /// as `width`: a drag must not write state once a frame.
    @State private var overflow = TabStripOverflow()

    init(
        pane: TabPane = .content,
        selection: AnyHashable? = nil,
        @ViewBuilder leading: () -> Leading,
        @ViewBuilder tabs: () -> Tabs,
        @ViewBuilder append: () -> Append,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.pane = pane
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
                        .onGeometryChange(for: CGFloat.self) { $0.size.width.rounded(.up) } action: {
                            tabsWidth = $0
                        }
                }
                .scrollIndicators(.never)
                // Only as wide as the tabs, so whatever `append` holds sits against the last tab
                // rather than out at the end of the strip with a lake of empty chrome between
                // them. The cap is an upper bound and nothing more: the moment the tabs come to
                // more than the strip can show, the row hands the scroller everything that is
                // left and the `+` lands exactly where it has always been, hard against the
                // controls at the end. There is no threshold to cross and nothing jumps, because
                // the two positions are the same position at the width where the tabs stop
                // fitting.
                //
                // Uncapped until the first measurement, which is the greedy scroller this has
                // always been.
                //
                // The measurement cannot chase itself: a horizontal scroller proposes no width to
                // what it holds, so the tabs come to the same total whatever this cap says.
                .frame(maxWidth: tabsWidth ?? .infinity)
                .onGeometryChange(for: CGFloat.self) { $0.size.width.rounded() } action: { width = $0 }
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
            }

            append

            // What is left of the strip once the tabs and the `+` have had theirs. It is the whole
            // of the gap the user sees to the right of the tabs, and it belongs to this view
            // rather than to a caller: a strip whose slots were all intrinsically sized would not
            // fill the column it is drawn in.
            Spacer(minLength: 0)

            trailing
        }
        .frame(height: Metrics.barHeight)
        // Painted over the chrome and under the tabs. See `TabPane.recess`.
        .background { Color.primary.opacity(pane.recess(colorScheme)) }
        // The busy signal belongs to the rule under the title bar and to nothing else. The centre
        // column's strip is the only one drawn on that rule: the bottom panel's is a `.sunken`
        // strip halfway down the window, and a light travelling that would be a second heartbeat
        // in a window that is meant to have one.
        .tabStripMaterial(sweeping: pane == .content)
    }
}

extension TabStrip {
    /// Opaque across the middle, fading only at an end that has tabs past it.
    ///
    /// Written as one gradient with four stops rather than as two overlays, because a stop that is
    /// not wanted can be collapsed onto its neighbour and then it draws nothing. With neither end
    /// overflowing this is a flat black mask, which is the same as no mask at all.
    private var fade: some View {
        let step = width > 0 ? min(TabStripOverflow.fadeWidth / width, 0.5) : 0
        return LinearGradient(
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
        pane: TabPane = .content,
        selection: AnyHashable? = nil,
        @ViewBuilder tabs: () -> Tabs,
        @ViewBuilder append: () -> Append,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.init(
            pane: pane, selection: selection,
            leading: { EmptyView() }, tabs: tabs, append: append, trailing: trailing
        )
    }
}

extension TabStrip where Trailing == EmptyView {
    /// A strip that ends with whatever follows its tabs, which is the bottom panel: the `+` is the
    /// last thing in it and there is no control pinned past that.
    init(
        pane: TabPane = .content,
        selection: AnyHashable? = nil,
        @ViewBuilder leading: () -> Leading,
        @ViewBuilder tabs: () -> Tabs,
        @ViewBuilder append: () -> Append
    ) {
        self.init(
            pane: pane, selection: selection,
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

/// The box a control at one end of a tab strip is drawn in: the bottom panel's chevron and its
/// `+`.
///
/// The slot stays the bar's own height, square, so nothing in the strip moves and the tabs start
/// where they started. What this settles is the PLATE inside it.
///
/// `.accessoryBar` draws its hover and pressed states in the button's OWN bounds, and a button
/// handed a frame fills that frame, so a control given the whole slot came out with a plate the
/// full width of it. Measured off a two times capture of the strip: the chevron's plate ran from
/// x=0 to x=32 and the rule before the first tab began on x=32, with no daylight at all between
/// the two shapes. The `+` had the same join mirrored, its plate's leading edge hard against the
/// rule that follows the last tab. Against a SELECTED first tab, where that rule is hidden, the
/// plate ended on x=32 and the tab's own outline began on x=33: one point of ground, which is a
/// single pixel of it on a display that is not Retina.
///
/// So the plate is what was too wide, rather than the gap after it being too small, and the two
/// want different fixes: the gap can only be widened by moving something, while the plate can be
/// inset inside a slot that does not move. Two points at each side, which is `Metrics.spacingTight`
/// and the same figure the sidebar's header buttons keep above and below their own plate. Taken
/// off both sides rather than the trailing one, so the glyph stays on the centre of its slot.
///
/// The cost is two points of hit target at each side. The plate IS the button here, so a narrower
/// plate is a narrower button and there is no way to have one without the other; what is left is
/// 28 points across, in a bar whose controls are only about sixteen points tall to begin with.
struct TabStripControlBox: ViewModifier {
    /// The daylight each side of the plate. The tight rung of the spacing scale.
    static let inset: CGFloat = Metrics.spacingTight

    func body(content: Content) -> some View {
        content
            .frame(width: Metrics.barHeight - 2 * Self.inset, height: Metrics.barHeight)
            .padding(.horizontal, Self.inset)
    }
}

extension View {
    /// See `TabStripControlBox`.
    func tabStripControl() -> some View {
        modifier(TabStripControlBox())
    }
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
