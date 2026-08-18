import AppKit
import SwiftUI
import BatonCore

/// Connects Baton to the agent CLIs installed on the machine.
///
/// The screen is deliberately read-mostly. Detection, version reading and account facts all come
/// from `AgentCatalog`, which owns both the parsing and the rule that no credential ever leaves
/// those files. This view renders whatever ordered label/value pairs it is handed and never looks
/// at a config file itself, so there is exactly one place where that rule has to hold.
struct AgentsSettingsView: View {
    @Environment(AppModel.self) private var app

    @State private var selection: AgentKind = .claudeCode
    @State private var statuses: [AgentKind: AgentStatus] = [:]
    @State private var overrides: [AgentKind: String] = [:]
    @State private var catalog: AgentCatalog?
    @State private var isLoading = true
    @State private var isRefreshing = false
    @State private var saveFailure: String?
    @State private var pathDraft = ""
    /// Which agent `pathDraft` belongs to. `selection` has already moved on by the time the
    /// change handler runs, so committing against it would file one agent's path under another.
    @State private var draftKind: AgentKind = .claudeCode
    @FocusState private var isEditingPath: Bool

    private var status: AgentStatus? { statuses[selection] }

    var body: some View {
        Form {
            Section {
                Picker("Agent", selection: $selection) {
                    ForEach(AgentKind.allCases) { kind in
                        Text(tabTitle(for: kind))
                            .tag(kind)
                            .accessibilityLabel(kind.label)
                            .accessibilityValue(
                                statuses[kind].map { stateTitle($0.connection) } ?? "Checking"
                            )
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            if let saveFailure {
                Section {
                    ErrorBanner(title: "Could not save", message: saveFailure)
                }
            }

            if isLoading {
                Section {
                    LoadingView("Looking for agent CLIs")
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, Metrics.gutter)
                }
            } else if let status {
                statusSection(status)

                if status.connection == .notInstalled {
                    notInstalledSection
                } else {
                    if !status.details.isEmpty {
                        Section("Details") {
                            ForEach(status.details) { detail in
                                LabeledContent(detail.label) {
                                    Text(detail.value)
                                        .font(Typo.label)
                                        .foregroundStyle(Palette.textSecondary)
                                        .textSelection(.enabled)
                                        .multilineTextAlignment(.trailing)
                                }
                            }
                        }
                    }

                    loginSection
                }

                executableSection(status)
                configurationSection(status)
                capabilitySection
            }
        }
        .formStyle(.grouped)
        .task { await bootstrap() }
        .onChange(of: selection) { _, kind in
            commitPathDraft()
            draftKind = kind
            pathDraft = overrides[kind] ?? ""
        }
    }

    // MARK: - Sections

    private func statusSection(_ status: AgentStatus) -> some View {
        Section {
            HStack(spacing: Metrics.gutter) {
                StateDot(connection: status.connection)

                Text(stateTitle(status.connection))
                    .font(Typo.bodyEmphasis)
                    .foregroundStyle(Palette.textPrimary)

                if let version = status.version {
                    Chip(text: version, monospaced: true)
                }

                Spacer()

                Button("Refresh") {
                    Task { await refresh() }
                }
                .disabled(isRefreshing)
                .accessibilityLabel("Refresh \(selection.label)")
            }
        } header: {
            Text(selection.label)
        }
    }

    /// A missing CLI is the normal state on a fresh machine, so it gets an empty state rather
    /// than the error treatment. The executable field stays visible underneath it, because
    /// pointing Baton at a binary outside PATH is the one repair the user can make from here.
    private var notInstalledSection: some View {
        Section {
            EmptyStateView(
                glyph: "magnifyingglass",
                title: "\(selection.label) was not found",
                message: "Baton looked for \(selection.executableName) on your PATH and did not find it. Install the CLI, or point Baton at the executable below."
            )
            .padding(.vertical, Metrics.gutter)
        }
    }

    private var loginSection: some View {
        Section("Sign in") {
            Button("Run \(selection.loginCommand)", action: runLogin)
            .help("Opens Terminal and runs \(selection.loginCommand). The login flow asks questions, so Baton cannot run it inline.")
        }
    }

    private func executableSection(_ status: AgentStatus) -> some View {
        Section {
            LabeledContent("Executable") {
                HStack(spacing: Metrics.gutter) {
                    TextField(
                        status.executablePath ?? "Not found on PATH",
                        text: $pathDraft
                    )
                    .font(Typo.codeSmall)
                    .focused($isEditingPath)
                    .onSubmit { commitPathDraft() }
                    .onChange(of: isEditingPath) { wasEditing, editing in
                        if wasEditing && !editing { commitPathDraft() }
                    }

                    Button("Choose executable", systemImage: "folder", action: chooseExecutable)
                        .labelStyle(.iconOnly)
                        .help("Choose the \(selection.executableName) executable")
                }
            }

            Button("Use system \(selection.executableName)") {
                pathDraft = ""
                commitPathDraft()
            }
            .disabled(overrides[selection] == nil)
            .help("Clears the override and goes back to whatever is first on your PATH.")
        } header: {
            Text("Location")
        } footer: {
            Text("Leave this empty to use the copy found on your PATH.")
                .font(Typo.caption)
                .foregroundStyle(Palette.textSecondary)
        }
    }

    @ViewBuilder
    private func configurationSection(_ status: AgentStatus) -> some View {
        if let path = status.configPath, let isDirectory = existenceKind(of: path) {
            Section("Configuration") {
                LabeledContent(isDirectory ? "Config folder" : "Config file") {
                    HStack(spacing: Metrics.gutter) {
                        Text(path)
                            .font(Typo.codeSmall)
                            .foregroundStyle(Palette.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.middle)

                        Button("Open") { Reveal.inEditor(path) }

                        Button("Reveal in Finder") { Reveal.inFinder(path) }
                            .buttonStyle(.link)
                    }
                }
            }
        }
    }

    /// Detecting a CLI and being able to drive a workspace with it are two different things, and
    /// only Claude Code can do the second one today. Saying so here is cheaper than letting
    /// someone find out when a workspace refuses to start.
    @ViewBuilder
    private var capabilitySection: some View {
        if !selection.canRunWorkspaces {
            Section {
                HStack(alignment: .top, spacing: Metrics.gutter) {
                    Image(systemName: "info.circle")
                        .foregroundStyle(Palette.textTertiary)

                    Text("Baton can detect and configure \(selection.label), but cannot run a workspace with it yet. Workspaces run on Claude Code.")
                        .font(Typo.label)
                        .foregroundStyle(Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// Nil when the path is gone, otherwise whether it is a directory. Cursor and OpenCode point
    /// at a config directory rather than a file, and the row should not call it a file.
    private func existenceKind(of path: String) -> Bool? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { return nil }
        return isDirectory.boolValue
    }

    // MARK: - Presentation

    private func stateTitle(_ connection: AgentStatus.Connection) -> String {
        switch connection {
        case .connected: "Connected"
        case .installed: "Installed"
        case .notInstalled: "Not installed"
        }
    }

    /// A leading dot in the segment title, so the row of tabs answers "which of these are wired
    /// up" without four clicks. Segmented controls draw their own text colour, so the state is
    /// carried by the glyph rather than by a tint that would be overridden.
    private func tabTitle(for kind: AgentKind) -> String {
        let mark = switch statuses[kind]?.connection {
        case .connected: "\u{25CF} "
        case .installed: "\u{25CB} "
        case .notInstalled, nil: ""
        }
        return mark + kind.label
    }

    // MARK: - Actions

    /// The login flows are interactive, so they cannot run inline. `Reveal.inTerminal` opens a
    /// Terminal window sitting at a path, and the command is appended to that so it runs in the
    /// window the user is now looking at.
    private func runLogin() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        Reveal.inTerminal("\(home) && \(selection.loginCommand)")
    }

    private func chooseExecutable() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.prompt = "Use Executable"
        panel.message = "Choose the \(selection.executableName) executable"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        pathDraft = url.path
        commitPathDraft()
    }

    // MARK: - Loading

    private func bootstrap() async {
        let loaded = await loadOverrides()
        overrides = loaded
        draftKind = selection
        pathDraft = loaded[selection] ?? ""

        let catalog = AgentCatalog(overrides: loaded)
        self.catalog = catalog
        await read(from: catalog)
        isLoading = false
    }

    private func refresh() async {
        guard let catalog else { return }
        isRefreshing = true
        await catalog.invalidate()
        await read(from: catalog)
        isRefreshing = false
    }

    private func read(from catalog: AgentCatalog) async {
        let found = await catalog.statuses()
        statuses = Dictionary(found.map { ($0.kind, $0) }, uniquingKeysWith: { _, latest in latest })
    }

    private func loadOverrides() async -> [AgentKind: String] {
        guard let store = app.store else { return [:] }
        var found: [AgentKind: String] = [:]
        for kind in AgentKind.allCases {
            guard let value = try? await store.setting(Self.overrideKey(kind)) else { continue }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { found[kind] = trimmed }
        }
        return found
    }

    /// Committing on submit and on focus loss rather than on every keystroke keeps a half-typed
    /// path out of the database and out of the detection run.
    private func commitPathDraft() {
        let kind = draftKind
        let trimmed = pathDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let value: String? = trimmed.isEmpty ? nil : trimmed
        guard value != overrides[kind] else { return }

        if let value {
            overrides[kind] = value
        } else {
            overrides.removeValue(forKey: kind)
        }

        let updated = overrides
        Task {
            if let store = app.store {
                do {
                    try await store.setSetting(Self.overrideKey(kind), value)
                    saveFailure = nil
                } catch {
                    saveFailure = "The executable path for \(kind.label) could not be stored."
                }
            } else {
                saveFailure = "The executable path for \(kind.label) could not be stored."
            }

            // A new override changes what detection resolves, so the catalog is rebuilt rather
            // than invalidated: its overrides are fixed at init.
            let catalog = AgentCatalog(overrides: updated)
            self.catalog = catalog
            await read(from: catalog)
        }
    }

    private static func overrideKey(_ kind: AgentKind) -> String {
        "agent.\(kind.rawValue).executablePath"
    }
}

/// The status dot, sized to sit on a text baseline rather than to be noticed on its own.
private struct StateDot: View {
    let connection: AgentStatus.Connection

    var body: some View {
        Circle()
            .fill(tint)
            .frame(width: 8, height: 8)
            .accessibilityHidden(true)
    }

    private var tint: Color {
        switch connection {
        case .connected: Palette.positive
        case .installed: Palette.warning
        case .notInstalled: Palette.textTertiary
        }
    }
}
