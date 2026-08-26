import SwiftUI
import BloomCore

/// The three figures the activity rule could draw, at the width it is read at, moving and held
/// still.
///
/// This rule has now been redrawn twice, and both times the argument was settled by putting the
/// candidates side by side rather than by describing them. The first set was drawn in a browser and
/// thrown away, which is why the second round started from nothing: the reasoning survived in
/// `BusyRule`'s header and the pictures did not. This page is the pictures, kept.
///
/// **Photograph it with `Bloom --snapshot-gallery <dir> --gallery activity-rule`.** No `--running`
/// is needed, unlike `running-glyph`: this page draws `ActivityRuleFigure` directly, which has no
/// opinion about whether a turn is under way, so the moving rows move whether or not the heartbeat
/// has been started. They all read the same epoch, so they are in step with each other on the page
/// the way they are in the window.
///
/// The page is also in `--snapshot`'s offscreen list, as `activity-rule-still`, and that picture is
/// not a placeholder: the still figure is plain SwiftUI precisely so an agent can photograph what
/// `Reduce Motion` draws without asking to film the owner's screen. What the offscreen pass cannot
/// show is the moving rows, which come out as SwiftUI's yellow placeholder there and are the whole
/// reason this page also has a window path.
struct ActivityRuleGallery: View {
    /// The centre column's rule at a window somebody would actually work in. The strip is as wide
    /// as the transcript under it, which is the width the complaint was made at.
    private static let columnWidth: CGFloat = 760
    /// The other rule in the window, and the narrow case: a crest is 190 points and this is 380.
    private static let inspectorWidth: CGFloat = 380

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Activity rule")
                    .font(Typo.title)
                Text("What the line under the tab strip says while an agent is working.")
                    .font(Typo.label)
                    .foregroundStyle(Palette.textSecondary)
            }

            ForEach(BusyRuleVariant.allCases, id: \.self) { variant in
                section(variant)
            }

            beside
            enlarged
            narrow
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: One variant

    private func section(_ variant: BusyRuleVariant) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(variant.title)
                    .font(Typo.label)
                if variant == .live {
                    Chip(text: "In the window")
                }
            }
            Text(variant.note)
                .font(Typo.micro)
                .foregroundStyle(Palette.textSecondary)

            strip(variant, isMoving: true, caption: "Working")
            // The row that decides an accessibility setting rather than a taste: with motion off
            // the mark has to stay a mark. A figure that is only legible while it moves is a figure
            // that says nothing to the reader who most needs it to.
            strip(variant, isMoving: false, caption: "Reduce Motion")
        }
    }

    /// One tab strip's worth of chrome with the rule closing it off, which is where this line
    /// actually lives. Drawn from the same pieces the strip is, so the page cannot disagree with
    /// the window about what is under the rule.
    private func strip(
        _ variant: BusyRuleVariant,
        isMoving: Bool,
        caption: String,
        width: CGFloat = ActivityRuleGallery.columnWidth
    ) -> some View {
        HStack(alignment: .bottom, spacing: 10) {
            ZStack(alignment: .bottom) {
                Palette.sidebar
                Hairline()
                ActivityRuleFigure(variant: variant, isMoving: isMoving)
            }
            .frame(width: width, height: 26)

            Text(caption)
                .font(Typo.micro)
                .foregroundStyle(Palette.textTertiary)
        }
    }

    // MARK: The cases the complaint was made in

    /// The rule with the accent fill directly under it.
    ///
    /// The report was made at the bottom of a long transcript, where the nearest large piece of
    /// colour is a user's own message in `Palette.accentFill`. A mark in the accent an inch above a
    /// block of the accent is the one place a green line can be lit and still not be seen, so it is
    /// a row on this page rather than something to find out later.
    private var beside: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Above a user's message")
                .font(Typo.label)
            strip(.live, isMoving: true, caption: "Working")
            HStack {
                Spacer(minLength: 0)
                Text("Have another look at the transcript stutter")
                    .font(Typo.body)
                    .foregroundStyle(Palette.textInverted)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Palette.accentFill, in: RoundedRectangle(cornerRadius: 12))
            }
            .frame(width: ActivityRuleGallery.columnWidth)
        }
    }

    /// The crest at four times, so the profile can be read rather than inferred.
    ///
    /// Held still, and not because the moving one could not be scaled: the still figure is the one
    /// with a claim to answer. It is what `Reduce Motion` draws, and the claim is that a shape with
    /// a short face and a long tail says which way it is going without moving at all.
    private var enlarged: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("The crest, four times, held still")
                .font(Typo.label)
            Text("Head at the trailing edge, tail behind it. Direction, in one frame.")
                .font(Typo.micro)
                .foregroundStyle(Palette.textSecondary)
            ZStack(alignment: .bottom) {
                Palette.sidebar
                ActivityRuleFigure(variant: .crest, isMoving: false)
                    .frame(width: BusyCrest.length, height: BusyCrest.thickness)
                    .scaleEffect(4, anchor: .bottom)
                    .frame(width: BusyCrest.length * 4, height: BusyCrest.thickness * 4)
            }
            .frame(width: ActivityRuleGallery.columnWidth, height: 40)
        }
    }

    /// The inspector's segment, which is the narrow case and the one a crest could overrun.
    private var narrow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("The inspector's segment of the same rule")
                .font(Typo.label)
            Text("380 points against a crest of 190, and both rules cross on one clock.")
                .font(Typo.micro)
                .foregroundStyle(Palette.textSecondary)
            strip(
                .live, isMoving: true, caption: "Working",
                width: ActivityRuleGallery.inspectorWidth
            )
            strip(
                .live, isMoving: false, caption: "Reduce Motion",
                width: ActivityRuleGallery.inspectorWidth
            )
        }
    }
}

extension Gallery {
    /// The registry entry for this page. See `Gallery`.
    ///
    /// It moves and still does not need the keys: nothing on it is a text field, and the heartbeat
    /// has no frontmost gate, so it runs in a window nobody has given the keyboard to.
    static let activityRule = Gallery(
        name: "activity-rule",
        title: "Activity rule",
        size: CGSize(width: 900, height: 1000),
        needsFocus: false,
        view: { _ in AnyView(ActivityRuleGallery()) }
    )
}
