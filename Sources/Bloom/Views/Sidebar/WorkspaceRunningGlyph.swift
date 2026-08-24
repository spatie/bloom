import SwiftUI
import BloomCore

/// The mark at the head of a sidebar row whose agent is mid turn.
///
/// A single dot that swells and dims, which is the same mark the transcript sets beside
/// "Requesting" and "Working" and the same mark a running tab carries. It is drawn by `PulsingDot`
/// at this column's own size and tint, so the two cannot drift apart.
///
/// It replaced a pair of concentric rings whose radial gap breathed, and the argument for those
/// was a good one: at thirteen points a single element changing size is a dot getting bigger,
/// where two elements approaching each other is a gesture, and a gesture survives being small. The
/// owner looked at both in the window and preferred the dot. What that trades away is the gesture;
/// what it buys is that the window says "this is working" in one shape rather than in two, and the
/// sidebar's mark is now the mark somebody has already learned in the transcript.
///
/// The row cannot shift when the state changes. `WorkspaceStatusGlyph` frames every one of its
/// marks in the same `Metrics.glyph` box, this one included, and the figure is centred in it: a
/// workspace that starts working, finishes, and comes back with changed files draws three different
/// shapes in the same square and the name beside it never moves a pixel.
///
/// # The phase is not this view's
///
/// `PulsingDot` reads `BusyPulse.epoch` rather than starting a loop of its own, which is the whole
/// argument on that type: five agents started at five moments give five figures at five phases, and
/// nothing ever pulls them back together. Phased off one instant, five working rows pulse as one
/// column, and they are in step with the light on the rule as well, because two pulses are exactly
/// one crossing of it. See `BusyDot.period`.
///
/// # What it costs
///
/// One layer per working row and two `CABasicAnimation`s, added when the row starts working and
/// never touched again. Nothing here rasterises a path per frame: the circle is built once at the
/// widest it will ever be and then scaled down, so the render server is interpolating a transform
/// and an opacity and nothing else. That matters because a sidebar can show many working rows at
/// once, and per row cost multiplies where the window's does not.
///
/// It keeps moving while the window is behind another app, which is the state a running agent is
/// most often watched from, and it costs nothing to leave running because the render server owns
/// the interpolation. Reduce Motion still holds it still, and the figure then rests as a whole dot,
/// which is a good mark in its own right.
struct WorkspaceRunningGlyph: View {
    /// Set on a row sitting on the accent selection fill, where the accent itself is unreadable.
    var isOnSelection = false

    /// The box the figure is centred in, which is the box every other mark in this column already
    /// uses. The dot reaches 8.1 points at the top of its pulse, so 13 cannot clip it.
    static let box: CGFloat = Metrics.glyph

    /// How wide the dot rests. The app's one dot size, and the size is not free.
    ///
    /// The unread mark in this same column is `circle.fill` at `Typo.micro`, which is a filled
    /// circle in the same accent: measured off an offscreen render at two times, it is ten points
    /// across. So the running mark is now a state that differs from its neighbour in size and in
    /// whether it moves, where the rest of the column differs in shape, and the only thing that
    /// keeps the two apart in a still is the gap between them. Eight was tried first and was
    /// wrong: it swells to 10.8, so at the top of every pulse it was exactly the unread mark.
    /// `Metrics.dot` rests at six and peaks at 8.1, which never reaches it.
    ///
    /// The box is what caps this. The dot cannot be made bigger than the unread mark instead: 13
    /// points of box over a peak of 1.35 leaves 9.6, which is under ten before the pulse starts.
    static let diameter: CGFloat = Metrics.dot

    private var tint: Color { isOnSelection ? Palette.textInverted : Palette.running }

    var body: some View {
        PulsingDot(diameter: Self.diameter, tint: tint)
            .frame(width: Self.box, height: Self.box)
    }
}
