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

/// Asking the user for a project folder. Wrapped so the two places that need it (the sidebar's
/// add button and Home's empty state) cannot drift apart on panel configuration.
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

/// The left column: who you are, where you can go, every project with its workspaces, and a
/// footer that stays put.
///
/// It is a `ScrollView` over a `LazyVStack` rather than a `List` on purpose. A `List` insists on
/// its own row insets, selection tint and separator rules, and every one of those fights the
/// 26pt rows and the hover treatment the rest of Baton uses.
struct SidebarView: View {
    @Environment(AppModel.self) private var app

    /// One hover id for the entire list. See `WorkspaceRow` for why this is not per row.
    @State private var hovered: String?
    @State private var renaming: String?
    @State private var filter: SidebarFilter = .all
    @State private var isShowingLegend = false

    var body: some View {
        VStack(spacing: 0) {
            accountRow
            navigation

            ScrollView {
                LazyVStack(spacing: 1, pinnedViews: .sectionHeaders) {
                    projectsHeader

                    ForEach(app.repos) { repo in
                        RepoSection(
                            repo: repo,
                            filter: filter,
                            hovered: $hovered,
                            renaming: $renaming,
                            onCreateWorkspace: { presentCreate(in: $0) }
                        )
                    }

                    if app.repos.isEmpty, app.isLoaded {
                        emptyProjects
                    }
                }
                .padding(.bottom, 8)
            }
            .scrollContentBackground(.hidden)

            Hairline()
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.sidebar)
    }

    // MARK: - Account

    private var accountRow: some View {
        Menu {
            Button("Add project…") { addProject() }
            Button("Refresh changes") { Task { await app.refreshDiffStats() } }
            Divider()
            SettingsLink { Text("Settings…") }
        } label: {
            HStack(spacing: 8) {
                ZStack {
                    Circle().fill(Palette.accent.opacity(0.18))
                    Text(initials)
                        .font(Typo.captionEmphasis)
                        .foregroundStyle(Palette.accent)
                }
                .frame(width: 20, height: 20)

                Text(NSFullUserName())
                    .font(Typo.bodyEmphasis)
                    .foregroundStyle(Palette.textPrimary)
                    .lineLimit(1)

                Spacer(minLength: 4)

                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(Palette.textTertiary)
            }
            .padding(.horizontal, 6)
            .frame(height: 30)
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .padding(.horizontal, 8)
        .padding(.top, 6)
    }

    private var initials: String {
        let parts = NSFullUserName()
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
        let letters = parts.prefix(2).compactMap { $0.first }
        return letters.isEmpty ? "?" : String(letters).uppercased()
    }

    // MARK: - Navigation

    private var navigation: some View {
        VStack(spacing: 1) {
            navRow(id: "nav:home", title: "Home", icon: "house", isSelected: app.selection == .home) {
                renaming = nil
                app.selection = .home
            }
            navRow(id: "nav:create", title: "Create", icon: "plus", isSelected: false) {
                // No repo, so RootView falls back to whatever is selected.
                presentCreate(in: nil)
            }
            navRow(id: "nav:search", title: "Search", icon: "magnifyingglass", isSelected: app.selection == .search) {
                renaming = nil
                app.selection = .search
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, 4)
        .padding(.bottom, 8)
    }

    private func navRow(
        id: String,
        title: String,
        icon: String,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(isSelected ? Palette.accent : Palette.textSecondary)
                .frame(width: 14)
            Text(title)
                .font(isSelected ? Typo.bodyEmphasis : Typo.body)
                .foregroundStyle(isSelected ? Palette.textPrimary : Palette.textSecondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .frame(height: Metrics.rowHeight)
        .rowBackground(isSelected: isSelected, isHovered: hovered == id)
        .contentShape(Rectangle())
        .onHoverChange { inside in
            hovered = inside ? id : (hovered == id ? nil : hovered)
        }
        .onTapGesture(perform: action)
    }

    // MARK: - Projects

    private var projectsHeader: some View {
        HStack(spacing: 2) {
            Text("Projects")
                .font(Typo.micro)
                .foregroundStyle(Palette.textTertiary)
                .textCase(.uppercase)

            Spacer(minLength: 4)

            Menu {
                Picker("Filter", selection: $filter) {
                    ForEach(SidebarFilter.allCases, id: \.self) { option in
                        Text(option.rawValue).tag(option)
                    }
                }
                .pickerStyle(.inline)
            } label: {
                Image(systemName: filter == .all ? "line.3.horizontal.decrease" : filter.icon)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(filter == .all ? Palette.textTertiary : Palette.accent)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 18)
            .help("Filter workspaces")

            Button {
                addProject()
            } label: {
                Image(systemName: "folder.badge.plus")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Palette.textTertiary)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Add a project folder")
        }
        .padding(.horizontal, 14)
        .frame(height: 22)
        .background(Palette.sidebar)
    }

    private var emptyProjects: some View {
        VStack(spacing: 6) {
            Text("No projects yet")
                .font(Typo.label)
                .foregroundStyle(Palette.textSecondary)
            Button("Add a folder") { addProject() }
                .buttonStyle(.borderless)
                .font(Typo.label)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 4) {
            statusChip

            Spacer(minLength: 4)

            Button {
                isShowingLegend.toggle()
            } label: {
                footerIcon("questionmark.circle")
            }
            .buttonStyle(.plain)
            .help("What the sidebar glyphs mean")
            .popover(isPresented: $isShowingLegend, arrowEdge: .top) {
                legend
            }

            // The deployment target is macOS 15, so `SettingsLink` is always available and there
            // is no need for the older `showSettingsWindow:` selector dance.
            SettingsLink {
                footerIcon("gearshape")
            }
            .buttonStyle(.plain)
            .help("Settings")
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(Palette.sidebar)
    }

    private func footerIcon(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Palette.textTertiary)
            .frame(width: 20, height: 20)
            .contentShape(Rectangle())
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
                Image(systemName: "circle.fill").font(.system(size: 7))
            }
            legendRow(Palette.warning, "Setup script failed") {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 10))
            }
            legendRow(Palette.textTertiary, "Idle, on its own branch") {
                Image(systemName: "arrow.triangle.branch").font(.system(size: 10))
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

    /// The create sheet lives in `RootView`, so every entry point (this button, the repo header's
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
