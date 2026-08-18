import AppKit
import SwiftUI
import BatonCore

@MainActor
private enum AppearancePreference {
    static func apply(_ value: String) {
        NSApp.appearance = switch value {
        case "light": NSAppearance(named: .aqua)
        case "dark": NSAppearance(named: .darkAqua)
        default: nil
        }
    }
}

/// Collects global and repository preferences in one window so configuration stays discoverable.
struct SettingsView: View {
    /// Which tab is showing. An enum rather than an index, so the value says what it selects.
    @State private var tab: SettingsTab = .general

    init() {
        AppearancePreference.apply(UserDefaults.standard.string(forKey: "appearance") ?? "system")
    }

    var body: some View {
        TabView(selection: $tab) {
            Tab("General", systemImage: "gear", value: SettingsTab.general) {
                GeneralSettingsView()
            }

            Tab("Projects", systemImage: "folder", value: SettingsTab.projects) {
                ProjectSettingsView()
            }

            Tab("Models", systemImage: "sparkle", value: SettingsTab.models) {
                ModelSettingsView()
            }

            Tab("Agents", systemImage: "person.2", value: SettingsTab.agents) {
                AgentsSettingsView()
            }

            Tab("Tools", systemImage: "wrench.and.screwdriver", value: SettingsTab.tools) {
                ToolSettingsView()
            }

            Tab("About", systemImage: "info.circle", value: SettingsTab.about) {
                AboutSettingsView()
            }
        }
        .frame(
            minWidth: Metrics.sidebarWidth + Metrics.inspectorWidth,
            minHeight: Metrics.inspectorWidth
        )
        .background(Palette.windowBackground)
        // RootView is the single presenter for `app.alert`. Binding it here too gave one alert
        // two presenters, and the loser leaves an empty dialog shell on screen.
    }
}

/// Keeps operating-system behavior and safety choices separate from agent configuration.
private struct GeneralSettingsView: View {
    @AppStorage("appearance") private var appearance = "system"
    @AppStorage("confirmBeforeArchiving") private var confirmBeforeArchiving = true

    var body: some View {
        Form {
            Picker("Appearance", selection: $appearance) {
                Text("System").tag("system")
                Text("Light").tag("light")
                Text("Dark").tag("dark")
            }
            .pickerStyle(.segmented)

            Toggle("Confirm before archiving", isOn: $confirmBeforeArchiving)

            LabeledContent("Workspaces root") {
                HStack(spacing: Metrics.gutter) {
                    Text(WorkspaceManager.workspacesRoot.path)
                        .font(Typo.codeSmall)
                        .foregroundStyle(Palette.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Button("Reveal in Finder") {
                        Reveal.inFinder(WorkspaceManager.workspacesRoot.path)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { AppearancePreference.apply(appearance) }
        .onChange(of: appearance) { _, value in AppearancePreference.apply(value) }
    }
}

/// Pairs editable project metadata with the effective layered settings developers need to debug.
private struct ProjectSettingsView: View {
    @Environment(AppModel.self) private var app
    @State private var selectedRepoID: String?
    @State private var repoPendingRemoval: Repo?

    private var selectedRepo: Repo? {
        app.repos.first { $0.id == selectedRepoID }
    }

    var body: some View {
        Form {
            Section("Projects") {
                List(selection: $selectedRepoID) {
                    ForEach(app.repos) { repo in
                        ProjectRow(repo: repo) {
                            repoPendingRemoval = repo
                        }
                        .tag(repo.id)
                        .contextMenu {
                            Button("Remove Project", role: .destructive) {
                                repoPendingRemoval = repo
                            }
                        }
                    }
                }
                .frame(minHeight: Metrics.sidebarWidth)

                HStack {
                    Button("Add Project", systemImage: "plus", action: addProjectFolder)

                    Button("Remove Project", systemImage: "minus", role: .destructive) {
                        repoPendingRemoval = selectedRepo
                    }
                    .disabled(selectedRepo == nil)

                    Spacer()
                }
            }

            if let selectedRepo {
                Section("Effective settings") {
                    EffectiveSettingsView(repo: selectedRepo)
                }
            } else {
                Section {
                    ContentUnavailableView(
                        "Select a project",
                        systemImage: "folder",
                        description: Text("Its effective repository settings will appear here.")
                    )
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            if selectedRepoID == nil { selectedRepoID = app.repos.first?.id }
        }
        .onChange(of: app.repos) { _, repos in
            if !repos.contains(where: { $0.id == selectedRepoID }) {
                selectedRepoID = repos.first?.id
            }
        }
        .confirmationDialog(
            "Remove \(repoPendingRemoval?.name ?? "this project")?",
            isPresented: $repoPendingRemoval.isPresent(),
            presenting: repoPendingRemoval
        ) { repo in
            Button("Remove Project", role: .destructive) { remove(repo) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Existing workspace records for this project will also be removed.")
        }
    }

    private func remove(_ repo: Repo) {
        repoPendingRemoval = nil
        Task { await app.removeRepository(repo) }
    }

    private func addProjectFolder() {
        guard let path = ProjectFolderPicker.choose() else { return }
        Task { await app.addRepository(at: path) }
    }
}

/// Keeps project edits local until commit so store reloads do not interrupt typing.
private struct ProjectRow: View {
    @Environment(AppModel.self) private var app
    let repo: Repo
    let onRemove: () -> Void

    @State private var name: String
    @FocusState private var isEditingName: Bool

    init(repo: Repo, onRemove: @escaping () -> Void) {
        self.repo = repo
        self.onRemove = onRemove
        _name = State(initialValue: repo.name)
    }

    var body: some View {
        HStack(spacing: Metrics.gutter) {
            ColorPicker("Accent", selection: accentBinding, supportsOpacity: false)
                .labelsHidden()
                .frame(width: Metrics.rowHeight)

            VStack(alignment: .leading, spacing: Metrics.cornerSmall) {
                TextField("Project name", text: $name)
                    .textFieldStyle(.plain)
                    .font(Typo.bodyEmphasis)
                    .focused($isEditingName)
                    .onSubmit { saveName() }
                    .onChange(of: isEditingName) { wasEditing, editing in
                        if wasEditing && !editing { saveName() }
                    }

                Text(repo.path)
                    .font(Typo.caption)
                    .foregroundStyle(Palette.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            Chip(text: repo.defaultBranch, systemImage: "arrow.triangle.branch", monospaced: true)

            Button("Remove \(repo.name)", systemImage: "minus.circle", action: onRemove)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .foregroundStyle(Palette.textSecondary)
        }
        .onChange(of: repo.name) { _, updated in
            if !isEditingName { name = updated }
        }
    }

    private var accentBinding: Binding<Color> {
        Binding(
            get: { Color(hexString: repo.accent) },
            set: { color in
                guard let hex = color.hexString else { return }
                Task {
                    guard let store = app.store else { return }
                    _ = try? await store.upsert(repo.with { $0.accent = hex })
                    await app.reload()
                }
            }
        )
    }

    private func saveName() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            name = repo.name
            return
        }
        guard trimmed != repo.name else { return }
        Task { await app.rename(repo, to: trimmed) }
    }
}

/// Shows the merged configuration because layered settings are otherwise difficult to reason about.
private struct EffectiveSettingsView: View {
    let repo: Repo
    @State private var settings = RepoSettings()

    var body: some View {
        Group {
            LabeledContent {
                Button("Open Project Settings") {
                    Reveal.inEditor((repo.path as NSString).appendingPathComponent(".conductor/settings.toml"))
                }
            } label: {
                Text("Configuration")
            }

            SettingValue(title: "Contributing files", value: settings.sources.isEmpty ? "None" : settings.sources.joined(separator: "\n"))
            ScriptValue(title: "Setup script", value: settings.setupScript)
            ScriptValue(title: "Archive script", value: settings.archiveScript)

            if settings.runScripts.isEmpty {
                SettingValue(title: "Run scripts", value: "None")
            } else {
                ForEach(settings.runScripts) { script in
                    ScriptValue(title: "Run: \(script.name)", value: script.command)
                }
            }

            SettingValue(
                title: "Files to copy",
                value: settings.filesToCopy.isEmpty ? "None" : settings.filesToCopy.joined(separator: "\n")
            )
            SettingValue(title: "Branch prefix", value: settings.branchPrefix ?? "None")
        }
        .task(id: repo.path) {
            settings = RepoSettings()
            let path = repo.path
            let loaded = await Task.detached {
                SettingsLoader.load(repo: path)
            }.value
            guard !Task.isCancelled else { return }
            settings = loaded
        }
    }
}

/// Applies one compact visual treatment to scalar settings and path lists.
private struct SettingValue: View {
    let title: String
    let value: String

    var body: some View {
        LabeledContent(title) {
            Text(value)
                .font(Typo.codeSmall)
                .foregroundStyle(Palette.textSecondary)
                .textSelection(.enabled)
                .multilineTextAlignment(.trailing)
        }
    }
}

/// Constrains long scripts while preserving their whitespace and making them easy to copy.
private struct ScriptValue: View {
    let title: String
    let value: String?

    var body: some View {
        LabeledContent(title) {
            ScrollView([.horizontal, .vertical]) {
                Text(value ?? "None")
                    .font(Typo.codeSmall)
                    .foregroundStyle(Palette.textSecondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(Metrics.cornerSmall)
            .background(Palette.surfaceSunken, in: RoundedRectangle(cornerRadius: Metrics.cornerSmall))
        }
    }
}

/// Surfaces missing command-line tools before an operation fails without a useful explanation.
///
/// The agent CLIs themselves moved to the Agents tab, which detects far more about them than a
/// path. What is left is the plumbing Baton shells out to on its own behalf.
private struct ToolSettingsView: View {
    var body: some View {
        Form {
            Section("Command-line tools") {
                ToolPathRow(name: "git", path: Shell.which("git"))
                ToolPathRow(name: "gh", path: Shell.which("gh"))
            }
        }
        .formStyle(.grouped)
    }
}

/// Distinguishes a resolved executable from an actionable missing-tool warning.
private struct ToolPathRow: View {
    let name: String
    let path: String?

    var body: some View {
        LabeledContent(name) {
            if let path {
                Text(path)
                    .font(Typo.codeSmall)
                    .foregroundStyle(Palette.textSecondary)
                    .textSelection(.enabled)
            } else {
                Label("Not found on PATH", systemImage: "exclamationmark.triangle.fill")
                    .font(Typo.label)
                    .foregroundStyle(Palette.negative)
            }
        }
    }
}

/// Gives the settings window a stable identity without hard-coding release metadata.
private struct AboutSettingsView: View {
    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development"
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("Application") {
                    Label("Baton", systemImage: "point.3.connected.trianglepath.dotted")
                        .font(Typo.title)
                        .foregroundStyle(Palette.textPrimary)
                }
                LabeledContent("Version", value: version)
                LabeledContent("Purpose", value: "Parallel coding agents in isolated git worktrees")
            }

            Section("Account") {
                LabeledContent("GitHub user") {
                    Text(GitHubIdentity.cachedUsername ?? "Not resolved")
                        .font(Typo.codeSmall)
                        .foregroundStyle(Palette.textSecondary)
                }
            }
        }
        .formStyle(.grouped)
    }
}

private extension Color {
    /// Converts an editable SwiftUI colour back to the repository's portable storage format.
    var hexString: String? {
        guard let color = NSColor(self).usingColorSpace(.sRGB) else { return nil }
        return [color.redComponent, color.greenComponent, color.blueComponent]
            .map { component in
                let byte = String(Int((component * 255).rounded()), radix: 16, uppercase: true)
                return byte.count == 1 ? "0" + byte : byte
            }
            .joined()
    }
}
