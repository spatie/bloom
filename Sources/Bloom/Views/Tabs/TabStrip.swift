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
/// controls at each end, which is why those are slots rather than options: the centre column ends
/// in a `+` and the inspector's toggle, the bottom panel begins with the chevron that collapses it.
///
/// The slots carry their own separators. A strip knows whether a rule belongs before its first
/// control; this view does not, and guessing produced a stray hairline at one end or the other.
struct TabStrip<Leading: View, Tabs: View, Trailing: View>: View {
    var pane: TabPane
    var leading: Leading
    var tabs: Tabs
    var trailing: Trailing

    @Environment(\.colorScheme) private var colorScheme

    init(
        pane: TabPane = .content,
        @ViewBuilder leading: () -> Leading,
        @ViewBuilder tabs: () -> Tabs,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.pane = pane
        self.leading = leading()
        self.tabs = tabs()
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 0) {
            leading

            ScrollView(.horizontal) {
                tabs
            }
            .scrollIndicators(.never)

            trailing
        }
        .frame(height: Metrics.barHeight)
        // Painted over the chrome and under the tabs. See `TabPane.recess`.
        .background { Color.primary.opacity(pane.recess(colorScheme)) }
        .tabStripMaterial()
    }
}

extension TabStrip where Leading == EmptyView {
    /// A strip whose leading end is the first tab.
    init(
        pane: TabPane = .content,
        @ViewBuilder tabs: () -> Tabs,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.init(pane: pane, leading: { EmptyView() }, tabs: tabs, trailing: trailing)
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
