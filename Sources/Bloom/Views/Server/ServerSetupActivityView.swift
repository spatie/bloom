import SwiftUI
import AppKit
import BloomCore

/// Steps remain visible while native, selectable output fills the rest of the window.
struct ServerSetupActivityView: View {
    let activity: ServerSetupActivity
    let failure: ServerSetupFailure?
    @State private var copiedOutput = false

    var compact = false
    var stages = ServerSetupActivity.Stage.allCases
    private var visibleStages: [ServerSetupActivity.Stage] { stages.filter { activity.status(of: $0) != .skipped } }
    /// The left column takes the extra stage when the count is odd.
    private var stageColumns: [[ServerSetupActivity.Stage]] {
        let split = (visibleStages.count + 1) / 2
        return [Array(visibleStages.prefix(split)), Array(visibleStages.dropFirst(split))]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.gutter) {
            if compact {
                // The failure and the stages take their natural height and the output pane gives
                // way. They used to share a scroll view capped at 180 points, so a two line failure
                // clipped the stages mid row while the output below sat half empty. The output's
                // lines are also in Copy Output and in the failure's Copy Error, so it is the part
                // that can afford to shrink.
                if let failure { ServerSetupFailureView(failure: failure).fixedSize(horizontal: false, vertical: true) }
                // Down the left column and then down the right, because the stages run in that
                // order. A grid fills across, which ticked them off left, right, left.
                HStack(alignment: .top, spacing: Metrics.gutter) {
                    ForEach(Array(stageColumns.enumerated()), id: \.offset) { _, column in
                        VStack(alignment: .leading, spacing: Metrics.spacing) {
                            ForEach(column) { stage in stageRow(stage) }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                output
            } else {
                if let failure { ServerSetupFailureView(failure: failure) }
                HStack(alignment: .top, spacing: Metrics.gutter * 2) {
                    VStack(alignment: .leading, spacing: Metrics.gutter) {
                        ForEach(visibleStages) { stage in stageRow(stage) }
                        Spacer(minLength: 0)
                    }
                    .frame(width: 185, alignment: .leading)
                    output
                }
                .frame(maxHeight: .infinity)
            }
        }
        .task(id: copiedOutput) {
            guard copiedOutput else { return }
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            copiedOutput = false
        }
    }

    private func stageRow(_ stage: ServerSetupActivity.Stage) -> some View {
        HStack(alignment: .top, spacing: Metrics.spacing) {
            statusIcon(activity.status(of: stage)).frame(width: 16)
            Text(stage.title)
                .font(activity.status(of: stage) == .running ? Typo.labelEmphasis : Typo.label)
                .foregroundStyle(activity.status(of: stage) == .pending || activity.status(of: stage) == .skipped ? Palette.textTertiary : Palette.textPrimary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(String(describing: activity.status(of: stage)))
    }

    private var output: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing) {
            HStack {
                Text("Server output").font(Typo.captionEmphasis)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(activity.output, forType: .string)
                    copiedOutput = true
                } label: { Text(copiedOutput ? "Copied" : "Copy Output").font(Typo.caption) }
                .buttonStyle(.bordered).controlSize(.small).help("Copy server output").accessibilityLabel("Copy server output")
            }
            ServerSetupOutputView(lines: activity.lines)
                .frame(minHeight: compact ? 120 : 240, maxHeight: .infinity)
            if failure == nil {
                Text(activity.currentMessage)
                    .font(Typo.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle).help(activity.currentMessage).textSelection(.enabled)
            }
        }
    }

    @ViewBuilder private func statusIcon(_ status: ServerSetupActivity.Status) -> some View {
        switch status {
        case .running: ProgressView().controlSize(.small)
        case .complete: Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.controlAccent)
        case .failed: Image(systemName: "exclamationmark.circle.fill").foregroundStyle(Palette.warning)
        case .skipped: Image(systemName: "minus.circle").foregroundStyle(Palette.textTertiary)
        case .pending: Image(systemName: "circle").foregroundStyle(Palette.textTertiary)
        }
    }
}

struct ServerSetupFailureView: View {
    let failure: ServerSetupFailure
    @State private var copiedError = false

    private var diagnostic: String {
        ServerSetupDiagnostics.sanitise([failure.message, failure.recovery, failure.command,
            failure.exitStatus.map { "Exit status: \($0)" }, failure.details].compactMap { $0 }.joined(separator: "\n\n"))
    }

    /// "ssh · exit 1" on one line. The exit status used to sit in a column of its own beside the
    /// title and wrapped to "Exit" over "1" whenever the message ran to two lines.
    private var commandLine: String? {
        let parts = [failure.command, failure.exitStatus.map { "exit \($0)" }].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.spacingSmall) {
            // Three lines at most: the whole message is in Copy Error and in the server output, and
            // a box that grows with it pushes everything below off the page.
            Label(failure.message, systemImage: "exclamationmark.triangle.fill")
                .font(Typo.labelEmphasis).foregroundStyle(Palette.warning)
                .lineLimit(3).help(failure.message)
                .fixedSize(horizontal: false, vertical: true)
            Text(failure.recovery).font(Typo.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .firstTextBaseline, spacing: Metrics.spacingWide) {
                if let commandLine {
                    Text(commandLine).font(Typo.codeSmall).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle).help(commandLine)
                }
                Spacer(minLength: 0)
                Button(copiedError ? "Copied" : "Copy Error") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(diagnostic, forType: .string)
                    copiedError = true
                }
                .controlSize(.small).fixedSize()
            }
            .padding(.top, 2)
        }
        .textSelection(.enabled)
        .padding(Metrics.gutter)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.surfaceSunken, in: RoundedRectangle(cornerRadius: Metrics.corner))
        .onChange(of: failure) { copiedError = false }
    }
}
