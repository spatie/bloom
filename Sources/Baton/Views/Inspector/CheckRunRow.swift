import SwiftUI
import BatonCore

/// One CI check: what it is, which workflow it came from, how long it took, and where to read it.
struct CheckRunRow: View {
    var run: CheckRun

    var body: some View {
        Button(action: open) {
            HStack(spacing: InspectorLayout.gap) {
                glyph
                VStack(alignment: .leading, spacing: 0) {
                    Text(run.name)
                        .font(Typo.label)
                        .foregroundStyle(Palette.textPrimary)
                        .lineLimit(1)
                    if let workflow = run.workflowName, workflow != run.name {
                        Text(workflow)
                            .font(Typo.micro)
                            .foregroundStyle(Palette.textTertiary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: InspectorLayout.tight * 2)
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
            .padding(.horizontal, InspectorLayout.inset)
            .frame(height: Metrics.rowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(run.detailsURL == nil)
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
                    .foregroundStyle(Palette.positive)
            case .failed:
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(Palette.negative)
            case .skipped:
                Image(systemName: "minus.circle")
                    .foregroundStyle(Palette.textTertiary)
            case .neutral:
                Image(systemName: "circle")
                    .foregroundStyle(Palette.textTertiary)
            }
        }
        .font(Typo.label)
        .imageScale(.medium)
        .frame(width: InspectorLayout.glyphWidth, height: InspectorLayout.glyphWidth)
        .accessibilityLabel(CheckState(run).description)
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
