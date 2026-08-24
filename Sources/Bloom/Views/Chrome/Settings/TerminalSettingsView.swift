import BloomCore
import SwiftUI

/// The Terminal pane: coupling a client the owner runs themselves to the Bloom that is running.
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
struct TerminalSettingsView: View {
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

    private func connectSection(_ command: String) -> some View {
        Section {
            Text(
                "Run this once. It registers Bloom as an MCP server for every Claude Code session "
                    + "on this Mac, so you can ask the one in your terminal to list your projects, "
                    + "add a repository, and start a workspace."
            )
            .font(Typo.label)
            .foregroundStyle(Palette.textSecondary)
            .fixedSize(horizontal: false, vertical: true)

            commandBox(command)

            Text(
                "Sessions already running will not see it. Start a new one, then ask it what it is "
                    + "connected to. It appears in your client as "
                    + BridgeRegistration.ownerServerName + "."
            )
            .font(Typo.caption)
            .foregroundStyle(Palette.textSecondary)
            .fixedSize(horizontal: false, vertical: true)

            legacyEntryNote
        } header: {
            Text("Use Bloom from your own terminal")
        } footer: {
            Label {
                Text(
                    "It registers at user scope, which keeps it in your own configuration file. Do "
                        + "not paste it into a project's .mcp.json: that file is committed, and "
                        + "the token in it lets anything that can reach this Mac create projects "
                        + "and workspaces in your Bloom."
                )
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
            }
            .font(Typo.caption)
            .foregroundStyle(Palette.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
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
    /// sends people to. It will read as noise to somebody installing Bloom for the first time,
    /// which is the price of not silently leaving a stranger with a broken entry.
    private var legacyEntryNote: some View {
        VStack(alignment: .leading, spacing: Metrics.spacingSmall) {
            Text(
                "Earlier versions registered as bloom-owner-bridge, whatever copy of Bloom they "
                    + "came from. If you ran that command, remove the old entry:"
            )
            .fixedSize(horizontal: false, vertical: true)

            Text("claude mcp remove --scope user bloom-owner-bridge")
                .font(Typo.codeSmall)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(Typo.caption)
        .foregroundStyle(Palette.textSecondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, Metrics.spacingSmall)
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

            HStack {
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
                        .font(Typo.label)
                        .foregroundStyle(Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Spacer()

                    Button("Regenerate", role: .destructive) { regenerate() }
                        .disabled(isRegenerating)
                }
            }
        } header: {
            Text("Token")
        } footer: {
            Text(
                "Do this if the token has been somewhere it should not have been, a commit or a "
                    + "screen share. The old one stops working immediately, so run the new command "
                    + "afterwards or your terminal will lose Bloom."
            )
            .font(Typo.caption)
            .foregroundStyle(Palette.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
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
                "This copy of Bloom cannot be connected to an outside client, because the bridge "
                    + "it would connect through is not running. Reinstalling Bloom is the fix."
            )
            .font(Typo.label)
            .foregroundStyle(Palette.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
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
