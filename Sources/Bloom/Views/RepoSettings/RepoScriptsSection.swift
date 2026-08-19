import SwiftUI
import BloomCore

/// The commands this project runs on Bloom's behalf.
///
/// These fields are not preferences, they are code that will be executed, so the section says so
/// before the first field: which shell, which directory, and which variables are bound. Nothing is
/// escaped, quoted or validated on the way in, because a setup script is a shell script and
/// pretending otherwise would only break the ones that work. What the screen owes the user instead
/// is an accurate account of what pressing Save will cause to run later, and where.
struct RepoScriptsSection: View {
    @Bindable var model: RepoSettingsModel

    var body: some View {
        Group {
            scriptSection
            runSection
        }
    }

    private var scriptSection: some View {
        Section {
            RepoScriptField(
                title: "Setup script",
                summary: "Runs once, in the new worktree, before the first message is sent. A workspace whose setup fails is created but marked failed.",
                placeholder: "#!/bin/zsh",
                text: $model.draft.setupScript,
                destination: SettingsDestinationLabel(model: model, key: .setupScript)
            )

            RepoScriptField(
                title: "Archive script",
                summary: "Runs in the worktree just before it is removed. Undo whatever setup did outside the folder here: a Valet site, a database, a container.",
                placeholder: "#!/bin/zsh",
                text: $model.draft.archiveScript,
                destination: SettingsDestinationLabel(model: model, key: .archiveScript)
            )
        } header: {
            Text("Scripts")
        } footer: {
            VStack(alignment: .leading, spacing: Metrics.spacingTight) {
                Text("Run by zsh with the workspace folder as the working directory, not in an interactive shell, so anything a login shell would set up has to be set up in the script.")
                Text(Self.variables)
                    .font(Typo.codeTiny)
            }
            .font(Typo.caption)
            .foregroundStyle(Palette.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Named rather than described, because a script writer needs the exact spelling. Both
    /// prefixes carry the same values, which is what lets a script written for Conductor run here
    /// unchanged.
    private static let variables = WorkspaceManager.environmentPrefixes
        .map { "\($0)_*" }
        .joined(separator: " and ")
        + ": WORKSPACE_NAME, WORKSPACE_ID, WORKSPACE_PATH, ROOT_PATH, DEFAULT_BRANCH, PORT, IS_LOCAL"

    // MARK: - Run scripts

    private var runSection: some View {
        Section {
            ForEach($model.draft.runScripts) { $script in
                RepoRunScriptRow(script: $script) {
                    model.draft.runScripts.removeAll { $0.id == script.id }
                }
            }

            HStack {
                Button("Add Run Script", systemImage: "plus") {
                    model.draft.runScripts.append(DraftRunScript(name: "Run", command: ""))
                }
                Spacer()
            }

            Picker("When several workspaces are open", selection: $model.draft.runMode) {
                Text("Only one may run at a time").tag("nonconcurrent")
                Text("They may all run at once").tag("concurrent")
            }
        } header: {
            Text("Run scripts")
        } footer: {
            VStack(alignment: .leading, spacing: Metrics.spacingTight) {
                Text("Started from the panel at the bottom of a workspace, in its own terminal. Use the one-at-a-time mode when the project cannot run twice, because it binds a fixed port or shares one database.")
                SettingsDestinationLabel(model: model, key: .runScripts)
            }
            .font(Typo.caption)
            .foregroundStyle(Palette.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// One script: what it is called, where it is going, the code, and what it does.
///
/// The order is deliberate and it is the order Conductor uses, because it is the order the
/// questions arrive in. The name and the destination sit on one line above the box, so the file
/// this will be written to is known before a character is typed. The code comes next, in a real
/// editor with a gutter and syntax colours, because it is code. The sentence describing when it
/// runs goes underneath, where it can be read once and then ignored.
struct RepoScriptField<Destination: View>: View {
    let title: String
    let summary: String
    var placeholder = ""
    @Binding var text: String
    let destination: Destination

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing) {
            HStack(alignment: .firstTextBaseline, spacing: Metrics.gutter) {
                Text(title)
                    .font(Typo.labelEmphasis)
                    .foregroundStyle(Palette.textPrimary)

                Spacer(minLength: Metrics.spacingSmall)

                destination
            }

            ScriptEditor(text: $text, placeholder: placeholder)
                .accessibilityLabel(title)

            Text(summary)
                .font(Typo.caption)
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .multilineTextAlignment(.leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, Metrics.spacingSmall)
    }
}

/// One run script. The name is what the tab is called; the command is what runs.
///
/// The name field carries no title of its own. A `TextField` with one, inside a `Form`, is split
/// into a label column and a value column by the form itself, which put the name and the command
/// on two separate rows of a table and right-aligned a shell command against the far edge of the
/// window.
struct RepoRunScriptRow: View {
    @Binding var script: DraftRunScript
    let onRemove: () -> Void

    /// Wide enough for "Watch tests" without the command below it starting at a different edge.
    private static let nameWidth: CGFloat = 180

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing) {
            HStack(spacing: Metrics.gutter) {
                TextField("", text: $script.name, prompt: Text("Name"))
                    .textFieldStyle(.roundedBorder)
                    // Without this the grouped form claims the field for its value column and
                    // indents it half way across the window, away from the command under it.
                    .labelsHidden()
                    .frame(width: Self.nameWidth)

                // The table this script is stored under. Shown because renaming it does not move
                // it: the table name is fixed when the script is first saved, and it is what a
                // teammate reading the file sees.
                if !script.key.isEmpty {
                    Text("scripts.run.\(script.key)")
                        .font(Typo.codeTiny)
                        .foregroundStyle(Palette.textTertiary)
                        .lineLimit(1)
                }

                Spacer(minLength: Metrics.spacingSmall)

                Button("Remove this run script", systemImage: "minus.circle", action: onRemove)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .foregroundStyle(Palette.textSecondary)
                    .help("Remove this run script")
            }

            // The same editor the setup script gets. A run script is one or two lines rather than
            // forty, so it starts at one and grows, but it is the same shell and it is read the
            // same way: the gutter and the colours are not a reward for length.
            ScriptEditor(
                text: $script.command,
                placeholder: "Command",
                minimumHeight: 40,
                maximumHeight: 160
            )
            .accessibilityLabel("Command for \(script.name)")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, Metrics.spacingTight)
    }
}
