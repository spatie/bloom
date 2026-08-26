import SwiftUI

/// The floating "you are not at the end" affordance, drawn inside the transcript above its bottom
/// edge. `ChatPaneView` places it and says why it is not on the composer any more.
///
/// It answers one question, and only one: the transcript has moved on below where you are reading,
/// take me back to it. So it appears when the view is away from the live end and at no other time,
/// and it goes as soon as the end is reached again.
///
/// It used to say "Next unread (64)" and it used to be shown whenever the session held anything
/// unread, which is a different claim and was not one the window could support. Unread is what the
/// sidebar bolds, what the Dock badge counts and what the menu bar item sums, and all three are
/// about workspaces you are NOT looking at. Inside the conversation you are looking at, everything
/// on screen has been seen by definition, and a count in the sixties for rows that had scrolled
/// past under the pointer read as a backlog rather than as a hint. The number is gone with it:
/// how far behind you are does not change what the button does or whether you want it.
///
/// # Why it is not the accent colour any more
///
/// **It was `accentFill`, and so is the user's own bubble.** Same value, `0x197593`, so a pill
/// floating over a bubble was the bubble's own colour on the bubble's own ground, with a corner of
/// each showing past the other. Captured over a two-line prompt and the two shapes read as one
/// piece of torn content.
///
/// Picking a second brand hue would have been the wrong repair, because every hue in this palette
/// already means something: the accent is activity, `warning` and `negative` are outcomes,
/// `merged` is a state a branch reaches. A floating button that takes you somewhere is none of
/// those, and a new hue for it would be a new meaning nobody could read.
///
/// So it is chrome rather than content: a raised surface, a hairline, the window's own label
/// colour, and a shadow doing the work of saying it is above the conversation rather than in it.
/// That is what the rest of the window's floating controls are made of, it cannot collide with a
/// bubble, and it cannot collide with whatever the next thing drawn in the transcript turns out to
/// be either.
struct JumpToNewestPill: View {
    var action: @MainActor () -> Void

    @State private var isHovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// How far the arrow dips when the pointer arrives.
    ///
    /// Two points, which is under the width of the glyph's own stem. The gesture is meant to be
    /// read as the button confirming which way it goes rather than as an animation being played,
    /// and anything past this reads as the arrow falling out of the capsule.
    private static let arrowDip: CGFloat = 2

    var body: some View {
        Button(action: action) {
            HStack(spacing: Metrics.spacingSmall) {
                Image(systemName: "arrow.down")
                    // The one moving part. It answers "where does this take me" in the direction
                    // it takes you, which a label cannot do and a colour certainly cannot.
                    .offset(y: isHovering ? Self.arrowDip : 0)
                Text("Jump to newest")
            }
            .font(Typo.captionEmphasis)
            .foregroundStyle(Palette.textPrimary)
            .padding(.horizontal, Metrics.gutter)
            .padding(.vertical, Metrics.spacingSmall + Metrics.spacingTight)
        }
        // A plain button, and then the whole surface is drawn here. `borderedProminent` was what
        // tinted it, and a tint is exactly what this must not have; `bordered` in a window that is
        // not the active one is drawn with no fill at all, which put a black label and a hairline
        // of grey over a paragraph and read as a smear. Captured, and unreadable at a glance.
        .buttonStyle(.plain)
        .background {
            Capsule()
                .fill(Palette.surfaceRaised)
                // The hover response, on the ground rather than on the label, so the words do not
                // change weight under the pointer.
                .overlay(Capsule().fill(isHovering ? Palette.hover : .clear))
                .overlay(Capsule().strokeBorder(Palette.border, lineWidth: Metrics.hairline))
        }
        .clipShape(Capsule())
        // It grows on hover because that is what says the thing is floating: a control that only
        // changed its fill reads as a patch of the transcript lighting up. The two states are the
        // two rungs of `Elevation` rather than six numbers written here, which is where the
        // window's third and fourth shadow recipes came from.
        .elevation(isHovering ? .lifted : .resting)
        .onHover { isHovering = $0 }
        // One length for the whole response, and it is the window's hover speed rather than a
        // literal of this file's own: the shadow, the wash and the arrow are one gesture and must
        // not arrive at three different times. Reduce Motion keeps every one of the states above
        // and drops only the travel between them.
        .animation(reduceMotion ? nil : Motion.hover, value: isHovering)
        .help("Jump to the newest row")
    }
}
