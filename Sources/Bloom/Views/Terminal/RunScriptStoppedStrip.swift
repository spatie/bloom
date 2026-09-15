import SwiftUI
import BloomCore

/// One line above a run script's shell, saying its command has stopped and for how long it ran.
///
/// The register is `TerminalRestartStrip`, for the same reason: the pane is not empty, it holds a
/// working shell with the command's last output in it, and that output is often the reason the
/// command was run. So nothing covers the terminal and nothing closes on its own. What is missing
/// is one process, and what is drawn is one line with the two things anybody does next.
///
/// **It says stopped, never failed or finished.** The command was typed into a shell, so there is
/// no exit status to read, only the moment the shell took its terminal back. Whether that was a
/// crash, a Ctrl+C or a seed completing is in the scrollback below, in the command's own words.
struct RunScriptStoppedStrip: View {
    var caption: String
    var command: String
    var onRunAgain: () -> Void
    var onCloseTab: () -> Void
    var onDismiss: () -> Void

    var body: some View {
        HStack(spacing: Metrics.spacing) {
            Image(systemName: "stop.circle")
                .imageScale(.small)
                .foregroundStyle(Palette.textSecondary)
                .frame(width: Metrics.glyph, height: Metrics.glyph)
                .accessibilityHidden(true)

            Text(caption)
                .font(Typo.caption)
                .foregroundStyle(Palette.textSecondary)
                .lineLimit(1)
                .layoutPriority(1)

            // Middle truncation, for `TerminalRestartStrip`'s reason: the program at one end and
            // the argument that says which one at the other.
            Text(verbatim: command)
                .font(Typo.codeSmall)
                .foregroundStyle(Palette.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .help(command)

            Spacer(minLength: 0)

            Button("Run Again", action: onRunAgain)
                .controlSize(.small)
                .accessibilityLabel("Run \(command) again")

            Button("Close Tab", action: onCloseTab)
                .controlSize(.small)

            Button("Dismiss", systemImage: "xmark", action: onDismiss)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .font(Typo.caption)
                .foregroundStyle(Palette.textTertiary)
                .help("Dismiss")
        }
        .padding(.horizontal, Metrics.gutter)
        .padding(.vertical, Metrics.spacing)
        .frame(maxWidth: .infinity)
        .background(Palette.surface)
        .overlay(alignment: .bottom) { Hairline() }
        .transition(.move(edge: .top).combined(with: .opacity))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(caption), \(command)")
    }
}
