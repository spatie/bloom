import AppKit
import SwiftUI
import BloomCore

/// Shared between `BloomApp`, which applies the stored choice at launch, and the Appearance
/// pane, which owns the picker that writes it.
@MainActor
enum AppearancePreference {
    static func apply(_ value: String) {
        // `shared` rather than `NSApp`: the launch call runs in `BloomApp.init`, before SwiftUI
        // has necessarily made the application object, and `NSApp` is nil until something does.
        NSApplication.shared.appearance = switch value {
        case "light": NSAppearance(named: .aqua)
        case "dark": NSAppearance(named: .darkAqua)
        default: nil
        }
    }
}

/// Collects global and repository preferences in one window so configuration stays discoverable.
struct SettingsView: View {
    @Environment(AppModel.self) private var app

    /// Enough for the widest form row without the window feeling like a second main window. Its
    /// own numbers, rather than the sidebar and inspector widths that happened to add up to
    /// something plausible.
    ///
    /// The width is a floor under `SettingsTabRow.width` rather than the answer. 640 held the
    /// forms and was never asked about the twelve tabs above them, and a preference-style toolbar
    /// that does not fit folds its tail behind a `»`, so the window opened with Storage and About
    /// in an overflow menu. See `SettingsTabRow`, which is where the row is measured and where the
    /// part of it that is an estimate is named.
    private static let minSize = CGSize(width: 640, height: 420)

    @MainActor private static var minWidth: CGFloat { max(minSize.width, SettingsTabRow.width) }

    /// Whether there is anything to revoke, which is whether the Approvals tab is drawn at all.
    ///
    /// Read once when the window opens rather than polled: a grant is made by pressing a button in
    /// the main window, so the answer changes at moments this window is not even on screen, and
    /// the tab appearing the next time Settings is opened is soon enough. See `ApprovalSettingsView`
    /// for why the pane has to exist at all.
    @State private var hasGrants = false

    /// Which tab is showing. An enum rather than an index, so the value says what it selects.
    ///
    /// Seeded from the capture harness, which is otherwise stuck on General: the selection lives
    /// here in `@State`, so `--settings` could only ever photograph the first pane and every
    /// other one went in unverified. `Snapshot.requestedSettingsTab` is nil in every ordinary
    /// launch.
    @State private var tab: SettingsTab = Snapshot.requestedSettingsTab ?? .general

    var body: some View {
        TabView(selection: $tab) {
            Tab(SettingsTab.general.title, systemImage: "gear", value: SettingsTab.general) {
                GeneralSettingsView()
            }

            Tab(SettingsTab.appearance.title, systemImage: "paintbrush", value: SettingsTab.appearance) {
                AppearanceSettingsView()
            }

            Tab(SettingsTab.notifications.title, systemImage: "bell", value: SettingsTab.notifications) {
                NotificationSettingsView()
            }

            // **No Projects tab.** It held two things and both live somewhere better. Adding and
            // removing a project is the sidebar's job, where the list you are changing is the list
            // you are looking at; a second copy in a window you had to open first was a list of
            // paths with a minus button. And a project's effective settings already have a window
            // of their own, off the gear on its row in that sidebar, which knows which project you
            // meant because you pressed it on that project. What was here needed a selector before
            // it could say anything, and the selector was the panel nobody needed.
            Tab(SettingsTab.models.title, systemImage: "sparkle", value: SettingsTab.models) {
                ModelSettingsView()
            }

            Tab(SettingsTab.agents.title, systemImage: "person.2", value: SettingsTab.agents) {
                AgentsSettingsView()
            }

            Tab(SettingsTab.prompts.title, systemImage: "text.bubble", value: SettingsTab.prompts) {
                PromptSettingsView()
            }

            // **Only once there is something to revoke.** It holds state the user created, one
            // row per "always allow" they have ever pressed, and it is the thing that makes
            // granting a rule forever safe to offer at all: a grant nobody can find is a grant
            // nobody can take back. But until the first one exists it is a tab explaining a list
            // that is empty, and this window has spent tonight losing exactly those.
            //
            // It appears the moment a grant does. `grantCount` is read once when the window opens
            // and again whenever the store says the grants moved, rather than polled.
            if hasGrants {
                Tab(SettingsTab.approvals.title, systemImage: "hand.raised", value: SettingsTab.approvals) {
                    ApprovalSettingsView()
                }
            }

            // Grouped only to get under `TabView`'s builder limit, which is ten children and was
            // exactly reached before the Command Line pane arrived. `Group` conforms to `TabContent`,
            // so this changes the tab bar not at all, and it is where a new pane goes now that
            // the limit is spent.
            Group {
            // **No Tools tab.** It listed the absolute paths of git and gh, read-only, which
            // answers "which git is Bloom using" and nothing else. That is a real question and a
            // rare one, and a tool that is missing is already said where it matters rather than
            // filed behind a tab beside Models and Prompts.

                // Beside Command Line rather than beside Agents, because both of these are about
                // something outside this Mac reaching in or being reached: a CLI the owner runs
                // themselves, and a machine Bloom drives over SSH. The Agents pane is about the
                // binaries on THIS machine.
                Tab(SettingsTab.servers.title, systemImage: "server.rack", value: SettingsTab.servers) {
                    ServerSettingsView()
                }

                // After Tools rather than beside Agents: the Agents pane is about the CLIs Bloom
                // launches, and this is the one arrangement where a CLI Bloom did not launch
                // reaches in the other way round.
                Tab(SettingsTab.commandLine.title, systemImage: "terminal", value: SettingsTab.commandLine) {
                    CommandLineSettingsView()
                }

                // **There was a Storage pane here and it has gone into Home.** It listed every
                // archived workspace with its project, its branch, its age and its size, which is
                // the list Home's Archived chip was already drawing with everything but the size
                // on it: the same objects on two screens with different columns. Home carries the
                // size, the order and both totals now, and this window has no pane that can
                // destroy anything.
            }

            // **No About tab.** `AboutWindow` is the About, it is what the Bloom menu opens, and
            // `BloomCommands` goes to the trouble of `replacing: .appInfo` to make sure of it. A
            // second one in Settings said the same four facts a scroll away from the first.
            //
            // One row here was not about the app: the GitHub account. It has moved to General,
            // which is where a fact about the person using Bloom belongs rather than filed under
            // the app's version and its maker.
        }
        .frame(minWidth: Self.minWidth, minHeight: Self.minSize.height)
        .task {
            guard let store = app.store else { return }
            hasGrants = !((try? await store.permissionGrants()) ?? []).isEmpty
        }
        // No tint. The selected tab is the last system-accent control in this window, and
        // `.tint(Palette.accent)` on this TabView was tried and measured: the label came out
        // `#397CE1` with it and `#397CE1` without it, identical pixels in the same capture. The
        // toolbar-style TabView is an `NSToolbar` whose selection colour nothing here can reach,
        // and it is also the control in this window closest to being genuinely the system's
        // chrome. So it is left alone, and this note is here so the next person does not spend
        // the same hour discovering the same nothing. `InspectorToolbar` has the same story about
        // a segmented control.
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

            InstallPingSettingsSection()

            SettingsRow("New workspaces") {
                VStack(alignment: .leading, spacing: Metrics.spacingSmall) {
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

                    // One sentence, and no notice anywhere else. An install that already has a
                    // root gets none of the indexing benefit and can only find that out from the
                    // row that names its folder; an install that has the new one is being told
                    // why its path looks like that. Neither is worth a banner or a migration.
                    Text(WorkspacesRoot.note(for: WorkspaceManager.workspacesRoot))
                        .settingsFootnote()
                }
            }

            // From the About pane, which has gone. It was the one row there that was not about
            // the app: who Bloom is talking to GitHub as, which is a fact about the person using
            // it rather than about the version or its maker.
            SettingsRow("GitHub user") {
                Text(GitHubIdentity.cachedUsername ?? "Not resolved")
                    .font(Typo.codeSmall)
                    .foregroundStyle(Palette.textSecondary)
            }
        }
        .settingsForm()
    }
}

/// Pairs editable project metadata with the effective layered settings developers need to debug.
private struct ProjectSettingsView: View {
    @Environment(AppModel.self) private var app
    /// This window raises its own copy of the offer. `RootView` presents the one belonging to the
    /// main window, and `Binding.on` keeps a request from appearing on both at once.
    @Bindable private var projectSetup = ProjectSetup.shared
    @State private var selectedRepoID: RepoID?
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
        .settingsForm()
        .onAppear {
            if selectedRepoID == nil { selectedRepoID = app.repos.first?.id }
        }
        .onChange(of: app.repos) { _, repos in
            if !repos.contains(where: { $0.id == selectedRepoID }) {
                selectedRepoID = repos.first?.id
            }
        }
        // Through `ProjectRemoval` like the other two, and with a visible title like the other
        // two: this was the one of the three that drew the dialog headless.
        .confirmationDialog(
            repoPendingRemoval.map(removal)?.title ?? "",
            isPresented: $repoPendingRemoval.isPresent(),
            titleVisibility: .visible,
            presenting: repoPendingRemoval
        ) { repo in
            Button(removal(repo).confirmLabel, role: .destructive) { remove(repo) }
            Button(removal(repo).cancelLabel, role: .cancel) {}
        } message: { repo in
            Text(removal(repo).message)
        }
        .sheet(item: $projectSetup.request.on(.settings)) { request in
            ProjectSetupSheet(request: request) { path in
                Task { await app.finishProjectSetup(path) }
            }
        }
    }

    /// The one question, asked here and in the sidebar and in the project's own window. See
    /// `ProjectRemoval`.
    private func removal(_ repo: Repo) -> Confirmation {
        app.projectRemoval(repo)
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
    /// without it each of those frames is a SQLite write, which is now also a change published to
    /// everything watching the store and a reload of the sidebar behind it. The project settings
    /// window has the same binding and the same guard.
    private var accentBinding: Binding<Color> {
        Binding(
            get: { Color(hexString: repo.accent) },
            set: { color in
                guard let hex = color.hexString, hex != repo.accent else { return }
                Task {
                    guard let store = app.store else { return }
                    _ = try? await store.update(repoID: repo.id) { $0.accent = hex }
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
            SettingsRow("Configuration") {
                Button("Open Project Settings") {
                    Reveal.inEditor(
                        (repo.path as NSString).appendingPathComponent(".conductor/settings.toml"),
                        repo: repo.id
                    )
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
        SettingsRow(title) {
            Text(value)
                .font(Typo.codeSmall)
                .foregroundStyle(Palette.textSecondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A script this project resolves to, read only.
///
/// Its title above it rather than beside it, which is the one thing on this pane that is not a
/// `SettingsRow`. A forty line shell script is not a value that belongs in a row's second half at
/// any width: it is code, so it is shown the way the rest of the app shows code, in the editor
/// `ScriptEditor` wraps, left aligned, line numbered, syntax coloured, and bounded so a long
/// script scrolls instead of stretching the pane.
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
