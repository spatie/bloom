import SwiftUI
import BloomCore

/// The commands this project runs on Bloom's behalf.
///
/// These fields are not preferences, they are code that will be executed, so the section says so
/// before the first field: which shell, which directory, and which variables are bound. Nothing is
/// escaped, quoted or validated on the way in, because a setup script is a shell script and
/// pretending otherwise would only break the ones that work. What the screen owes the user instead
/// is an accurate account of what pressing Save will cause to run later, and where.
///
/// "Where" is now a real answer. A script long enough to be a program is saved as an executable
/// file, `.bloom/setup.sh`, and the settings file points at it, so the same program can be linted,
/// opened in the user's own editor and run straight from a terminal. Every field names the file it
/// will be written to before a character is typed. See `SettingsWriter.scriptFile`.
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
                model: model,
                location: .setup,
                key: .setupScript,
                title: "Setup script",
                summary: "Runs once, in the new worktree, before the first message is sent. A workspace whose setup fails is created but marked failed.",
                placeholder: "#!/bin/zsh",
                text: $model.draft.setupScript
            )

            RepoScriptField(
                model: model,
                location: .archive,
                key: .archiveScript,
                title: "Archive script",
                summary: "Runs in the worktree just before it is removed. Undo whatever setup did outside the folder here: a Valet site, a database, a container.",
                placeholder: "#!/bin/zsh",
                text: $model.draft.archiveScript
            )
        } footer: {
            VStack(alignment: .leading, spacing: Metrics.spacingTight) {
                Text("Run with the workspace folder as the working directory, not in an interactive shell, so anything a login shell would set up has to be set up in the script. A script saved as a file is run as itself, so the shebang on its first line picks the interpreter; one kept as a line of settings is run by zsh.")
                Text(Self.variables)
                    .font(Typo.codeTiny)
                Text(Self.alias)
            }
            .font(Typo.caption)
            .foregroundStyle(Palette.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Named rather than described, because a script writer needs the exact spelling.
    private static let variables = "\(WorkspaceManager.environmentPrefix)_"
        + "{WORKSPACE_NAME, WORKSPACE_ID, WORKSPACE_PATH, ROOT_PATH, DEFAULT_BRANCH, PORT, IS_LOCAL}"

    /// Said once, quietly, and not given equal billing with the real names above it. A script
    /// written for Conductor keeps working; a script written today should not be written that way.
    private static let alias = "Each is also set as "
        + "\(WorkspaceManager.deprecatedEnvironmentPrefix)_*, for scripts written for Conductor."

    // MARK: - Run scripts

    private var runSection: some View {
        Section {
            ForEach($model.draft.runScripts) { $script in
                RepoRunScriptRow(model: model, script: $script) {
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
struct RepoScriptField: View {
    let model: RepoSettingsModel
    let location: ScriptLocation
    let key: SettingsKey
    let title: String
    let summary: String
    var placeholder = ""
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing) {
            HStack(alignment: .firstTextBaseline, spacing: Metrics.gutter) {
                Text(title)
                    .font(Typo.labelEmphasis)
                    .foregroundStyle(Palette.textPrimary)

                Spacer(minLength: Metrics.spacingSmall)

                ScriptDestinationLabel(model: model, location: location, key: key, script: text)
            }

            // Inlined rather than a view that draws nothing, because a `VStack` still spaces
            // around a child whose body is empty.
            if let missing = model.missingScriptFile(for: location) {
                MissingScriptNote(path: missing)
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

/// Names the script's own file, when it has one, and otherwise the settings file it is a line of.
///
/// The distinction is the whole point of the field: `.bloom/setup.sh` is a program somebody can
/// open, lint and run, and a line inside `settings.toml` is not. Which of the two a script is
/// depends on the script, so the label is worked out from what is in the box at this moment and
/// changes under the user's hands the moment a shebang or a second line makes it a program. That
/// is not a glitch, it is the rule being shown before it is applied.
struct ScriptDestinationLabel: View {
    let model: RepoSettingsModel
    let location: ScriptLocation
    let key: SettingsKey
    let script: String

    var body: some View {
        if let file {
            Text(text(for: file))
                .font(Typo.caption)
                .foregroundStyle(isMoving ? Palette.warning : Palette.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(help(for: file))
        } else {
            // Still a line of settings, so the ordinary label, which knows about `.conductor` and
            // about machine-wide files, is exactly right.
            SettingsDestinationLabel(model: model, key: key)
        }
    }

    private var file: String? { model.scriptFile(for: location, script: script) }

    /// True while saving would move this script out of a settings file and into one of its own.
    private var isMoving: Bool { model.loaded.scriptFiles[location] == nil }

    private func text(for file: String) -> String {
        isMoving ? "Moving into \(file)" : "Saved to \(file)"
    }

    private func help(for file: String) -> String {
        let settings = short(model.destination(for: key))
        guard isMoving else {
            return "Saved to \(file), which \(settings) names as this script."
        }
        return """
            A script with a shebang, or with more than one line, is a program rather than a \
            setting. Saving writes it to \(file), makes it executable, and leaves \(settings) \
            naming that path instead of holding the text. It can then be run, and linted, on its \
            own.
            """
    }

    private func short(_ path: String) -> String {
        path.hasPrefix(model.repo.path + "/")
            ? String(path.dropFirst(model.repo.path.count + 1))
            : (path as NSString).abbreviatingWithTildeInPath
    }
}

/// Said plainly, because the field underneath is empty and an empty field means something else.
///
/// A settings file naming a script that is not on disk is not the same as a project with no setup
/// script: the first is a repository somebody has not finished checking out, or a file somebody
/// deleted, and the difference is invisible unless it is stated. It is not an error either.
/// Workspaces are still created, the script is skipped, and typing here puts the file back at the
/// path the settings already name.
struct MissingScriptNote: View {
    let path: String

    var body: some View {
        Label(
            "\(path) is named here but is not on disk. The script is skipped rather than failed, and anything typed below is written back to that path.",
            systemImage: "exclamationmark.triangle"
        )
        .font(Typo.caption)
        .foregroundStyle(Palette.warning)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// One run script. The name is what the tab is called; the command is what runs.
///
/// The name field carries no title of its own. A `TextField` with one, inside a `Form`, is split
/// into a label column and a value column by the form itself, which put the name and the command
/// on two separate rows of a table and right-aligned a shell command against the far edge of the
/// window.
struct RepoRunScriptRow: View {
    let model: RepoSettingsModel
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

                // Where this script lives: the table it is stored under, or the file it was long
                // enough to be given. Shown because renaming it does not move it: the table name
                // is fixed when the script is first saved, and it is what a teammate reading the
                // file sees.
                if let storage {
                    Text(storage)
                        .font(Typo.codeTiny)
                        .foregroundStyle(Palette.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: Metrics.spacingSmall)

                Button("Remove this run script", systemImage: "minus.circle", action: onRemove)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .foregroundStyle(Palette.textSecondary)
                    .help("Remove this run script")
            }

            if !script.key.isEmpty, let missing = model.missingScriptFile(for: .run(script.key)) {
                MissingScriptNote(path: missing)
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

private extension RepoRunScriptRow {
    /// A file when this script has one or is about to get one, and the TOML table otherwise.
    var storage: String? {
        guard !script.key.isEmpty else { return nil }
        if let file = model.scriptFile(for: .run(script.key), script: script.command) {
            return file
        }
        return "scripts.run.\(script.key)"
    }
}
