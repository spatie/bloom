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
/// This pane is the whole of the feature's onboarding, which is why it is a pane rather than a row
/// somewhere. Everything else about the standalone bridge already exists by the time anybody gets
/// here: the socket is listening, the token is on disk, the role is decided and the tools are
/// gated. What is missing without this is the only step a person has to take, and there is exactly
/// one of them: run a command. So the pane is built around that command being copyable in one
/// press, with everything else on the page written to answer a question somebody would otherwise
/// have to go and ask.
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
    /// system, and a `body` that does it runs it again on every redraw, the flash of the Copied
    /// label included.
    @State private var command: String?
    @State private var didCopy = false
    @State private var isRegenerating = false

    var body: some View {
        Form {
            if let command {
                connectSection(command)
                regenerateSection
            } else {
                unavailableSection
            }
        }
        .settingsForm()
        .task { command = app.bridge?.ownerAttachment().map(BridgeRegistration.ownerAddCommand) }
    }

    // MARK: - Sections

    /// One instruction, the command, and the warning. Nothing else is above the thing to copy.
    ///
    /// The three paragraphs this used to open with said, between them, what an MCP server is, that
    /// already-running sessions will not pick it up, and what the entry is called. Only the last
    /// two are facts a person needs while they are here, and both are short enough to sit beside
    /// the Copy button instead of above the box.
    private func connectSection(_ command: String) -> some View {
        Section {
            Text(
                "Run this once, and Claude Code in your terminal can list your projects, add a "
                    + "repository and start a workspace."
            )
            .settingsFootnote()

            commandBox(command)

            legacyEntryNote
        } header: {
            Text("Use Bloom from your own terminal")
        } footer: {
            // The one paragraph on this pane that is not explanation but prevention, so it stays
            // on screen and stays next to the button. A committed token is the single genuinely
            // bad outcome this feature makes available.
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
            .settingsFootnote()
            .padding(.top, Metrics.spacingSmall)
        }
    }

    /// The one thing this rename leaves behind, said once and left to the reader.
    ///
    /// Every copy of Bloom used to register as `bloom-owner-bridge`, so anybody who ran the
    /// earlier command has that entry in `~/.claude.json` still, and nothing here will take it
    /// out: Bloom does not edit a person's own configuration file, which is the whole reason this
    /// feature is a command to copy rather than a write. The entry is not harmless enough to leave
    /// unmentioned either. If it names this same copy of Bloom it still works, and the owner gets
    /// two of every tool in one client under two names; if it names a copy that has gone, Claude
    /// Code reports a failed server at the start of every session with nothing to say why.
    ///
    /// So: one sentence and the line that removes it, in the pane the refusal message already
    /// sends people to. Behind a disclosure, because it is addressed to people who ran a command
    /// that no longer exists and is noise to everybody installing Bloom for the first time, which
    /// is now most readers of this pane. Closed it costs one line; deleted it would leave a
    /// stranger with a broken entry and nothing to say why.
    private var legacyEntryNote: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: Metrics.spacingSmall) {
                Text(
                    "Earlier versions registered as bloom-owner-bridge, whatever copy of Bloom "
                        + "they came from. If you ran that command, remove the old entry:"
                )
                .fixedSize(horizontal: false, vertical: true)

                Text("claude mcp remove --scope user bloom-owner-bridge")
                    .font(Typo.codeSmall)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .settingsFootnote()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, Metrics.spacingSmall)
        } label: {
            Text("Upgrading from an earlier version")
                .settingsFootnote()
        }
    }

    private func commandBox(_ command: String) -> some View {
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
                        .fill(Palette.surface)
                        .overlay(
                            RoundedRectangle(cornerRadius: Metrics.corner, style: .continuous)
                                .strokeBorder(Palette.border, lineWidth: Metrics.hairline)
                        )
                )

            HStack(spacing: Metrics.gutter) {
                // Beside the button rather than in a paragraph of its own above it: both facts are
                // about what happens after the press, and this is where the press is.
                Text(
                    "Appears as \(BridgeRegistration.ownerServerName). Sessions already running "
                        + "will not see it."
                )
                .settingsFootnote()

                Spacer()

                Button(didCopy ? "Copied" : "Copy command") { copy(command) }
                    .disabled(didCopy)
            }
        }
        .padding(.vertical, Metrics.spacingSmall)
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

    private func copy(_ command: String) {
        Clipboard.copy(command)
        didCopy = true
        Task {
            try? await Task.sleep(for: Clipboard.flashDuration)
            didCopy = false
        }
    }

    /// Regenerating rewrites the file and rebuilds the command in one step, so the box on screen
    /// is never the old token: a person who reads the box after pressing this and pastes what they
    /// see would otherwise be pasting the thing they just revoked.
    private func regenerate() {
        guard let bridge = app.bridge else { return }
        isRegenerating = true
        defer { isRegenerating = false }
        do {
            try bridge.regenerateOwnerToken()
            command = bridge.ownerAttachment().map(BridgeRegistration.ownerAddCommand)
            didCopy = false
        } catch {
            app.alert = BloomAlert(
                title: "Could not regenerate the token",
                message: error.readableMessage
            )
        }
    }
}
