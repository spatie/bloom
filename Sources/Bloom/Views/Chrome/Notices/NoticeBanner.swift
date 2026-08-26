import SwiftUI
import BloomCore

/// One thing the app did on its own, in the corner of the window.
///
/// Deliberately not `ErrorBanner`. That one is red, it sits in the layout of the form that raised
/// it, and it stays until it is dismissed, because a failure that scrolls away is a failure nobody
/// acted on. This is the opposite kind of message: nothing went wrong, there is nothing to do, and
/// the only thing that would be worse than not saying it is saying it in a dialog.
///
/// It floats over the detail column instead of taking part in the layout, so the window does not
/// resize around a sentence that is about to leave.
///
/// **Everything it decides, it is told.** How long it stays, whether it leaves at all, where the
/// sentence about what happened stops and the sentence about why starts, and which words in it are
/// a machine's, are all `BloomNotice` in the core, where they are tested. What is left here is the
/// drawing and the pointer.
struct NoticeBanner: View {
    let notice: BloomNotice
    let onDismiss: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.fontScale) private var fontScale

    /// What is left of the notice's life, or nil for one that waits to be dismissed.
    @State private var remaining: Duration?
    /// How much of the bar is still to drain, held so a pause and a resume can restate it without
    /// asking Core Animation where it had got to.
    @State private var fraction: Double = 1
    /// Bumped whenever the countdown has to be restarted or stopped: a new notice, the pointer
    /// arriving, the pointer leaving. Both the sleep and the bar key on it.
    @State private var generation = 0
    @State private var isHeld = false
    /// When the sleep now running is due to finish, so a pause can work out what is left of it.
    /// Written by the countdown, read by `hold`.
    @State private var deadline: ContinuousClock.Instant?

    private var lifetime: Duration? { notice.lifetime }

    /// How wide the card is allowed to get.
    ///
    /// Off the spacing scale on purpose, because it is a measure rather than a gap: a banner holds
    /// a sentence and a sentence has a comfortable line length, and this is the same order as the
    /// transcript's own prose measure. Named because it was a bare 400 in a file where the two
    /// shadows below it carry a paragraph each.
    private static let cardWidth: CGFloat = 400

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: TranscriptLayout.cardInset) {
                Image(systemName: "info.circle.fill")
                    .font(Typo.label)
                    .foregroundStyle(Palette.accent)
                    // Nudged onto the first line's cap height rather than its box, which is where
                    // an SF Symbol beside a run of text otherwise sits a point proud.
                    .padding(.top, Metrics.spacingHair)
                    .accessibilityHidden(true)

                sentences

                Button("Dismiss", systemImage: "xmark", action: onDismiss)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .font(Typo.caption)
                    // Tertiary at rest and secondary under the pointer. The banner goes on its own,
                    // so the cross is a way out rather than the thing to do, and at full strength
                    // it was the heaviest mark in the box.
                    .foregroundStyle(isHeld ? Palette.textSecondary : Palette.textTertiary)
                    .help("Dismiss")
            }
            .padding(TranscriptLayout.cardInset)

            drain
        }
        .frame(maxWidth: Self.cardWidth, alignment: .leading)
        .background(Palette.surfaceRaised)
        .clipShape(RoundedRectangle(cornerRadius: Metrics.corner, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Metrics.corner, style: .continuous)
                .strokeBorder(Palette.border)
        )
        // Two shadows rather than one. The near one draws the edge, which is the whole of what
        // separates a white card from the white page under it in light; the far one is the depth,
        // and on its own at this radius it read as a smudge with no card in it.
        .shadow(color: .black.opacity(0.10), radius: 2, y: 1)
        .shadow(color: .black.opacity(0.16), radius: 16, y: 6)
        .padding(Metrics.gutter)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(notice.text.plain)
        .onHover { isHeld = $0 }
        .onChange(of: isHeld) { _, held in held ? hold() : release() }
        .task(id: generation) { await countdown() }
        // A new notice takes the place of whatever was showing, and takes a full reading time with
        // it rather than inheriting what was left of the last one's.
        .onChange(of: notice.id, initial: true) { _, _ in restart() }
        // Debug builds only, and it draws nothing: it is how a capture run holds the countdown
        // without the owner's cursor being moved for it. See `Snapshot`.
        .acceptsCaptureNoticeHold { isHeld = $0 }
    }

    /// The fact, then the reason, at two sizes.
    ///
    /// One box of text at one size is what made this read as a paragraph in a corner: the part that
    /// matters, which is what Bloom did, was the same weight as the part that explains it. The
    /// machine's own words inside either of them are set in mono, which is what mono means
    /// everywhere else in this window.
    private var sentences: some View {
        let text = notice.text
        return VStack(alignment: .leading, spacing: Metrics.spacingHair) {
            run(text.fact, rung: Typo.labelEmphasis)
                .foregroundStyle(Palette.textPrimary)

            if !text.reason.isEmpty {
                run(text.reason, rung: Typo.caption)
                    .foregroundStyle(Palette.textSecondary)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        // Worth pasting somewhere else, like every other message the app shows.
        .textSelection(.enabled)
    }

    /// One sentence, as a single attributed run.
    ///
    /// One `Text` rather than several added together, which is what this was: `Text.+` is
    /// deprecated on macOS 26, and a single string with a font per run wraps as one paragraph
    /// where a sum of `Text` is a sequence the layout is free to treat as pieces.
    ///
    /// `monospacedCompanion` rather than the mono rung of the same size, because mono at the same
    /// nominal size reads a size larger than the prose around it. That is the whole reason the
    /// companion exists; see `ScaledFont`.
    private func run(_ runs: [NoticeRun], rung: ScaledFont) -> Text {
        var sentence = AttributedString()
        for piece in runs {
            var part = AttributedString(piece.text)
            part.font = piece.isMachine
                ? rung.monospacedCompanion(scale: fontScale)
                : rung.resolved(scale: fontScale)
            sentence += part
        }
        return Text(sentence)
    }

    /// The time left, along the bottom edge.
    ///
    /// Nothing at all under Reduce Motion, and nothing for a notice that waits. A static bar in
    /// either case would be a clock stopped at the full hour: it would say a definite amount of
    /// time was left, and in the first case it is passing invisibly and in the second there is none
    /// to count. The notice still goes on its own under Reduce Motion; only the drawing of it does
    /// not move.
    @ViewBuilder
    private var drain: some View {
        if lifetime != nil, !reduceMotion {
            NoticeDrainBar(fraction: fraction, remaining: isHeld ? nil : remaining, generation: generation)
                // Three points, of which two are seen: the card's one point border is stroked over
                // the bottom of it. Measured off a capture, where a two point bar came out a
                // single point of teal under the rule and read as a scratch rather than a gauge.
                .frame(height: 3)
                .accessibilityHidden(true)
        }
    }

    private func restart() {
        remaining = lifetime
        fraction = 1
        generation += 1
    }

    /// The pointer arrived: bank what is left and stop.
    ///
    /// The standard courtesy, and the reason it is not optional here. This banner carries two
    /// branch names in a sentence about why they differ, which is exactly the message somebody
    /// stops to read twice, and having it vanish under the pointer mid read is worse than never
    /// having shown it.
    private func hold() {
        guard let lifetime, let remaining else { return }
        let started = ContinuousClock.now
        // What the sleep had already served, taken from the deadline the countdown recorded.
        let left = deadline.map { max(.zero, started.duration(to: $0)) } ?? remaining
        self.remaining = left
        fraction = lifetime > .zero ? left.seconds / lifetime.seconds : 0
        generation += 1
    }

    private func release() {
        guard remaining != nil else { return }
        generation += 1
    }

    private func countdown() async {
        guard !isHeld, let remaining, remaining > .zero else {
            deadline = nil
            return
        }
        deadline = .now + remaining
        try? await Task.sleep(for: remaining)
        guard !Task.isCancelled else { return }
        onDismiss()
    }
}
