import SwiftUI
import BloomCore

/// A busy sweep in a SwiftUI layout: the layer while a turn runs and while it fades out, nothing
/// otherwise, and nothing that moves under Reduce Motion.
///
/// **Nothing, while idle.** A strip of ten idle tabs is ten empty `ZStack`s: no `NSView`, no layer
/// and no animation. The layer view is built when a turn starts and taken away once its fade out
/// has finished, which `BusySweepView` reports rather than this guessing at a duration.
///
/// Hit testing nothing and hidden from VoiceOver. The band sits behind a tab's label, under its
/// close button, its rename field and the press that starts a drag, and it must take none of them;
/// what it says is said to VoiceOver by the tab's own `accessibilityValue`.
///
/// Under Reduce Motion this draws nothing at all. A tab's still tint is the tab's background to
/// draw (`TabItemView`), and the column's is `ColumnBusySignal`'s.
struct BusySweepBand: View {
    var figure: BusySweepFigure
    var isActive: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Whether the layer view exists: true from a start until its fade out has finished.
    @State private var isMounted = false
    /// Whether the view was already busy when it appeared, which is not a turn starting.
    @State private var arrivesLit = false

    var body: some View {
        ZStack {
            if isMounted && !reduceMotion {
                BusySweepLayer(figure: figure, isActive: isActive, arrivesLit: arrivesLit) {
                    if !isActive { isMounted = false }
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onChange(of: isActive, initial: true) { was, active in
            if was == active {
                // The initial call.
                isMounted = active
                arrivesLit = active
            } else if active {
                if !isMounted { arrivesLit = false }
                isMounted = true
            }
            // A stop leaves the view mounted: it fades itself out and says when it has.
        }
    }
}

/// The busy signal along the top of a column with no tab strip.
///
/// The segment, 2.5 points tall with nothing behind it. Under Reduce Motion, a wash of house blue
/// falling off from the column's top edge over `BusySweep.columnStillHeight`, fading in and out
/// rather than moving: a still segment in the moving one's place would be a hard blue line under
/// the title bar, which is what the owner reported the crest as. See `BusySweep.columnStill`.
struct ColumnBusySignal: View {
    var isActive: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if reduceMotion {
                ZStack {
                    if isActive {
                        LinearGradient(
                            colors: [Palette.busyColumnStill, Palette.busyColumnStill.opacity(0)],
                            startPoint: .top, endPoint: .bottom
                        )
                        .transition(.opacity)
                    }
                }
                .frame(height: BusySweep.columnStillHeight)
                .animation(.easeInOut(duration: BusySweep.fade), value: isActive)
            } else {
                BusySweepBand(figure: .column, isActive: isActive)
                    .frame(height: BusySweep.columnThickness)
            }
        }
        .frame(maxWidth: .infinity)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// One frame of a sweep, drawn in SwiftUI, for a gallery.
///
/// `ImageRenderer` paints its yellow placeholder over an `NSViewRepresentable`, so the moving layer
/// cannot be photographed offscreen. This is the same band at one point through its crossing,
/// from the same figures, so the picture is the window's rather than a sketch of it.
struct BusySweepStill: View {
    var figure: BusySweepFigure
    /// The track's width, handed in rather than measured: a gallery knows it.
    var width: CGFloat
    /// How far through the crossing, after easing, from 0 to 1.
    var progress: Double

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let shape = figure.band
        let peak = figure == .tab ? BusySweep.tabBand.member(dark: colorScheme == .dark) : 1
        let gradient = LinearGradient(
            stops: shape.stops.map {
                Gradient.Stop(color: Palette.accentFill.opacity(peak * $0.strength), location: $0.location)
            },
            startPoint: .leading, endPoint: .trailing
        )
        let bandWidth = width * shape.widthShare
        return ZStack(alignment: .leading) {
            if figure == .column {
                Capsule().fill(gradient).frame(width: bandWidth)
            } else {
                Rectangle().fill(gradient).frame(width: bandWidth)
            }
        }
        .offset(x: width * shape.leadingEdge(at: progress))
        .frame(width: width, alignment: .leading)
        .clipped()
        .allowsHitTesting(false)
    }
}
