import SwiftUI
import BloomCore

/// The one strip of chrome Home has: the controls that decide what the list contains, and what
/// came back.
///
/// **What this replaced, and why.** Home used to open with a page header: the Mac's icon at thirty
/// points, the machine name set in title2 bold, a subtitle under it, and a large filled "New
/// workspace" capsule at the trailing edge. Every one of those is a web convention rather than a
/// Mac one. A Mac window states what it is in its title bar and offers its primary action in its
/// toolbar, and this window already does both: the window's own title names what is showing, and
/// `BloomWindowToolbar` puts a `+` split button on the leading edge that opens the same sheet. The
/// header was a second title bar drawn inside the content, two hundred points below the real one,
/// and the capsule was the same command offered twice in one window.
///
/// What is left is the part that could not move: three controls that only make sense against this
/// list, and the count they change. They sit in a single accessory strip on the chrome colour, at
/// `Metrics.barHeight`, which is what the sidebar's status bar and the inspector's tab row are.
/// The strip is the same piece of furniture in all three places, so Home stops looking like a
/// different app in the same window.
///
/// It does not scroll. The list under it is hundreds of rows on a real install, and a strip that
/// leaves the screen takes the search field and the state of the filters with it, which is how a
/// user ends up staring at eleven rows wondering where the rest went.
struct HomeBar: View {
    /// What the list adds up to, worked out by `HomeView`. Empty means there is nothing to say.
    var summary: String
    var repos: [Repo]
    var archivedCount: Int
    @Binding var filter: HomeFilter

    @FocusState private var fieldFocused: Bool

    var body: some View {
        HStack(spacing: Metrics.spacing) {
            field
            projectMenu
            archivedToggle

            Spacer(minLength: Metrics.gutter)

            // Trailing, and the whole reason the count is still on screen at all: it describes the
            // list rather than the database whenever the two differ, so it has to sit with the
            // controls that made them differ. A forgotten filter is only obvious if the number it
            // changed is an inch away from it.
            //
            // First to be given up when the pane is narrow. The controls are how the user gets out
            // of a narrowed list; the readout only explains it.
            if !summary.isEmpty {
                Text(summary)
                    .font(Typo.caption)
                    .foregroundStyle(Palette.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(-1)
                    .accessibilityLabel("Showing \(summary)")
            }
        }
        .padding(.horizontal, HomeMetrics.gutter)
        .frame(height: Metrics.barHeight)
        // The chrome colour with the pane's top edge already drawn on it, which is what every
        // other strip of small controls in this window stands on.
        .tabStripMaterial()
    }

    // MARK: - Search

    /// Hand built rather than `.searchable`, which on macOS puts the field in the window's toolbar.
    /// The toolbar belongs to the window and is shared with the transcript and the inspector, so a
    /// field that appeared in it would look like it searched all of them.
    ///
    /// The placeholder is one word. It was a sentence naming all three things the search looks at,
    /// which is a fine thing to say once and a poor thing to have permanently occupying three
    /// hundred points of a control strip; it is now the accessibility label and the tooltip, where
    /// it is available to anyone who asks and in the way of nobody who does not.
    private var field: some View {
        HStack(spacing: Metrics.spacingSmall) {
            Image(systemName: "magnifyingglass")
                .font(Typo.caption)
                .foregroundStyle(Palette.textTertiary)
                .accessibilityHidden(true)

            TextField("Search", text: $filter.query)
                .textFieldStyle(.plain)
                .font(Typo.label)
                .foregroundStyle(Palette.textPrimary)
                .focused($fieldFocused)
                .onExitCommand { clear() }

            if !filter.query.isEmpty {
                Button("Clear the search", systemImage: "xmark.circle.fill", action: clear)
                    .labelStyle(.iconOnly)
                    .font(Typo.caption)
                    .foregroundStyle(Palette.textTertiary)
                    .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, Metrics.spacing)
        .frame(width: Self.fieldWidth, height: Self.fieldHeight)
        .background(Palette.surfaceSunken, in: RoundedRectangle(cornerRadius: Metrics.cornerSmall))
        // A hand-built field gets no focus ring from AppKit, and a text field that looks
        // identical whether or not it has the keyboard is the single most reliable way to make a
        // Mac window feel like a web page. `keyboardFocusIndicatorColor` is the same colour the
        // system draws, and it follows Full Keyboard Access and Increase Contrast with it.
        .overlay {
            RoundedRectangle(cornerRadius: Metrics.cornerSmall)
                .stroke(
                    fieldFocused ? Palette.focusRing : Palette.border,
                    lineWidth: fieldFocused ? Self.focusRingWidth : Metrics.hairline
                )
        }
        .help(Self.searchDescription)
        .accessibilityLabel(Self.searchDescription)
    }

    private static let searchDescription = "Search workspaces, branches and projects"

    /// Drawn inside the field's own edge rather than outside it, which is where AppKit puts a real
    /// one. A ring outside would have to be given clearance by the strip, and a two point inner
    /// stroke reads as the same signal at this size.
    private static let focusRingWidth: CGFloat = 2

    /// A small control's height, so the field sits inside the strip with the same clearance the
    /// menu and the toggle beside it have rather than filling it edge to edge.
    private static let fieldHeight: CGFloat = 22
    /// Enough for a branch name typed in full and no more. It was 360, which is not a control any
    /// more, it is a column.
    private static let fieldWidth: CGFloat = 220

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
        case 0: "All projects"
        case 1: name(of: filter.projects.first)
        default: "\(filter.projects.count) projects"
        }
    }

    private func name(of id: RepoID?) -> String {
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

    /// A hide, not a show, and that is the whole of what changed here.
    ///
    /// This was "Archived" / "Showing archived", off by default, and the list it governed left
    /// every archived workspace out until somebody found the button. Home is the only screen in
    /// the app that lists an archived workspace at all, so that default made the one place they
    /// exist the one place they could not be seen. Home now opens on everything, and a switch
    /// whose only power is to add rows nobody hid has no job left: what is worth keeping is the
    /// other direction, for the machine where a year of finished work buries the four things
    /// still being worked in.
    ///
    /// The two labels are deliberately different kinds of phrase. At rest it offers the action,
    /// because showing everything is simply what Home does and there is no state there worth
    /// announcing. Turned on it reports the state, because rows are missing and something on this
    /// strip has to say so.
    ///
    /// The label carries that on its own because nothing else here can. Measured off a window
    /// capture, a small button-style toggle's filled plate is a step of grey away from its resting
    /// one and the filled `archivebox` differs from the outlined one by a few pixels of tray: with
    /// one fixed label, a filter that is hiding a third of the machine's work looks exactly like
    /// one that is not. This control used to change its words too, and that was the signal doing
    /// the work rather than the fill. The readout at the end of the strip still counts what is
    /// being held back, but it is at the other end of the strip, and a filter you cannot see is
    /// how somebody comes to report that their workspaces have disappeared.
    private var archivedToggle: some View {
        Toggle(isOn: $filter.hidesArchived) {
            Label(
                filter.hidesArchived ? "Archived hidden" : "Hide archived",
                systemImage: filter.hidesArchived ? "archivebox.fill" : "archivebox"
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
                : "Leave the \(count(archivedCount, "archived workspace")) out of the list"
        )
    }

    private func count(_ value: Int, _ noun: String) -> String {
        value == 1 ? "1 \(noun)" : "\(value) \(noun)s"
    }

    // MARK: - Actions

    private func clear() {
        filter.query = ""
        fieldFocused = true
    }
}
