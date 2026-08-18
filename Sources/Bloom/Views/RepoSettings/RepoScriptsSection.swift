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
                title: "Setup",
                summary: "Runs once, in the new worktree, before the first message is sent. A workspace whose setup fails is created but marked failed.",
                text: $model.draft.setupScript,
                destination: SettingsDestinationLabel(model: model, key: .setupScript)
            )

            RepoScriptField(
                title: "Archive",
                summary: "Runs in the worktree just before it is removed. Undo whatever setup did outside the folder here: a Valet site, a database, a container.",
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

/// One script: a label, a monospaced box, and the file it will be written to.
struct RepoScriptField<Destination: View>: View {
    let title: String
    let summary: String
    @Binding var text: String
    let destination: Destination

    /// Tall enough for a handful of lines. The maximum matters more than the minimum: a real
    /// setup script runs to eighty lines, and without a ceiling the box grows to all of them and
    /// pushes every other section of the window off the bottom of the form.
    private static var editorHeight: CGFloat { 92 }
    private static var editorMaximumHeight: CGFloat { 240 }

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing) {
            Text(title)
                .font(Typo.labelEmphasis)
                .foregroundStyle(Palette.textPrimary)

            Text(summary)
                .font(Typo.caption)
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            TextEditor(text: $text)
                .font(Typo.codeSmall)
                .scrollContentBackground(.hidden)
                .padding(Metrics.spacingSmall)
                .frame(minHeight: Self.editorHeight, maxHeight: Self.editorMaximumHeight)
                .background(Palette.surfaceSunken, in: RoundedRectangle(cornerRadius: Metrics.cornerSmall))
                .overlay {
                    RoundedRectangle(cornerRadius: Metrics.cornerSmall)
                        .strokeBorder(Palette.border, lineWidth: Metrics.hairline)
                }
                .accessibilityLabel("\(title) script")

            destination
        }
        .padding(.vertical, Metrics.spacingSmall)
    }
}

/// One run script. The name is what the tab is called; the command is what runs.
struct RepoRunScriptRow: View {
    @Binding var script: DraftRunScript
    let onRemove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing) {
            HStack(spacing: Metrics.gutter) {
                TextField("Name", text: $script.name)
                    .frame(maxWidth: 180)

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

                Button("Remove \(script.name)", systemImage: "minus.circle", action: onRemove)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .foregroundStyle(Palette.textSecondary)
                    .help("Remove this run script")
            }

            TextField("Command", text: $script.command, axis: .vertical)
                .font(Typo.codeSmall)
                .lineLimit(1...4)
        }
        .padding(.vertical, Metrics.spacingTight)
    }
}
