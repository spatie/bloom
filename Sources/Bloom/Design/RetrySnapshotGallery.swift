import SwiftUI
import BloomCore

/// Every state of the retry surface on one page, so the escalation can be looked at rather than
/// argued about.
///
/// The numbers are the real ones out of `Tests/fixtures/claude-api-retry.ndjson`: the attempts and
/// their backoffs are what `claude` 2.1.241 actually did during the outage, so the page shows the
/// wait growing from six hundred milliseconds to nearly forty seconds the way it really does.
///
/// **A window rather than `ImageRenderer`.** The drain under each row is `NoticeDrainBar`, which is
/// a layer behind an `NSViewRepresentable`, and offscreen SwiftUI paints those as a yellow
/// placeholder. So this page is captured through `--snapshot-gallery <dir> --gallery retries`,
/// which puts it in a real window and asks the window server for it, the same route the review
/// comment box takes for the same reason.
struct RetrySnapshotGallery: View {
    private static func retry(_ attempt: Int, _ delay: TimeInterval, status: Int = 529) -> AgentRetry {
        AgentRetry(attempt: attempt, maxAttempts: 10, delay: delay, status: status)
    }

    private static func run(_ attempt: Int, _ delay: TimeInterval, status: Int = 529) -> RetryRun {
        RetryRun(retry(attempt, delay, status: status))
    }

    var body: some View {
        // No `ScrollView`. Offscreen it has no proposed height to lay itself out against and the
        // whole page renders blank, which is what the first photograph of this file was.
        VStack(alignment: .leading, spacing: 20) {
                group("What it used to say, for three minutes and fourteen seconds") {
                    StreamingStatusView(glyph: nil, text: "Requesting")
                }

                group("Attempt 1 of 10, six hundred milliseconds in. Not news yet.") {
                    RetryRowView(run: Self.run(1, 0.6), isStill: true)
                }

                group("Attempt 5 of 10. It lifts onto a plate: a different object, not a longer sentence.") {
                    RetryRowView(run: Self.run(5, 8.757), isStill: true)
                }

                group("Attempt 9 of 10, two and a half minutes in.") {
                    RetryRowView(run: Self.run(9, 37.186), isStill: true)
                }

                group("A 429 rather than a 529. Same shape, different diagnosis.") {
                    RetryRowView(run: Self.run(6, 19.5, status: 429), isStill: true)
                }

                group("Nothing came back at all, which may be this machine.") {
                    RetryRowView(
                        run: RetryRun(AgentRetry(
                            attempt: 4, maxAttempts: 10, delay: 12, status: nil, category: "timeout"
                        )),
                        isStill: true
                    )
                }

                group("And what is left under the turn once it got through.") {
                    Text(recovered.recoveredSentence)
                        .font(Typo.caption)
                        .foregroundStyle(Palette.textTertiary)
                        .padding(.horizontal, TranscriptLayout.inset)
                }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Palette.windowBackground)
    }

    private var recovered: RetryRun {
        var run = Self.run(1, 0.6)
        run.absorb(Self.retry(4, 4.7))
        return run
    }

    @ViewBuilder
    private func group(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(Typo.caption)
                .foregroundStyle(Palette.textTertiary)
            content()
        }
    }
}

extension Gallery {
    /// The registry entry for this page. See `Gallery`.
    static let retries = Gallery(
        name: "retries",
        title: "Retries",
        size: CGSize(width: 860, height: 1_020),
        needsFocus: false,
        view: { _ in AnyView(RetrySnapshotGallery()) }
    )
}
