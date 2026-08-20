import SwiftUI
import BloomCore

/// The mark at the head of a sidebar row whose agent is mid turn.
///
/// Three dots in a vertical line, brightening and dimming in turn so the light runs down them and
/// back. It is Conductor's mark for the same state, in Bloom's own glyph box and Bloom's own
/// accent, and it is the only thing in the sidebar that moves.
///
/// It REPLACES the pulsing `ActivityDot` that used to stand here rather than joining it. Both
/// occupy the row's one glyph slot, so keeping both was never on the table, and of the two this is
/// the one that says which agent is working without also being the shape the app uses for "a thing
/// is happening" in four other places. The row now has one moving part, not two, and the tab strip
/// and the transcript keep the dot they always had.
///
/// The row cannot shift when the state changes. `WorkspaceStatusGlyph` frames every one of its
/// thirteen marks in the same `Metrics.glyph` box, this one included, and the figure is centred in
/// it: a workspace that starts working, finishes, and comes back with changed files draws three
/// different shapes in the same square and the name beside it never moves a pixel. Measured on a
/// capture: the name begins on the same pixel in a running row and an idle one.
///
/// # Why the dots do not step
///
/// The first version of this built a figure out of nothing, a stage per beat: one dot, then a line
/// of three, then a grid of six. It was wrong, and wrong in a way worth writing down, because it
/// reads perfectly well in the source and cannot look right on a screen. Swapping between three
/// arrangements gives exactly three frames of motion however often the swap fires, and shortening
/// the interval only makes the three arrivals come sooner. It was read as "like 3 frames" from
/// across the room, which is precisely what it was.
///
/// So nothing here is stepped. Each dot holds one opacity, animated between two values, and Core
/// Animation interpolates it at whatever the display refreshes at: 120 frames a second on a
/// ProMotion panel and 60 on anything else, with no rate named anywhere here. All the clock
/// supplies is the moment the ramp begins, which is the one thing that has to be shared.
///
/// The travel is `stagger`. Every dot animates the same flip, each starting a little after the one
/// above it, so at any instant the three are at three different points of the same ramp and the
/// brightness runs down the line. Without it the three would brighten together, which is a blink.
///
/// # The phase is not this view's
///
/// Every one of these reads `BusyPulse` rather than starting an animation of its own, which is the
/// whole argument on that type: five agents started at five moments give five figures at five
/// phases, and nothing ever pulls them back together. Reading one counter, five lit rows are one
/// rhythm down the column, and they are in step with the light on the rule as well, because the
/// sweep is exactly three of these.
///
/// # What it costs
///
/// Three opacity animations per running row, restarted once a beat, and one body evaluation per
/// row in the same beat. The list is an `NSTableView` underneath, so a running row scrolled out of
/// view is not built and holds nothing. The clock stops when the window is not the front one and
/// when Reduce Motion is on, and the figure then rests at full strength, which is the state the
/// mark means anyway. Measured against the `ActivityDot` this replaces, on the same window with
/// three agents running, it is the cheaper of the two.
struct WorkspaceRunningGlyph: View {
    /// Set on a row sitting on the accent selection fill, where the accent itself is unreadable.
    var isOnSelection = false

    private var pulse: BusyPulse { .shared }

    /// The figure: three dots, three points across and one point apart.
    ///
    /// Whole points, and that is the only reason these are not 2.5 and 2. Eleven points centred in
    /// the thirteen point glyph box puts every dot on a whole point, so the figure is drawn on
    /// pixel boundaries at one times as well as at two. The half point version measured 11.5 in a
    /// 13 box, which lands the first dot on 0.75 and softens all three on a display that has no
    /// half pixels to soften them into.
    private static let dot: CGFloat = 3
    private static let gap: CGFloat = 1
    private static let count = 3

    /// How far each dot's ramp trails the one above it. Long enough that the eye reads a direction
    /// rather than three dots moving as one, short enough that the last dot has finished before
    /// the next beat begins: two of these plus `ramp` is `BusyPulse.tickInterval` to the
    /// millisecond.
    private static let stagger: Double = 0.1

    /// How long one dot takes to cross between its two opacities.
    private static let ramp: Double = 0.55

    /// What a dot holds at the bottom of its ramp. Not zero: a dot that goes out entirely makes
    /// the figure a different shape twice a beat, and the shape is what this column is read by.
    private static let dim: Double = 0.22

    private var tint: Color { isOnSelection ? Palette.textInverted : Palette.running }

    var body: some View {
        // One boolean for the whole figure, flipped by the shared clock. Every dot animates that
        // same flip on its own delay, which is what turns a blink into a travel.
        let isHigh = pulse.isTicking && pulse.isWaveHigh
        let isTicking = pulse.isTicking

        return VStack(spacing: Self.gap) {
            ForEach(0..<Self.count, id: \.self) { index in
                Circle()
                    .fill(tint)
                    .frame(width: Self.dot, height: Self.dot)
                    .opacity(isTicking ? (isHigh ? 1 : Self.dim) : 1)
                    .animation(
                        isTicking
                            ? .easeInOut(duration: Self.ramp).delay(Double(index) * Self.stagger)
                            : nil,
                        value: isHigh
                    )
            }
        }
    }
}
