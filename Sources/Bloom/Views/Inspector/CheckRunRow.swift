import SwiftUI
import BloomCore

/// One CI check: what it is, which workflow it came from, how long it took, and where to read it.
///
/// The fill is painted by `ChecksView`, the same way the other two inspector lists do it, so a row
/// that opens a URL gets the hover feedback that says it is clickable at all.
struct CheckRunRow: View {
    var run: CheckRun
    /// Whether the pointer is on this row, which is what puts the hand-off button up. Passed down
    /// rather than sensed here, because `ChecksView` already tracks it to paint the fill and two
    /// hover states on one row would disagree at the edges.
    var isHovered = false
    /// True while this row's own failure is being fetched. Nil hides the button altogether, which
    /// is what a passing check and a workspace with no conversation both get.
    var isSending = false
    var onSend: (@MainActor () -> Void)?

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
                if let onSend, isHovered || isSending {
                    send(onSend)
                }
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
        // The hover button's action, offered again where a Mac user goes looking for what a row
        // can do. `onSend` is nil on a check that passed and on a workspace with no conversation
        // to send anything to, and this offers nothing in either case, exactly as the button does,
        // so the two cannot disagree about when it is available.
        //
        // Not in the menu bar: this acts on one check run out of a list of them, and a menu bar
        // item would have to guess which. The row's own menu is where the answer is already known.
        .contextMenu {
            if let onSend {
                Button("Send This Failure to the Agent", action: onSend)
                    .disabled(isSending)
            }
        }
    }

    /// The one action a failed check offers: start the next turn with this failure in it.
    ///
    /// On hover rather than always, for the reason the diff list's own row buttons are: a column
    /// 380 points wide with a control on every row reads as a toolbar, and this is only ever
    /// offered on the runs that failed, which is a minority of any healthy branch. The row it sits
    /// in is itself a button, and a nested one is why this is `.plain` with its own content shape:
    /// the press has to stop here rather than also opening the run in a browser.
    private func send(_ action: @escaping @MainActor () -> Void) -> some View {
        Button(action: action) {
            Group {
                if isSending {
                    ProgressView()
                        .controlSize(.mini)
                } else {
                    Image(systemName: "text.bubble")
                        .font(Typo.micro)
                        .imageScale(.medium)
                        .foregroundStyle(isOnSelection ? Palette.selectedEmphasizedText : Palette.textSecondary)
                }
            }
            .frame(width: Metrics.glyph, height: Metrics.glyph)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isSending)
        .help("Start a turn with this failure and its log")
        .accessibilityLabel("Send this failure to the agent")
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
        .frame(width: InspectorLayout.glyphWidth, height: InspectorLayout.glyphWidth, alignment: .leading)
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
