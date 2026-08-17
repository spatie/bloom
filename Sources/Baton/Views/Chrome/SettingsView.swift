import AppKit
import SwiftUI
import BatonCore

/// Collects global and repository preferences in one window so configuration stays discoverable.
struct SettingsView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gear") }

            ProjectSettingsView()
                .tabItem { Label("Projects", systemImage: "folder") }

            AgentSettingsView()
                .tabItem { Label("Agent", systemImage: "terminal") }

            AboutSettingsView()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .tabViewStyle(.automatic)
        .frame(width: 620, height: 480)
        .background(Palette.windowBackground)
        .alert(item: Bindable(app).alert) { alert in
            Alert(title: Text(alert.title), message: Text(alert.message))
        }
    }
}

/// Keeps operating-system behavior and safety choices separate from agent configuration.
private struct GeneralSettingsView: View {
    @AppStorage("appearance") private var appearance = "system"
    @AppStorage("notifyWhenAgentFinishes") private var notifyWhenAgentFinishes = false
    @AppStorage("confirmBeforeArchiving") private var confirmBeforeArchiving = true

    var body: some View {
        Form {
            Picker("Appearance", selection: $appearance) {
                Text("System").tag("system")
                Text("Light").tag("light")
                Text("Dark").tag("dark")
            }
            .pickerStyle(.segmented)

            Toggle("Notify when an agent finishes", isOn: $notifyWhenAgentFinishes)
                .onChange(of: notifyWhenAgentFinishes) { _, enabled in
                    if enabled { Notifications.requestAuthorization() }
                }

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
        VStack(spacing: 0) {
            List(selection: $selectedRepoID) {
                ForEach(app.repos) { repo in
                    ProjectRow(repo: repo)
                        .tag(repo.id)
                        .contextMenu {
                            Button("Remove Project", role: .destructive) {
                                repoPendingRemoval = repo
                            }
                        }
                }
            }
            .frame(minHeight: 150)

            HStack {
                Button {
                    addProjectFolder()
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Add Project Folder")

                Button {
                    repoPendingRemoval = selectedRepo
                } label: {
                    Image(systemName: "minus")
                }
                .buttonStyle(.borderless)
                .disabled(selectedRepo == nil)
                .accessibilityLabel("Remove Project")

                Spacer()
            }
            .padding(.horizontal, Metrics.gutter)
            .frame(height: Metrics.rowHeight)

            Hairline()

            if let selectedRepo {
                EffectiveSettingsView(repo: selectedRepo)
            } else {
                EmptyStateView(
                    glyph: "folder",
                    title: "Select a project",
                    message: "Its effective repository settings will appear here."
                )
            }
        }
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
            isPresented: Binding(
                get: { repoPendingRemoval != nil },
                set: { if !$0 { repoPendingRemoval = nil } }
            )
        ) {
            Button("Remove Project", role: .destructive) {
                guard let repo = repoPendingRemoval else { return }
                repoPendingRemoval = nil
                Task { await app.removeRepository(repo) }
            }
            Button("Cancel", role: .cancel) {
                repoPendingRemoval = nil
            }
        } message: {
            Text("Existing workspace records for this project will also be removed.")
        }
    }

    private func addProjectFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Add Project"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await app.addRepository(at: url.path) }
    }
}

/// Keeps project edits local until commit so store reloads do not interrupt typing.
private struct ProjectRow: View {
    @Environment(AppModel.self) private var app
    let repo: Repo

    @State private var name: String
    @FocusState private var isEditingName: Bool

    init(repo: Repo) {
        self.repo = repo
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

    private var settings: RepoSettings {
        SettingsLoader.load(repo: repo.path)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.gutter) {
                HStack {
                    Text("Effective settings")
                        .font(Typo.title)
                    Spacer()
                    Button("Open Project Settings") {
                        Reveal.inEditor((repo.path as NSString).appendingPathComponent(".conductor/settings.toml"))
                    }
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
            .padding(Metrics.gutter)
        }
    }
}

/// Applies one compact visual treatment to scalar settings and path lists.
private struct SettingValue: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.cornerSmall) {
            Text(title)
                .font(Typo.labelEmphasis)
            Text(value)
                .font(Typo.codeSmall)
                .foregroundStyle(Palette.textSecondary)
                .textSelection(.enabled)
        }
    }
}

/// Constrains long scripts while preserving their whitespace and making them easy to copy.
private struct ScriptValue: View {
    let title: String
    let value: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.cornerSmall) {
            Text(title)
                .font(Typo.labelEmphasis)

            ScrollView([.horizontal, .vertical]) {
                Text(value ?? "None")
                    .font(Typo.codeSmall)
                    .foregroundStyle(Palette.textSecondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 72)
            .padding(Metrics.cornerSmall)
            .background(Palette.surfaceSunken, in: RoundedRectangle(cornerRadius: Metrics.cornerSmall))
        }
    }
}

/// Stores launch defaults independently of repository overrides and surfaces missing command-line tools early.
private struct AgentSettingsView: View {
    @Environment(AppModel.self) private var app

    @State private var defaultModel = "opus"
    @State private var defaultEffort = "high"
    @State private var defaultPermissionMode = PermissionMode.acceptEdits.rawValue
    @State private var fastModeByDefault = false
    @State private var hasLoaded = false

    var body: some View {
        Form {
            Picker("Default model", selection: $defaultModel) {
                Text("Opus").tag("opus")
                Text("Sonnet").tag("sonnet")
                Text("Haiku").tag("haiku")
            }

            Picker("Default effort", selection: $defaultEffort) {
                Text("Low").tag("low")
                Text("Medium").tag("medium")
                Text("High").tag("high")
                Text("Max").tag("max")
            }

            Picker("Default permission mode", selection: $defaultPermissionMode) {
                ForEach(PermissionMode.allCases, id: \.rawValue) { mode in
                    Text(mode.label).tag(mode.rawValue)
                }
            }

            Toggle("Fast mode by default", isOn: $fastModeByDefault)

            Section("Command-line tools") {
                ToolPathRow(name: "claude", path: Shell.which("claude"))
                ToolPathRow(name: "gh", path: Shell.which("gh"))
                ToolPathRow(name: "git", path: Shell.which("git"))
            }
        }
        .formStyle(.grouped)
        .task { await load() }
        .onChange(of: defaultModel) { _, value in save("defaultModel", value) }
        .onChange(of: defaultEffort) { _, value in save("defaultEffort", value) }
        .onChange(of: defaultPermissionMode) { _, value in save("defaultPermissionMode", value) }
        .onChange(of: fastModeByDefault) { _, value in save("fastModeByDefault", value ? "true" : "false") }
    }

    private func load() async {
        guard let store = app.store else { return }
        defaultModel = (try? await store.setting("defaultModel")) ?? "opus"
        defaultEffort = (try? await store.setting("defaultEffort")) ?? "high"
        defaultPermissionMode = (try? await store.setting("defaultPermissionMode")) ?? PermissionMode.acceptEdits.rawValue
        fastModeByDefault = (try? await store.setting("fastModeByDefault")) == "true"
        hasLoaded = true
    }

    private func save(_ key: String, _ value: String) {
        guard hasLoaded, let store = app.store else { return }
        Task { try? await store.setSetting(key, value) }
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
        VStack(spacing: Metrics.gutter) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 32))
                .foregroundStyle(Palette.accent)

            Text("Baton")
                .font(Typo.title)

            Text("Version \(version)")
                .font(Typo.label)
                .foregroundStyle(Palette.textSecondary)

            Text("Parallel coding agents, each working safely in its own git worktree.")
                .font(Typo.label)
                .foregroundStyle(Palette.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)

            LabeledContent("GitHub user") {
                Text(GitHubIdentity.cachedUsername ?? "Not resolved")
                    .font(Typo.codeSmall)
                    .foregroundStyle(Palette.textSecondary)
            }
            .frame(maxWidth: 320)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private extension Color {
    /// Converts an editable SwiftUI colour back to the repository's portable storage format.
    var hexString: String? {
        guard let color = NSColor(self).usingColorSpace(.sRGB) else { return nil }
        return String(
            format: "%02X%02X%02X",
            Int((color.redComponent * 255).rounded()),
            Int((color.greenComponent * 255).rounded()),
            Int((color.blueComponent * 255).rounded())
        )
    }
}
