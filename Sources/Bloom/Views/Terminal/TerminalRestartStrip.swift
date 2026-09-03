import SwiftUI
import BloomCore

/// One line above a shell, saying what this pane was running before Bloom last stopped, with a
/// button that starts it again.
///
/// The gap it fills: a dev server started in a terminal tab is gone after a relaunch, while the
/// tab, the split and the shell all come back. Nothing on screen said what had been lost, so the
/// only routes back were remembering the command or asking an agent to type it a second time.
///
/// **The button is the only thing that runs it.** The command is drawn and pressed, never executed
/// on the app's own initiative, because it may have been written by an agent through
/// `terminal_start` rather than typed by the owner. That is also why it is rendered as
/// `Text(verbatim:)` in mono: it is somebody else's text, shown as text, with no markdown parsed
/// out of it and nothing about it treated as a phrase of Bloom's own. What is worth showing at all
/// is `TerminalCommandMemory`, in the core, where a control character and a bare shell are both
/// refused.
///
/// The register is `WorktreeSetupStrip`, one strip above the same shell for the same reason: a fact
/// about the pane that the pane itself cannot show. Not an `EmptyStateView`, and that is the whole
/// difference between this and the other placeholders in the app: the pane is not empty. It holds a
/// working shell in the right worktree, and covering that over with a card would take a terminal
/// away in order to say something about it. What is missing is one process, so what is drawn is one
/// line.
struct TerminalRestartStrip: View {
    var command: String
    var onStart: () -> Void
    var onDismiss: () -> Void

    var body: some View {
        HStack(spacing: Metrics.spacing) {
            Image(systemName: "arrow.clockwise")
                .imageScale(.small)
                .foregroundStyle(Palette.textSecondary)
                .frame(width: Metrics.glyph, height: Metrics.glyph)
                .accessibilityHidden(true)

            Text("Was running here")
                .font(Typo.caption)
                .foregroundStyle(Palette.textSecondary)
                .lineLimit(1)
                .layoutPriority(1)

            // Middle truncation, because the ends of a command are what identify it: the program
            // at one end and the argument that says which one at the other.
            Text(verbatim: command)
                .font(Typo.codeSmall)
                .foregroundStyle(Palette.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .help(command)

            Spacer(minLength: 0)

            Button("Start", action: onStart)
                .controlSize(.small)
                .accessibilityLabel("Start \(command)")

            Button("Dismiss", systemImage: "xmark", action: onDismiss)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .font(Typo.caption)
                .foregroundStyle(Palette.textTertiary)
                .help("Forget this command")
        }
        .padding(.horizontal, Metrics.gutter)
        .padding(.vertical, Metrics.spacing)
        .frame(maxWidth: .infinity)
        .background(Palette.surface)
        .overlay(alignment: .bottom) { Hairline() }
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}
