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
    /// The narrow case: a crest is 190 points and this is 380. It is also the width the inspector
    /// used to light, which is what the last row on this page is a record of.
    private static let narrowWidth: CGFloat = 380

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
            twoSegments
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

    /// A narrow centre column, which is the case a crest could overrun.
    ///
    /// The column is what is left of the window after the sidebar and the inspector, so it is at
    /// its narrowest with both of those at their widest. 380 points is well past that and is here
    /// because it is the width the two crest defect below was reported at.
    private var narrow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("A narrow column")
                .font(Typo.label)
            Text("380 points against a crest of 190. The tail clips; the head does not.")
                .font(Typo.micro)
                .foregroundStyle(Palette.textSecondary)
            strip(
                .live, isMoving: true, caption: "Working",
                width: ActivityRuleGallery.narrowWidth
            )
            strip(
                .live, isMoving: false, caption: "Reduce Motion",
                width: ActivityRuleGallery.narrowWidth
            )
        }
    }

    /// What the window drew instead, for a fortnight, and what was wrong with it.
    ///
    /// The rule ran on two segments, the centre column's and the inspector's, off one epoch. The
    /// report was "there seems to be two going, one in middle pane, one in right". Drawn here
    /// because the fix was to delete the second one, and a defect fixed by a deletion leaves
    /// nothing behind to look at: the next person to propose lighting the inspector's half should
    /// see what it did before proposing it.
    ///
    /// Both halves are correct on their own terms, and that is the point. They share a period, so
    /// they set off together and finish together, and because they are different lengths they cross
    /// at different speeds. Watch either one and it is right. Watch the pair and there are two.
    private var twoSegments: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("What it did with the inspector's half lit")
                .font(Typo.label)
            Text("One period, two lengths, two speeds. Reported as two bubbles, and deleted.")
                .font(Typo.micro)
                .foregroundStyle(Palette.textSecondary)
            HStack(alignment: .bottom, spacing: 0) {
                segment(width: ActivityRuleGallery.columnWidth - ActivityRuleGallery.narrowWidth)
                // The split divider, which is what the pair were meant to read as passing behind.
                Rectangle()
                    .fill(Palette.border)
                    .frame(width: Metrics.hairline, height: 26)
                segment(width: ActivityRuleGallery.narrowWidth)
            }
        }
    }

    /// One lit segment with no caption beside it, for the row that draws two of them touching.
    private func segment(width: CGFloat) -> some View {
        ZStack(alignment: .bottom) {
            Palette.sidebar
            Hairline()
            ActivityRuleFigure(variant: .live, isMoving: true)
        }
        .frame(width: width, height: 26)
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
        size: CGSize(width: 900, height: 1120),
        needsFocus: false,
        view: { _ in AnyView(ActivityRuleGallery()) }
    )
}
