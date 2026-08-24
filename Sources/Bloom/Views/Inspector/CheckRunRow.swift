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
    /// Six states, six shapes, and the shapes live in `CheckState` rather than here: see
    /// `CheckState.symbolName` for why that mapping is a decision the suite holds rather than one
    /// this view takes. Queued and running are both amber, because the strip above the list rolls
    /// both of them up into one amber "checks pending" and a row that argued with it would be
    /// noise. They are told apart the way every other glyph column in this window is told apart,
    /// by shape: a clock for a job nobody has picked up, and a filled disc for one a runner is
    /// executing.
    ///
    /// Nothing here moves any more. The running mark used to be a dashed ring turning once every
    /// three seconds, and the turn was never what made it findable: the dashes were, and there
    /// were not enough of them. A mark with the same ink as the tick beside it is found without
    /// motion, which is also what GitHub draws, so Reduce Motion now has nothing to switch off and
    /// the render server has nothing to composite for a branch with seven checks in flight.
    private var glyph: some View {
        let state = CheckState(run)
        return Image(systemName: state.symbolName)
            .foregroundStyle(tint(ink(for: state)))
            .font(Typo.label)
            .imageScale(.medium)
            .frame(width: InspectorLayout.glyphWidth, height: InspectorLayout.glyphWidth, alignment: .leading)
            .accessibilityLabel(state.description)
    }

    /// What each state is drawn in. The colour stays with the drawing, where `TurnEnding` leaves
    /// it: it is the shape that has to be right about all six at once, and that is next door in
    /// the core.
    private func ink(for state: CheckState) -> Color {
        switch state {
        case .queued, .running: Palette.warning
        case .passed: Palette.positive
        case .failed: Palette.negative
        case .skipped, .neutral: Palette.textTertiary
        }
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
