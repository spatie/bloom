import SwiftUI
import AppKit
import BatonCore

/// What the Projects filter is currently letting through. Kept deliberately small: the sidebar is
/// a place to find one workspace fast, not a query builder.
enum SidebarFilter: String, CaseIterable, Hashable {
    case all = "All workspaces"
    case unread = "Unread"
    case changed = "With changes"

    func accepts(_ workspace: Workspace) -> Bool {
        switch self {
        case .all: true
        case .unread: workspace.unread
        case .changed: workspace.hasDiff
        }
    }

    var icon: String {
        switch self {
        case .all: "line.3.horizontal.decrease"
        case .unread: "circle.fill"
        case .changed: "plusminus"
        }
    }
}

/// Asking the user for a project folder. Wrapped so the places that need it (the toolbar, the
/// sidebar's empty state and Home's empty state) cannot drift apart on panel configuration.
@MainActor
enum ProjectFolderPicker {
    static func choose() -> String? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.prompt = "Add project"
        panel.message = "Choose the git repository you want to run agents in."
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return url.path
    }
}

/// The left column: where you can go, every project with its workspaces, and a status bar that
/// stays put.
///
/// A real `List` with `.listStyle(.sidebar)`, not a `ScrollView` over a `LazyVStack`. The list
/// brings the source list treatment that was previously hand-drawn and always slightly wrong:
/// AppKit selection (accent when the window is key, grey when it is not), disclosure triangles on
/// section headers, the standard row insets, and keyboard navigation between rows.
///
/// There is no account row. Baton is local and single user, so a row naming the logged-in Mac
/// user said nothing, and on macOS `Menu { } label: { }` with `.borderlessButton` throws the
/// custom label away and draws only the indicator, which is why it rendered as a lone letter.
struct SidebarView: View {
    @Environment(AppModel.self) private var app

    /// One hover id for the entire list. See `WorkspaceRow` for why this is not per row.
    @State private var hovered: String?
    @State private var renaming: String?
    @State private var filter: SidebarFilter = .all
    @State private var isShowingLegend = false

    var body: some View {
        List(selection: selection) {
            Section {
                navRow(.home, title: "Home", icon: "house")
                navRow(.search, title: "Search", icon: "magnifyingglass")
            }

            ForEach(app.repos) { repo in
                RepoSection(
                    repo: repo,
                    filter: filter,
                    hovered: $hovered,
                    renaming: $renaming,
                    onCreateWorkspace: { presentCreate(in: $0) }
                )
            }
        }
        .listStyle(.sidebar)
        .overlay {
            if app.repos.isEmpty, app.isLoaded {
                noProjects
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { statusBar }
        // Moving off a row has to close whatever field was open on it, or the rename would carry
        // on editing a workspace that is no longer on screen.
        .onChange(of: app.selection) { _, _ in renaming = nil }
    }

    // MARK: - Selection

    /// The list works in optionals because clicking empty space deselects. Baton always has
    /// somewhere to be, so an empty selection is ignored rather than written back.
    private var selection: Binding<SidebarSelection?> {
        Binding(
            get: { app.selection },
            // Nothing else is written here on purpose. This setter runs inside the table's own
            // selection callback, and touching view state from there is what AppKit means by a
            // reentrant delegate operation. Closing an open rename field is left to the
            // `onChange` below, which SwiftUI runs after the update has finished.
            set: { newValue in
                guard let newValue else { return }
                app.selection = newValue
            }
        )
    }

    private func navRow(_ target: SidebarSelection, title: String, icon: String) -> some View {
        Label(title, systemImage: icon)
            .tag(target)
    }

    // MARK: - Empty

    private var noProjects: some View {
        ContentUnavailableView {
            Label("No projects yet", systemImage: "folder.badge.plus")
        } description: {
            Text("Point Baton at a git repository to start running agents in it.")
        } actions: {
            Button("Add a Folder") { addProject() }
                .buttonStyle(.borderedProminent)
        }
    }

    // MARK: - Status bar

    /// The filter lives down here rather than in a header, which is where Xcode and Finder put
    /// the controls that narrow a source list.
    private var statusBar: some View {
        VStack(spacing: 0) {
            Divider()

            HStack(spacing: 4) {
                statusChip

                Spacer(minLength: 4)

                Menu {
                    Picker("Filter", selection: $filter) {
                        ForEach(SidebarFilter.allCases, id: \.self) { option in
                            Label(option.rawValue, systemImage: option.icon).tag(option)
                        }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Image(systemName: filter == .all ? "line.3.horizontal.decrease" : filter.icon)
                        .foregroundStyle(filter == .all ? Palette.textSecondary : Palette.accent)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Filter workspaces")

                Button {
                    isShowingLegend.toggle()
                } label: {
                    Image(systemName: "questionmark.circle")
                }
                .buttonStyle(.borderless)
                .help("What the sidebar glyphs mean")
                .popover(isPresented: $isShowingLegend, arrowEdge: .top) {
                    legend
                }

                // The deployment target is macOS 15, so `SettingsLink` is always available and
                // there is no need for the older `showSettingsWindow:` selector dance.
                SettingsLink {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.borderless)
                .help("Settings")
            }
            .imageScale(.medium)
            .foregroundStyle(Palette.textSecondary)
            .padding(.horizontal, 10)
            .frame(height: 28)
        }
        .background(.bar)
    }

    private var statusChip: some View {
        let running = app.runningCount
        return Chip(
            text: running == 0 ? "Idle" : "\(running) running",
            systemImage: running == 0 ? "moon.zzz" : "bolt.fill",
            tint: running == 0 ? Palette.textTertiary : Palette.running
        )
    }

    private var legend: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Workspace states")
                .font(Typo.captionEmphasis)
                .foregroundStyle(Palette.textSecondary)

            legendRow(Palette.running, "An agent is working") {
                ActivityDot(isActive: true)
            }
            legendRow(Palette.accent, "Finished, not read yet") {
                Image(systemName: "circle.fill").font(Typo.micro)
            }
            legendRow(Palette.warning, "Setup script failed") {
                Image(systemName: "exclamationmark.triangle.fill").font(Typo.caption)
            }
            legendRow(Palette.textTertiary, "Idle, on its own branch") {
                Image(systemName: "arrow.triangle.branch").font(Typo.caption)
            }
        }
        .padding(12)
        .frame(width: 220)
    }

    private func legendRow<Glyph: View>(
        _ tint: Color,
        _ text: String,
        @ViewBuilder glyph: () -> Glyph
    ) -> some View {
        HStack(spacing: 8) {
            glyph()
                .foregroundStyle(tint)
                .frame(width: 13, height: 13)
            Text(text)
                .font(Typo.caption)
                .foregroundStyle(Palette.textSecondary)
            Spacer(minLength: 0)
        }
    }

    // MARK: - Actions

    /// The create sheet lives in `RootView`, so every entry point (the toolbar, the repo header's
    /// `+`, the menu bar command) goes through one notification and behaves identically.
    private func presentCreate(in repo: Repo?) {
        renaming = nil
        NotificationCenter.default.post(name: .batonNewWorkspace, object: repo)
    }

    private func addProject() {
        guard let path = ProjectFolderPicker.choose() else { return }
        Task { await app.addRepository(at: path) }
    }
}
