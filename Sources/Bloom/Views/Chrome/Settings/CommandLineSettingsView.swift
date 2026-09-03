import BloomCore
import SwiftUI

/// The Command Line pane: coupling a client the owner runs themselves to the Bloom that is
/// running.
///
/// **Not called Terminal, and that is a correction rather than a preference.** It was, and the two
/// settings anybody goes looking for under that word, the terminal's text size and whether a shell
/// survives a quit, are in Appearance and always have been. A reader after a font size clicked
/// Terminal and got an `mcp add` command. Nothing in here is about the terminal Bloom draws; it is
/// about the one the owner already had open.
///
/// This pane used to be the whole of the feature's onboarding, and that is what was wrong with it.
/// Everything else about the standalone bridge already exists by the time anybody gets here: the
/// socket is listening, the token is on disk, the role is decided and the tools are gated. What is
/// missing without this is the only step a person has to take, and there is exactly one of them:
/// run a command. Nobody browses a settings tab they do not know exists, so a capability that
/// needs one command run once was invisible to everyone who did not go looking, and the welcome
/// window offers it as a step now. See `WelcomeCommandLine`.
///
/// The pane stays, and it is not the lesser half. A capability offered only during onboarding is
/// one that cannot be turned on afterwards, this is where somebody comes back for the command, and
/// Regenerate lives here and nowhere else. What the two share is drawn by `CommandLineOffer`, so
/// the command and the wording have one source and the warning cannot be edited in one place only.
///
/// **`--scope user`, and the pane says why out loud.** Claude Code would also take this at project
/// scope, which writes a `.mcp.json` in the working directory, and that file is meant to be
/// committed and shared with everyone who clones the repository. A token that grants the power to
/// register projects and cut worktrees on this machine, in a commit, is the one genuinely bad
/// outcome available here, so the warning is on the page next to the button rather than in a
/// document nobody opens.
struct CommandLineSettingsView: View {
    @Environment(AppModel.self) private var app

    /// Resolved once when the pane opens rather than in `body`. Reading the token touches the file
    /// system, and a `body` that does it runs it again on every redraw.
    @State private var attachment: BridgeAttachment?
    @State private var isRegenerating = false

    var body: some View {
        Form {
            if let attachment {
                connectSection(attachment)
                regenerateSection
            } else {
                unavailableSection
            }
        }
        .settingsForm()
        .task { attachment = app.bridge?.ownerAttachment() }
    }

    // MARK: - Sections

    /// One instruction, the command, and the warning. Nothing else is above the thing to copy.
    ///
    /// The three paragraphs this used to open with said, between them, what an MCP server is, that
    /// already-running sessions will not pick it up, and what the entry is called. Only the last
    /// two are facts a person needs while they are here, and both are short enough to sit beside
    /// the Copy button instead of above the box.
    private func connectSection(_ attachment: BridgeAttachment) -> some View {
        Section {
            CommandLineInstruction(supportsMultipleClients: true)

            commandOffer(
                title: "Claude Code",
                command: BridgeRegistration.ownerAddCommand(attachment)
            )
            commandOffer(
                title: "Codex",
                command: BridgeRegistration.ownerCodexAddCommand(attachment)
            )
        } header: {
            Text("Use Bloom from your own terminal")
        } footer: {
            CommandLineWarning()
                .padding(.top, Metrics.spacingSmall)
        }
    }

    private func commandOffer(title: String, command: String) -> some View {
        VStack(alignment: .leading, spacing: Metrics.spacingTight) {
            Text(title)
                .font(Typo.bodyEmphasis)

            // A regenerated token gives the offer a new identity, clearing its Copied flash.
            CommandLineOffer(command: command)
                .id(command)
        }
    }

    private var regenerateSection: some View {
        Section {
            SettingsRow("Regenerate") {
                HStack(spacing: Metrics.gutter) {
                    Text("Ends the connection above and issues a new command to run.")
                        .settingsFootnote()

                    Spacer()

                    Button("Regenerate", role: .destructive) { regenerate() }
                        .disabled(isRegenerating)
                }
            }
        } header: {
            Text("Token")
        } footer: {
            Text(
                "Do this if the token has been somewhere it should not have been. The old one "
                    + "stops working at once, so run the new command afterwards."
            )
            .settingsFootnote()
        }
    }

    /// What the pane says when there is nothing to copy.
    ///
    /// Two causes and they are told apart nowhere, on purpose: both mean this copy of Bloom cannot
    /// serve a bridge at all, and neither is anything the reader can do about beyond reinstalling.
    /// A build assembled without the shim beside it is a development build somebody made by hand,
    /// and a bridge that did not start is in the log.
    private var unavailableSection: some View {
        Section("Use Bloom from your own terminal") {
            Text(
                "The bridge this would connect through is not running, so this copy of Bloom "
                    + "cannot be reached from an outside client. Reinstalling Bloom is the fix."
            )
            .settingsFootnote()
        }
    }

    // MARK: - Actions

    /// Regenerating rewrites the file and rebuilds the command in one step, so the box on screen
    /// is never the old token: a person who reads the box after pressing this and pastes what they
    /// see would otherwise be pasting the thing they just revoked.
    private func regenerate() {
        guard let bridge = app.bridge else { return }
        isRegenerating = true
        defer { isRegenerating = false }
        do {
            try bridge.regenerateOwnerToken()
            attachment = bridge.ownerAttachment()
        } catch {
            app.alert = BloomAlert(
                title: "Could not regenerate the token",
                message: error.readableMessage
            )
        }
    }
}
