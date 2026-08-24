import SwiftUI
import BloomCore

/// One line above a shell, saying that the worktree it is standing in is not finished.
///
/// A chat has had this for as long as there has been a queue: a message typed into a workspace
/// whose setup script is still running sits under a bubble that says so, and `DeliveryHold` is the
/// rule behind it. A terminal had nothing, which did not matter while every workspace opened on a
/// chat and matters now that one can be created to be driven by hand. The shell is forked the
/// moment the worktree exists, several minutes before `bun install` has finished, and a prompt in
/// a half-built directory looks exactly like a prompt in a finished one. The only thing that made
/// the difference visible was reading the transcript, which is the tab this kind of workspace was
/// created in order not to use.
///
/// What it says and when is `WorktreeReadiness`, in the core, where the suite holds both the
/// precedence and the sentences.
struct WorktreeSetupStrip: View {
    var readiness: WorktreeReadiness

    var body: some View {
        if let sentence = readiness.sentence {
            HStack(spacing: Metrics.spacing) {
                // A spinner while something is running, a mark once nothing is. A progress view
                // left up after a failure is the app claiming to still be trying.
                if readiness == .installing {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.7)
                        .frame(width: Metrics.glyph, height: Metrics.glyph)
                } else {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .imageScale(.small)
                        .foregroundStyle(Palette.warning)
                        .frame(width: Metrics.glyph, height: Metrics.glyph)
                }

                Text(sentence)
                    .font(Typo.caption)
                    .foregroundStyle(Palette.textSecondary)
                    .lineLimit(1)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, Metrics.gutter)
            .padding(.vertical, Metrics.spacing)
            .frame(maxWidth: .infinity)
            .background(Palette.surface)
            .overlay(alignment: .bottom) { Hairline() }
            // Wired to the sentence rather than to the case, so the strip going away and the strip
            // changing what it says are one animation rather than two shapes of the same edit.
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}
