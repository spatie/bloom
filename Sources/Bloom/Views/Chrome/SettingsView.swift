import AppKit
import SwiftUI
import BloomCore

/// Shared with the Appearance pane, which owns the picker that writes the preference.
@MainActor
enum AppearancePreference {
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
    /// Enough for the widest form row without the window feeling like a second main window. Its
    /// own numbers, rather than the sidebar and inspector widths that happened to add up to
    /// something plausible.
    private static let minSize = CGSize(width: 640, height: 420)

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

            Tab("Appearance", systemImage: "paintbrush", value: SettingsTab.appearance) {
                AppearanceSettingsView()
            }

            Tab("Notifications", systemImage: "bell", value: SettingsTab.notifications) {
                NotificationSettingsView()
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

            Tab("Prompts", systemImage: "text.bubble", value: SettingsTab.prompts) {
                PromptSettingsView()
            }

            Tab("Tools", systemImage: "wrench.and.screwdriver", value: SettingsTab.tools) {
                ToolSettingsView()
            }

            Tab("About", systemImage: "info.circle", value: SettingsTab.about) {
                AboutSettingsView()
            }
        }
        .frame(minWidth: Self.minSize.width, minHeight: Self.minSize.height)
        .background(Palette.windowBackground)
        // RootView is the single presenter for `app.alert`. Binding it here too gave one alert
        // two presenters, and the loser leaves an empty dialog shell on screen.
    }
}

/// Keeps operating-system behavior and safety choices separate from agent configuration.
private struct GeneralSettingsView: View {
    @AppStorage("confirmBeforeArchiving") private var confirmBeforeArchiving = true
    @AppStorage(MenuBarStatusItem.settingKey) private var showsMenuBarStatus = MenuBarStatusItem.isOnByDefault

    var body: some View {
        Form {
            Toggle("Confirm before archiving", isOn: $confirmBeforeArchiving)

            // A switch with its explanation underneath, not a checkbox inside a labelled row.
            // Two booleans of the same rank sat next to each other wearing two different controls,
            // and every other boolean in this window is a switch.
            Toggle(isOn: $showsMenuBarStatus) {
                Text("Show agent status in the menu bar")
                Text("Which agents are running and which are waiting for you, without raising the window.")
            }

            SleepSettingsSection()

            UpdateSettingsSection()

            LabeledContent("New workspaces") {
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
    /// This window raises its own copy of the offer. `RootView` presents the one belonging to the
    /// main window, and `Binding.on` keeps a request from appearing on both at once.
    @Bindable private var projectSetup = ProjectSetup.shared
    @State private var selectedRepoID: String?
    @State private var repoPendingRemoval: Repo?

    private var selectedRepo: Repo? {
        app.repos.first { $0.id == selectedRepoID }
    }

    /// Enough rows to scan a project list without the form below it disappearing.
    private static let listHeight: CGFloat = 260

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
                .frame(minHeight: Self.listHeight)

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
        .sheet(item: $projectSetup.request.on(.settings)) { request in
            ProjectSetupSheet(request: request) { path in
                Task { await app.finishProjectSetup(path) }
            }
        }
    }

    private func remove(_ repo: Repo) {
        repoPendingRemoval = nil
        Task { await app.removeRepository(repo) }
    }

    private func addProjectFolder() {
        Task {
            guard let path = await ProjectFolderPicker.choose() else { return }
            // Named, because a folder that is not a repository yet raises an offer, and the offer
            // has to appear on this window rather than on the one behind it.
            await app.addRepository(at: path, presentedIn: .settings)
        }
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
            // A stock `ColorPicker`, so the colour panel and its eyedropper come for free. It is
            // a capsule on macOS 26 because that is what Apple draws, but at the default control
            // size it is taller than the two lines of text beside it and reads as the subject of
            // the row rather than as one attribute of it.
            ColorPicker("Accent", selection: accentBinding, supportsOpacity: false)
                .labelsHidden()
                .controlSize(.small)

            VStack(alignment: .leading, spacing: Metrics.spacingTight) {
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
                .help("Remove \(repo.name)")
        }
        .onChange(of: repo.name) { _, updated in
            if !isEditingName { name = updated }
        }
    }

    /// The unchanged check is not a nicety. A colour well reports on every frame of a drag, and
    /// without it each of those frames is a SQLite write plus a full `app.reload()`. The project
    /// settings window has the same binding and the same guard.
    private var accentBinding: Binding<Color> {
        Binding(
            get: { Color(hexString: repo.accent) },
            set: { color in
                guard let hex = color.hexString, hex != repo.accent else { return }
                Task {
                    guard let store = app.store else { return }
                    _ = try? await store.update(repoID: repo.id) { $0.accent = hex }
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

/// A script this project resolves to, read only.
///
/// Not a `LabeledContent`. A form's value column carries `multilineTextAlignment(.trailing)` in
/// its environment, and `Text` obeys it, so a forty line setup script was set flush right: every
/// line ragged on the left, the indentation destroyed, and the whole thing squeezed into whatever
/// the label column left over. Shell is code, so it is shown the way the rest of the app shows
/// code, in the editor `ScriptEditor` wraps: left aligned, line numbered, syntax coloured, and
/// bounded so a long script scrolls instead of stretching the pane.
private struct ScriptValue: View {
    let title: String
    let value: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing) {
            Text(title)
                .font(Typo.labelEmphasis)
                .foregroundStyle(Palette.textPrimary)

            ScriptEditor(
                text: .constant(value ?? ""),
                isEditable: false,
                placeholder: "None",
                minimumHeight: 56,
                maximumHeight: 280
            )
            .accessibilityLabel(title)
        }
        .multilineTextAlignment(.leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, Metrics.spacingSmall)
    }
}

/// Surfaces missing command-line tools before an operation fails without a useful explanation.
///
/// The agent CLIs themselves moved to the Agents tab, which detects far more about them than a
/// path. What is left is the plumbing Bloom shells out to on its own behalf.
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
    /// Two lines of the row's own type, which is where an icon beside a name belongs.
    private static let iconSize: CGFloat = 32

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development"
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("Application") {
                    HStack(spacing: Metrics.spacing) {
                        // The app's own icon, read out of the running bundle. It used to be an SF
                        // Symbol of three connected dots, which was a stand-in from before Bloom
                        // had a mark of its own and stopped being true the moment it did.
                        Image(nsImage: NSApp.applicationIconImage)
                            .resizable()
                            .frame(width: Self.iconSize, height: Self.iconSize)
                            .accessibilityHidden(true)
                        Text(verbatim: "Bloom")
                            .font(Typo.title)
                            .foregroundStyle(Palette.textPrimary)
                    }
                }
                LabeledContent("Version", value: version)
                LabeledContent("Purpose", value: "Parallel coding agents in isolated git worktrees")
                LabeledContent("Website") {
                    Link("runbloom.app", destination: URL(string: "https://runbloom.app")!)
                }
            }

            Section("Made by") {
                SpatieCredit()
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

/// Who made the app, with their mark rather than their name set in the app's own type.
private struct SpatieCredit: View {
    /// The mark is two-tone and its plate colour is fixed, so it cannot be tinted to suit the
    /// window: the two files are the two authorised versions and the scheme picks between them.
    @Environment(\.colorScheme) private var colorScheme

    private var logo: NSImage? {
        let name = colorScheme == .dark ? "SpatieLogoWhite" : "SpatieLogo"
        guard let url = Bundle.main.url(forResource: name, withExtension: "pdf") else { return nil }
        return NSImage(contentsOf: url)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing) {
            if let logo {
                // A PDF, so AppKit redraws the vector at whatever scale the display asks for.
                // Height is fixed and width follows, because the mark is a fixed 2.33:1 lockup
                // and a stretched logo is worse than no logo.
                Image(nsImage: logo)
                    .resizable()
                    .scaledToFit()
                    .frame(height: 34)
                    .accessibilityLabel("Spatie")
            } else {
                Text(verbatim: "Spatie")
                    .font(Typo.heading)
                    .foregroundStyle(Palette.textPrimary)
            }

            Text("A web development company in Antwerp, Belgium, known for its open source work in the PHP and Laravel world.")
                .font(Typo.caption)
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            Link("spatie.be", destination: URL(string: "https://spatie.be")!)
                .font(Typo.caption)
        }
        .padding(.vertical, Metrics.spacingSmall)
    }
}
