import SwiftUI
import BloomCore

/// One CI check: what it is, which workflow it came from, how long it took, and where to read it.
///
/// The fill is painted by `ChecksView`, the same way the other two inspector lists do it, so a row
/// that opens a URL gets the hover feedback that says it is clickable at all.
struct CheckRunRow: View {
    var run: CheckRun

    @Environment(\.isOnEmphasizedSelection) private var isOnSelection

    var body: some View {
        Button(action: open) {
            HStack(spacing: InspectorLayout.gap) {
                glyph
                // The workflow name is not repeated here. Every row in this list sits under a
                // pinned section header that is the workflow name, so seven rows of "Run tests"
                // under a heading reading "Run tests" said one thing eight times and cost the
                // name above it half its type size. The header is always on screen, which is
                // what makes dropping the line safe rather than lossy.
                Text(run.name)
                    .font(Typo.body)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: Metrics.spacingSmall)
                if let duration {
                    Text(duration)
                        .font(Typo.micro)
                        .monospacedDigit()
                        .foregroundStyle(Palette.textTertiary)
                }
                if run.detailsURL != nil {
                    Image(systemName: "arrow.up.right")
                        .font(Typo.micro)
                        .imageScale(.small)
                        .foregroundStyle(Palette.textTertiary)
                        .accessibilityHidden(true)
                }
            }
            // `ChecksView` insets the fill by the rest of the shared row inset, the way the
            // changed file list and the worktree tree do, so all three lists start on one line.
            .padding(.horizontal, InspectorLayout.gap)
            .frame(height: Metrics.rowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Not `.disabled`: a plain button dims everything inside it, so a run GitHub gave no URL
        // for came out unreadable rather than merely unclickable. Nothing to open simply opens
        // nothing.
        .help(run.detailsURL ?? run.name)
        .accessibilityInputLabels([run.name])
    }

    /// Every state occupies the same box, so a list of mixed results does not shuffle its names
    /// sideways as runs finish.
    ///
    /// Six states, six shapes. Queued and running are both amber, because the strip above the
    /// list rolls both of them up into one amber "checks pending" and a row that argued with it
    /// would be noise. They are told apart the way every other glyph column in this window is
    /// told apart, by shape: a clock for a job nobody has picked up, and a ring for one a runner
    /// is executing. That holds under Reduce Motion, where the ring stops and the shapes are all
    /// that is left.
    private var glyph: some View {
        Group {
            switch CheckState(run) {
            case .queued:
                Image(systemName: "clock")
                    .foregroundStyle(tint(Palette.warning))
            case .running:
                RunningRing(tint: tint(Palette.warning))
            case .passed:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(tint(Palette.positive))
            case .failed:
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(tint(Palette.negative))
            case .skipped:
                Image(systemName: "minus.circle")
                    .foregroundStyle(tint(Palette.textTertiary))
            case .neutral:
                Image(systemName: "circle")
                    .foregroundStyle(tint(Palette.textTertiary))
            }
        }
        .font(Typo.label)
        .imageScale(.medium)
        .frame(width: InspectorLayout.glyphWidth, height: InspectorLayout.glyphWidth)
        .accessibilityLabel(CheckState(run).description)
    }

    /// A pass/fail colour is unreadable on the accent fill, so a selected row hands the meaning
    /// back to the glyph's shape and borrows the row's own foreground.
    private func tint(_ colour: Color) -> Color {
        isOnSelection ? Palette.selectedEmphasizedText : colour
    }

    /// Nil until the run has both ends of its clock.
    private var duration: String? {
        guard let started = run.startedAt, let completed = run.completedAt else { return nil }
        let seconds = Int(completed.timeIntervalSince(started).rounded())
        guard seconds >= 0 else { return nil }
        if seconds < 60 { return "\(seconds)s" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m \(seconds % 60)s" }
        return "\(minutes / 60)h \(minutes % 60)m"
    }

    private func open() {
        guard let url = run.detailsURL else { return }
        GitHubBridge.open(url)
    }
}

/// The mark beside a check a runner is executing: a dashed ring, turning once every three seconds.
///
/// A ring rather than a `ProgressView`, which is what used to be here. A spinner is the shape this
/// app uses for one thing it is waiting on: a sheet, a workspace being set up, an attachment. A
/// branch routinely has seven checks in flight at once, and seven spinners in a 380 point column
/// is a machine room, not a list. GitHub draws the same event as a slowly turning dashed circle
/// for the same reason, and at three seconds a turn it reads as texture rather than as motion.
///
/// It costs nothing per frame. `rotationEffect` under a `repeatForever` animation is handed to
/// Core Animation once and interpolated by the render server, so the main thread evaluates this
/// body exactly twice in the life of a check: once when it appears and once when it finishes. The
/// list is lazy, so a row scrolled out of view is torn down and its animation with it, and the
/// tab only polls while it is on screen, so a pane nobody is looking at holds nothing at all.
private struct RunningRing: View {
    var tint: Color

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.controlActiveState) private var activeState

    @State private var turned = false

    /// Reduce Motion drops the turn rather than slowing it, which is what `ActivityDot` and the
    /// pane animations do. Nothing is lost: the ring is still a ring, and it is still the only
    /// amber shape in the column that is not a clock.
    ///
    /// It also stops when the window is not the front one. A check that runs for twenty minutes
    /// behind a browser is twenty minutes of the render server compositing a ring nobody is
    /// reading, and the state is unchanged when the window comes back.
    private var isTurning: Bool {
        turned && !reduceMotion && activeState != .inactive
    }

    var body: some View {
        Image(systemName: "circle.dashed")
            .foregroundStyle(tint)
            .rotationEffect(.degrees(isTurning ? 360 : 0))
            .animation(
                isTurning ? .linear(duration: 3).repeatForever(autoreverses: false) : .default,
                value: isTurning
            )
            .onAppear { turned = true }
    }
}
