import BloomCore
import SwiftUI

/// The one command that couples a client the owner runs themselves to the Bloom that is running,
/// drawn the same way in both places that offer it.
///
/// Two places, one file, and that is the point of the file existing. The offer started in the
/// Command Line settings pane, where it was the whole of the feature's onboarding and where
/// nobody who did not already know it was there ever found it. It is now also a step of the
/// welcome window, which is where somebody meets it while they are already being set up. Settings
/// is where they go back for it, and where Regenerate lives, so both have to stay; what must not
/// be two things is the wording and the command, because the sentence that keeps somebody from
/// committing a live token is worth nothing if only one of the two copies of it gets edited.
///
/// Nothing here decides anything. The command is `BridgeRegistration.ownerAddCommand`, whether the
/// offer is worth making at all is `BridgeUserRegistration`, and both of those are in the core
/// with tests. This is the drawing.
struct CommandLineOffer: View {
    /// The line to run, already built. Passed in rather than resolved here because reading it
    /// touches the file holding the token, and a `body` that did that would do it again on every
    /// redraw, the flash of the Copied label included.
    let command: String
    /// What the box is filled with, because the ground it lands on decides which way the well
    /// goes. A settings section is already sunken, so the box on it is raised; the welcome
    /// window's reading band is the raised colour itself, so a box filled the same way there
    /// would be nothing but its own border.
    var fill: Color = Palette.surface

    @State private var didCopy = false

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.spacingSmall) {
            // Selectable as well as copyable. The button is how anybody sane moves it, and the
            // selection is for the person who wants to change the scope or read the token before
            // trusting it to their shell.
            Text(command)
                .font(Typo.codeSmall)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Metrics.spacing)
                .background(
                    RoundedRectangle(cornerRadius: Metrics.corner, style: .continuous)
                        .fill(fill)
                        .overlay(
                            RoundedRectangle(cornerRadius: Metrics.corner, style: .continuous)
                                .strokeBorder(Palette.border, lineWidth: Metrics.outline)
                        )
                )

            HStack(spacing: Metrics.gutter) {
                // Beside the button rather than in a paragraph of its own above it: both facts are
                // about what happens after the press, and this is where the press is.
                Text(
                    "Appears as \(BridgeRegistration.ownerServerName). Sessions already running "
                        + "will not see it."
                )
                .modifier(CommandLineNote())

                Spacer()

                Button(didCopy ? "Copied" : "Copy command") { copy() }
                    .disabled(didCopy)
            }
        }
        .padding(.vertical, Metrics.spacingSmall)
    }

    private func copy() {
        Clipboard.copy(command)
        didCopy = true
        Task {
            try? await Task.sleep(for: Clipboard.flashDuration)
            didCopy = false
        }
    }
}

/// One instruction, said once, above whichever box is showing the command.
struct CommandLineInstruction: View {
    /// True where this is the sentence under a headline rather than a note under a section header.
    /// The words are the same in both places and the rung is not: the welcome window sets its
    /// prose at `Typo.body`, which is what the verdict line on the checks screen is set at, and a
    /// caption there would be the one sentence explaining the offer set smaller than the warning
    /// under it.
    var isLead = false

    var body: some View {
        Group {
            if isLead {
                Text(sentence)
                    .font(Typo.body)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(sentence).modifier(CommandLineNote())
            }
        }
    }

    private var sentence: String {
        "Run this once, and Claude Code in your terminal can list your projects, add a "
            + "repository and start a workspace."
    }
}

/// The one paragraph about this feature that is not explanation but prevention.
///
/// It stays on screen and it stays next to the button, in both places, and it is the last sentence
/// either of them may cut for brevity. Claude Code would take this registration at project scope,
/// which writes a `.mcp.json` in the working directory, and that file is meant to be committed and
/// shared with everyone who clones the repository. A token that grants the power to register
/// projects and cut worktrees on this machine, in a commit, is the one genuinely bad outcome this
/// feature makes available.
struct CommandLineWarning: View {
    var body: some View {
        Label {
            Text(
                "Registers at user scope, in your own configuration file. Never paste it into "
                    + "a project's .mcp.json: that file is committed, and the token in it lets "
                    + "anything that can reach this Mac create projects and workspaces in your "
                    + "Bloom."
            )
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
        }
        .modifier(CommandLineNote())
    }
}

/// The rung every small line in this offer is set at.
///
/// Spelled out rather than `settingsFootnote()`, which is the same three lines, because half of
/// what this file draws is now in a window that is not Settings and a modifier named after a pane
/// is a modifier somebody will one day change for that pane alone.
private struct CommandLineNote: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(Typo.caption)
            .foregroundStyle(Palette.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
