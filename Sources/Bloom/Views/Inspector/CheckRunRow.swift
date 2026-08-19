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
                VStack(alignment: .leading, spacing: 0) {
                    Text(run.name)
                        .font(Typo.body)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let workflow = run.workflowName, workflow != run.name {
                        Text(workflow)
                            .font(Typo.caption)
                            .foregroundStyle(Palette.textTertiary)
                            .lineLimit(1)
                    }
                }
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
    private var glyph: some View {
        Group {
            switch CheckState(run) {
            case .running:
                ProgressView()
                    .controlSize(.mini)
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
