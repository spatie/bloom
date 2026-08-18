import SwiftUI
import AppKit
import BloomCore

/// The two fixed rows above Home's list: who this is and what it adds up to, then the controls
/// that decide what the list contains.
///
/// They do not scroll. The list under them is hundreds of rows on a real install, and a heading
/// that leaves the screen takes the search field and the state of the filters with it, which is
/// how a user ends up staring at eleven rows wondering where the rest went.
struct HomeHeader: View {
    var summary: String
    var repos: [Repo]
    var archivedCount: Int
    /// Whether there is anything for the controls to act on. A search field, a project filter and
    /// an archived switch over an empty machine are three controls that cannot change what is on
    /// screen, sitting directly above a panel explaining that there is nothing on screen.
    var showsControls: Bool
    @Binding var filter: HomeFilter
    var onCreateWorkspace: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.inset) {
            heading
            if showsControls {
                HomeControls(repos: repos, archivedCount: archivedCount, filter: $filter)
            }
        }
        .padding(.horizontal, Metrics.pane)
        .padding(.top, Metrics.inset)
        .padding(.bottom, Metrics.inset)
    }

    // MARK: - Heading

    /// The machine, not the person.
    ///
    /// Conductor puts the user's account picture and "<name>'s Mac" here. Bloom is single user and
    /// entirely local: there is no second account to distinguish this one from, so an avatar
    /// identifies nothing and the only honest reading of an identity in this window is which
    /// machine the worktrees are on. That is a fact worth stating (the same repository is cloned on
    /// more than one Mac, and a screenshot of Home should say which one it was taken on) and it
    /// costs nothing to read. Nothing here goes near the agent config files: those hold live
    /// credentials, and a machine name is not something they would be asked for anyway.
    private var heading: some View {
        HStack(alignment: .center, spacing: Metrics.gutter) {
            if let icon = Self.machineIcon {
                Image(nsImage: icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: Self.machineIconSize, height: Self.machineIconSize)
                    .accessibilityHidden(true)
            }

            VStack(alignment: .leading, spacing: Metrics.spacingTight) {
                Text(Self.machineName)
                    .font(.title2)
                    .bold()
                    .foregroundStyle(Palette.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .accessibilityAddTraits(.isHeader)

                Text(summary)
                    .font(Typo.caption)
                    .foregroundStyle(Palette.textSecondary)
                    .lineLimit(1)
            }

            Spacer(minLength: Metrics.gutter)

            // No `font` of its own: a large bordered button already picks the weight and size
            // AppKit uses at that control size, and overriding it desynchronises the label from
            // the capsule drawn around it. Called "New workspace" rather than Conductor's "Create
            // workspace" because that is what the toolbar, the sidebar and the menu bar all call
            // the same sheet.
            Button("New workspace", systemImage: "plus", action: onCreateWorkspace)
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
        }
    }

    private static let machineIconSize: CGFloat = 30

    /// The system's own picture of a Mac, at whatever the current model is. Resolved once: it is
    /// an icon lookup, and it does not change while the app is running.
    private static let machineIcon: NSImage? = NSImage(named: NSImage.computerName)

    /// "Freek Van der Herten's Mac", as set in Sharing settings. Falls back to the network host
    /// name, and then to something that is at least not empty.
    private static let machineName: String = {
        if let name = Host.current().localizedName, !name.isEmpty { return name }
        let host = ProcessInfo.processInfo.hostName
        return host.isEmpty ? "This Mac" : host
    }()
}

/// The row under the heading: a search field, a project filter and the archived switch.
struct HomeControls: View {
    var repos: [Repo]
    var archivedCount: Int
    @Binding var filter: HomeFilter

    @FocusState private var fieldFocused: Bool

    var body: some View {
        HStack(spacing: Metrics.spacingWide) {
            field
            Spacer(minLength: Metrics.spacingWide)
            projectMenu
            archivedToggle
        }
    }

    // MARK: - Search

    /// Hand built rather than `.searchable`, which on macOS puts the field in the window's toolbar.
    /// The toolbar belongs to the window and is shared with the transcript and the inspector, so a
    /// field that appeared in it would look like it searched all of them.
    private var field: some View {
        HStack(spacing: Metrics.spacing) {
            Image(systemName: "magnifyingglass")
                .font(Typo.caption)
                .foregroundStyle(Palette.textTertiary)
                .accessibilityHidden(true)

            TextField("Search workspaces, branches and projects", text: $filter.query)
                .textFieldStyle(.plain)
                .font(Typo.body)
                .foregroundStyle(Palette.textPrimary)
                .focused($fieldFocused)
                .onExitCommand { clear() }

            if !filter.query.isEmpty {
                Button("Clear the search", systemImage: "xmark.circle.fill", action: clear)
                    .labelStyle(.iconOnly)
                    .font(Typo.caption)
                    .foregroundStyle(.tertiary)
                    .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, Metrics.spacingWide)
        .frame(minHeight: Self.controlHeight)
        .background(Palette.surfaceSunken, in: RoundedRectangle(cornerRadius: Metrics.corner))
        .overlay {
            RoundedRectangle(cornerRadius: Metrics.corner)
                .stroke(Palette.border, lineWidth: Metrics.hairline)
        }
        .frame(maxWidth: Self.fieldWidth)
    }

    private static let controlHeight: CGFloat = 26
    /// A search field wider than this stops looking like a control and starts looking like the
    /// page, and the space is better spent on the row of workspaces underneath.
    private static let fieldWidth: CGFloat = 360

    // MARK: - Projects

    /// A real menu with real toggles rather than a hand-drawn checklist. Seventeen projects is a
    /// scrolling menu for free, every row is reachable by keyboard and by Voice Control, and the
    /// checkmarks are AppKit's rather than a column of drawn ticks that has to be kept in step
    /// with the selection by hand.
    ///
    /// `.menuStyle(.button)` because a borderless `Menu` on macOS throws a custom label away and
    /// draws only the chevron, which is what the sidebar's account row used to look like.
    private var projectMenu: some View {
        Menu {
            Toggle("All projects", isOn: allProjects)

            if !repos.isEmpty {
                Divider()
                ForEach(repos) { repo in
                    Toggle(repo.name, isOn: binding(for: repo))
                }
            }
        } label: {
            Label(projectLabel, systemImage: "folder")
                .lineLimit(1)
        }
        .menuStyle(.button)
        .controlSize(.small)
        .fixedSize()
        .help("Choose which projects Home lists")
        .accessibilityLabel("Project filter, \(projectLabel)")
    }

    /// The label says what is filtered, always. A filter you cannot see is the reason someone
    /// files a bug about workspaces having disappeared.
    private var projectLabel: String {
        switch filter.projects.count {
        case 0: "In all projects"
        case 1: "In \(name(of: filter.projects.first ?? ""))"
        default: "In \(filter.projects.count) projects"
        }
    }

    private func name(of id: String) -> String {
        repos.first { $0.id == id }?.name ?? "1 project"
    }

    /// Turning "All projects" on clears the set; turning it off is refused, because the state it
    /// would leave behind (nothing chosen, nothing shown, and a menu whose every row is off) has
    /// no way back that is not another click on this same row.
    private var allProjects: Binding<Bool> {
        Binding(
            get: { filter.projects.isEmpty },
            set: { isOn in if isOn { filter.projects = [] } }
        )
    }

    private func binding(for repo: Repo) -> Binding<Bool> {
        Binding(
            get: { filter.projects.contains(repo.id) },
            set: { isOn in
                if isOn {
                    filter.projects.insert(repo.id)
                } else {
                    filter.projects.remove(repo.id)
                }
            }
        )
    }

    // MARK: - Archived

    /// Three signals rather than one, because an archived workspace looks exactly like a live one
    /// at a glance: the button says "Showing archived" rather than "Archived", a button-style
    /// toggle draws itself filled while it is on, and the box fills in. The rows themselves are
    /// dimmed and carry the same box, and the summary line above counts them.
    private var archivedToggle: some View {
        Toggle(isOn: $filter.showsArchived) {
            Label(
                filter.showsArchived ? "Showing archived" : "Archived",
                systemImage: filter.showsArchived ? "archivebox.fill" : "archivebox"
            )
            .lineLimit(1)
        }
        .toggleStyle(.button)
        .controlSize(.small)
        .fixedSize()
        .disabled(archivedCount == 0)
        .help(
            archivedCount == 0
                ? "Nothing has been archived yet"
                : "Show the \(archivedCount) archived workspaces in the list too"
        )
    }

    // MARK: - Actions

    private func clear() {
        filter.query = ""
        fieldFocused = true
    }
}
