import SwiftUI
import AppKit
import BloomCore

/// Steps remain visible while native, selectable output fills the rest of the window.
struct ServerSetupActivityView: View {
    let activity: ServerSetupActivity
    let failure: ServerSetupFailure?
    @State private var copiedOutput = false

    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.gutter) {
            if let failure { ServerSetupFailureView(failure: failure) }
            if compact {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: 2), alignment: .leading, spacing: Metrics.spacing) {
                    ForEach(ServerSetupActivity.Stage.allCases) { stage in stageRow(stage) }
                }
                output
            } else {
                HStack(alignment: .top, spacing: Metrics.gutter * 2) {
                    VStack(alignment: .leading, spacing: Metrics.gutter) {
                        ForEach(ServerSetupActivity.Stage.allCases) { stage in stageRow(stage) }
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
                .font(activity.status(of: stage) == .running ? Typo.captionEmphasis : Typo.caption)
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
            if failure == nil {
                Text(activity.currentMessage)
                    .font(Typo.caption).foregroundStyle(.secondary)
                    .lineLimit(2).textSelection(.enabled)
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

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing) {
            HStack(alignment: .firstTextBaseline) {
                Label(failure.message, systemImage: "exclamationmark.triangle.fill")
                    .font(Typo.labelEmphasis).foregroundStyle(Palette.warning)
                Spacer(minLength: 0)
                if let status = failure.exitStatus {
                    Text("Exit \(status)").font(Typo.codeSmall).foregroundStyle(.secondary)
                }
            }
            if let command = failure.command {
                Text(command).font(Typo.codeSmall).foregroundStyle(.secondary).lineLimit(2)
            }
            Text(failure.recovery).font(Typo.caption).foregroundStyle(.secondary)
            Button(copiedError ? "Copied" : "Copy Error") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(diagnostic, forType: .string)
                copiedError = true
            }
            .controlSize(.small)
        }
        .textSelection(.enabled)
        .padding(Metrics.gutter)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.surfaceSunken, in: RoundedRectangle(cornerRadius: Metrics.corner))
        .onChange(of: failure) { copiedError = false }
    }
}
