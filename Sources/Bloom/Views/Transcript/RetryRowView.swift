import SwiftUI
import BloomCore

/// A turn that is alive and waiting out somebody else's outage.
///
/// **This is not an error row and must never look like one.** The transcript already has a drawing
/// for a turn that failed, in the negative red, and it is correct: it appears when the CLI has run
/// out of attempts and stopped. What was missing is everything before that. During three minutes
/// and fourteen seconds of 529s the tail said "Requesting" beside a live dot and never changed,
/// which is indistinguishable from a hang, and the owner reasonably read it as one.
///
/// So the row borrows the window's vocabulary for waiting rather than its vocabulary for failure:
/// the drain bar the notice toast uses, and the tertiary ink a pending row is drawn in. Nothing
/// here is red.
///
/// # It escalates by changing shape, not only by changing words
///
/// Attempt 1 of 10 six hundred milliseconds in is not news, and a plate with a border around it
/// would be a claim that something has gone wrong. Attempt 9 of 10 two and a half minutes in is a
/// turn that will probably fail, and somebody deciding whether to keep waiting needs to see it
/// from across the room. So the first band is a plain row like any other, and the later two lift
/// onto a washed plate in the warning tint. A person who looks up after two minutes sees a
/// different object, not a longer sentence in the same one. `RetryPatience` decides which band it
/// is in, in the core, where it can be tested.
///
/// # Three things move, and none of them is a countdown
///
/// The attempt number changes on every announcement. The drain empties over exactly
/// `retry_delay_ms` and restarts when the next attempt fails, so the wait has a shape. The glyph
/// breathes on the window's own heartbeat. What is deliberately absent is a ticking figure: see
/// `AgentRetry.waitPhrase` for why counting down to the next attempt would be counting down to
/// the wrong thing.
struct RetryRowView: View {
    var run: RetryRun
    /// Draws without motion for the snapshot run, which has no window to run an animation in.
    var isStill = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var retry: AgentRetry { run.latest }

    /// Quiet while it is only settling, and the warning tint once it has been at this a while.
    /// Never `negative`: the turn has not failed, and half the point of the row is saying so.
    private var tint: Color {
        run.patience == .settling ? Palette.textTertiary : Palette.warning
    }

    /// Whether the row lifts onto a plate of its own. The shape change is the escalation.
    private var isRaised: Bool { run.patience != .settling }

    private var sentence: String {
        [retry.note, retry.waitPhrase].compactMap { $0 }.joined(separator: " ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: TranscriptLayout.tight) {
            header
            Text(sentence)
                .font(Typo.caption)
                .foregroundStyle(Palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: TranscriptLayout.proseMeasure, alignment: .leading)
                // Under the headline rather than under the glyph, so the two lines read as one
                // block instead of as a row with a caption parked beside it.
                .padding(.leading, TranscriptLayout.glyphWidth + TranscriptLayout.glyphGap)

            // Its own rung of air above it. Set at the block spacing the sentence uses, the bar sat
            // hard under the last line of the sentence and read as an underline of it rather than
            // as a clock.
            drain
                .padding(.top, TranscriptLayout.tight)
                .padding(.leading, TranscriptLayout.glyphWidth + TranscriptLayout.glyphGap)
        }
        .padding(isRaised ? TranscriptLayout.tight : 0)
        .background {
            if isRaised {
                RoundedRectangle(cornerRadius: Metrics.corner)
                    .fill(Palette.warning.opacity(0.07))
                    .overlay {
                        RoundedRectangle(cornerRadius: Metrics.corner)
                            .strokeBorder(Palette.warning.opacity(0.28), lineWidth: Metrics.hairline)
                    }
            }
        }
        .padding(.horizontal, TranscriptLayout.inset)
        .padding(.vertical, TranscriptLayout.inset)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(retry.headline). \(sentence)")
    }

    private var header: some View {
        HStack(spacing: TranscriptLayout.glyphGap) {
            TranscriptGlyph(symbol: "arrow.trianglehead.clockwise", tint: tint)
                .modifier(BreathingOpacity(isActive: !isStill && !reduceMotion))

            Text(retry.headline)
                .font(Typo.label)
                .foregroundStyle(Palette.textSecondary)
                .lineLimit(1)

            Spacer(minLength: TranscriptLayout.tight)

            // The one figure that is always on screen, because it is the one that moves on its
            // own. Monospaced digits so "9 of 10" arriving after "8 of 10" does not shift the row.
            Text("\(retry.attempt) of \(retry.maxAttempts)")
                .font(Typo.caption)
                .monospacedDigit()
                .foregroundStyle(tint)
                .fixedSize()
        }
    }

    /// The wait itself, as a shape. Left anchored and draining, which is the notice toast's own
    /// bar and the same argument: a bar that fills is a job being done, a bar that empties is time
    /// being spent, and this is time being spent.
    ///
    /// Keyed on the attempt, so each announcement restarts it over that attempt's own delay. A
    /// wait too short to see (the first backoffs are around half a second) draws the track and
    /// nothing else, which is correct: there is nothing to watch.
    ///
    /// The still drawing is a plain shape rather than the layer, and not only to hold a
    /// photograph: `ImageRenderer` paints an `NSViewRepresentable` as a yellow placeholder
    /// offscreen, so the one page that exists to show this row would have shown a yellow bar.
    @ViewBuilder
    private var drain: some View {
        Group {
            // `isStill` is a snapshot-capture flag, not an accessibility one, and it was the only
            // gate here: the file reads `accessibilityReduceMotion` at the top and applies it to
            // the breathing glyph above, then handed the drain bar an ungated `remaining:`. During
            // an upstream outage that bar empties and restarts for minutes in the reading column.
            // `NoticeBanner` guards the identical component correctly, and the still branch below
            // already draws a correct frozen bar.
            if isStill || reduceMotion {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(tint.opacity(0.12))
                        Capsule().fill(tint.opacity(0.6))
                            .frame(width: proxy.size.width * 0.62)
                    }
                }
            } else {
                NoticeDrainBar(
                    fraction: 1,
                    remaining: .seconds(retry.delay),
                    generation: retry.attempt,
                    tint: tint
                )
            }
        }
        .frame(height: Metrics.hairline * 2)
        .frame(maxWidth: TranscriptLayout.proseMeasure, alignment: .leading)
    }
}

/// The glyph breathing on the window's heartbeat, so a retrying turn reads as alive.
///
/// `BusyBreath`'s envelope rather than a sine, and sampled through the same keyframes the sidebar's
/// running mark uses, so a workspace that is retrying breathes in step with every other mark in
/// the window rather than starting a rhythm of its own. Opacity only: the glyph must not change
/// size, because a symbol that grows and shrinks at this size reads as a focus problem.
private struct BreathingOpacity: ViewModifier {
    var isActive: Bool

    func body(content: Content) -> some View {
        if isActive {
            content.keyframeAnimator(
                initialValue: 1.0,
                repeating: true
            ) { view, value in
                view.opacity(value)
            } keyframes: { _ in
                KeyframeTrack {
                    for sample in BusyBreath.samples(count: 12) {
                        LinearKeyframe(0.45 + 0.55 * sample, duration: BusyBreath.period / 12)
                    }
                }
            }
        } else {
            content
        }
    }
}
