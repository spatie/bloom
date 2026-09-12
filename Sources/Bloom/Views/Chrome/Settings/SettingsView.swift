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

/// A stable sidebar keeps every category discoverable as settings are added.
struct SettingsView: View {
    @Environment(AppModel.self) private var app
    @State private var tab: SettingsTab? = Snapshot.requestedSettingsTab ?? .general
    @State private var defaults = AppDefaults()
    @State private var isLoaded = false
    @State private var saveTask: Task<Void, Never>?
    @State private var saveError: String?

    var body: some View {
        // A fixed sidebar avoids the split view's collapsible toolbar and its reserved top inset.
        HStack(spacing: 0) {
            List(selection: $tab) {
                Section("Bloom") {
                    navigationRows([.general, .appearance, .menuBar, .notifications])
                }
                Section("Agents") {
                    navigationRows([.agents, .sessions, .permissions, .prompts])
                }
                Section("Terminal & connections") {
                    navigationRows([.terminal, .commandLine])
                }
            }
            .listStyle(.sidebar)
            .frame(width: 185)
            // The menu bar's "Menubar Settings…" names the pane it wants; without this the window
            // opens on whichever pane it was left on, which is not what that row promises.
            .onReceive(NotificationCenter.default.publisher(for: SettingsTabRequest.name)) { notification in
                if let requested = SettingsTabRequest.tab(in: notification) { tab = requested }
            }

            Divider()

            VStack(spacing: 0) {
                if let saveError {
                    ErrorBanner(title: "Could not save settings", message: saveError) {
                        self.saveError = nil
                    }
                    .padding(Metrics.inset)
                }
                pane
                    .frame(maxWidth: 680)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
            .background(Palette.windowBackground)
        }
        .navigationTitle((tab ?? .general).title)
        .frame(minWidth: 780, idealWidth: 850, minHeight: 560, idealHeight: 700)
        .task {
            guard !isLoaded, let store = app.store else { return }
            defaults = await AppDefaults.load(from: store)
            isLoaded = true
        }
    }

    private var defaultsBinding: Binding<AppDefaults> {
        Binding(get: { defaults }, set: { updated in
            guard isLoaded, let store = app.store else { return }
            let previous = defaults
            defaults = updated
            // Keep rapid edits in order, even when the user switches panes before a write finishes.
            let pending = saveTask
            saveTask = Task {
                await pending?.value
                do {
                    try await updated.saveChanges(from: previous, to: store)
                    saveError = nil
                } catch {
                    saveError = error.readableMessage
                }
            }
        })
    }

    private func navigationRows(_ tabs: [SettingsTab]) -> some View {
        ForEach(tabs, id: \.self) { item in
            Label(item.title, systemImage: item.systemImage)
                .tag(item)
        }
    }

    @ViewBuilder
    private var pane: some View {
        switch tab ?? .general {
        case .general: GeneralSettingsView()
        case .appearance: AppearanceSettingsView()
        case .menuBar: MenuBarSettingsView(app: app)
        case .notifications: NotificationSettingsView()
        case .agents: AgentsSettingsView()
        case .sessions: ModelSettingsView(defaults: defaultsBinding).disabled(!isLoaded)
        case .permissions: ApprovalSettingsView(defaults: defaultsBinding, isReady: isLoaded)
        case .prompts: PromptSettingsView()
        case .terminal: TerminalSettingsView()
        case .commandLine: CommandLineSettingsView()
        }
    }
}

struct GeneralSettingsView: View {
    @AppStorage("confirmBeforeArchiving") private var confirmBeforeArchiving = true
    @AppStorage(MenuBarStatusItem.settingKey) private var showsMenuBarStatus = MenuBarStatusItem.isOnByDefault
    @State private var namesWorkspaces = WorkspaceNamingPreferences().isEnabled

    var body: some View {
        Form {
            Section("Everyday behaviour") {
                Toggle("Confirm before archiving", isOn: $confirmBeforeArchiving)
                Toggle(isOn: $showsMenuBarStatus) {
                    Text("Show agent status in the menu bar")
                    Text("See which agents are working or waiting for you.")
                }
            }

            DirectorySettingsSection()

            SleepSettingsSection()

            Section("Workspaces") {
                Toggle(isOn: $namesWorkspaces) {
                    Text("Name workspaces automatically")
                    Text("Claude uses your first message to suggest a name, without accessing your code.")
                }
                .onChange(of: namesWorkspaces) { _, value in
                    WorkspaceNamingPreferences().isEnabled = value
                }

                SettingsRow("Location") {
                    VStack(alignment: .leading, spacing: Metrics.spacingSmall) {
                        HStack(spacing: Metrics.gutter) {
                            Text((WorkspaceManager.workspacesRoot.path as NSString).abbreviatingWithTildeInPath)
                                .font(Typo.codeSmall)
                                .foregroundStyle(Palette.textSecondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .textSelection(.enabled)
                                .help(WorkspaceManager.workspacesRoot.path)
                            Spacer(minLength: 0)
                            Button("Reveal in Finder") {
                                Reveal.inFinder(WorkspaceManager.workspacesRoot.path)
                            }
                        }
                        DisclosureGroup("Folder details") {
                            Text(WorkspacesRoot.note(for: WorkspaceManager.workspacesRoot))
                                .settingsFootnote()
                        }
                    }
                }
            }

            UpdateSettingsSection()
            InstallPingSettingsSection()
            CrashReportingSettingsSection()
        }
        .settingsForm()
    }
}
