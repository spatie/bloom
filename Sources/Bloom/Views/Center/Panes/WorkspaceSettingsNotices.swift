import SwiftUI
import BloomCore

/// What a workspace's settings files need the owner to know, at the top of its centre column: a
/// run script asking to start on its own, and entries a committed file had that were skipped.
///
/// In the layout rather than floating like `NoticeBanner`, and staying until answered, because
/// both are questions rather than news. `NoticeBanner` is for something the app already did and
/// leaves on its own; a request to run commands that goes away while somebody is reading it has
/// been answered by a timer, and a skipped run script that vanishes from the menu with a warning
/// that also vanished is the "where did it go" this exists to prevent.
///
/// Everything these say is decided in the core: `RunScriptAutostartNotice` and
/// `SettingsIssuesNotice`. What is left here is the drawing and the buttons.
struct WorkspaceSettingsNotices: View {
    var model: WorkspaceModel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var launcher: RunScriptLauncher { .shared }

    var body: some View {
        let ask = launcher.ask(for: model.workspace.id)
        let issues = SettingsIssuesNotice.make(issues: model.settings.issues)
            .flatMap { launcher.dismissedIssues.contains($0.signature) ? nil : $0 }

        VStack(spacing: 0) {
            if let ask {
                autostart(ask)
            }
            if let issues {
                settingsIssues(issues)
            }
        }
        .animation(reduceMotion ? nil : Motion.pane, value: ask)
        .animation(reduceMotion ? nil : Motion.pane, value: issues)
    }

    // MARK: - Autostart

    private func autostart(_ notice: RunScriptAutostartNotice) -> some View {
        WorkspaceNoticeStrip(symbol: "play.circle", tint: Palette.accent, title: notice.title) {
            VStack(alignment: .leading, spacing: Metrics.spacingTight) {
                ForEach(notice.lines) { line in
                    commandLine(line)
                }
            }
        } actions: {
            Button("Not Now") { launcher.notNow(in: model) }
                .controlSize(.small)
            Button(notice.allowTitle) { Task { await launcher.allow(notice, in: model) } }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
        }
    }

    /// One script: its name, then the command it would run, in mono. A changed command shows the
    /// one that was approved first, struck through, so the difference is the thing read.
    private func commandLine(_ line: RunScriptAutostartNotice.Line) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Metrics.spacing) {
            Text(verbatim: line.name)
                .font(Typo.captionEmphasis)
                .foregroundStyle(Palette.textPrimary)
                .lineLimit(1)
                .fixedSize()

            if let approved = line.approved {
                Text(verbatim: approved)
                    .font(Typo.codeSmall)
                    .foregroundStyle(Palette.textSecondary)
                    .strikethrough()
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(approved)
                Image(systemName: "arrow.right")
                    .imageScale(.small)
                    .foregroundStyle(Palette.textTertiary)
                    .accessibilityLabel("changed to")
            }

            // Shown whole on hover and selectable, because approving it is approving this text.
            Text(verbatim: line.command)
                .font(Typo.codeSmall)
                .foregroundStyle(Palette.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .help(line.command)
        }
    }

    // MARK: - Settings issues

    private func settingsIssues(_ notice: SettingsIssuesNotice) -> some View {
        WorkspaceNoticeStrip(
            symbol: "exclamationmark.triangle", tint: Palette.warning, title: notice.title,
            onDismiss: { launcher.dismissIssues(notice) }
        ) {
            VStack(alignment: .leading, spacing: Metrics.spacingTight) {
                ForEach(Array(notice.messages.enumerated()), id: \.offset) { _, message in
                    Text(verbatim: message)
                        .font(Typo.caption)
                        .foregroundStyle(Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
        } actions: {
            Button("Open File") { SettingsFileOpener.open(notice.path, repo: model.workspace.repoID) }
                .controlSize(.small)
        }
    }
}
