import SwiftUI
import BloomCore

/// The one strip of chrome above Home's list: which chip is lit, and which projects are listed.
///
/// **What came off it.** It used to hold a hand built search field with a hand drawn focus ring, a
/// project menu, a "Hide archived" toggle and a readout of what the list added up to. The field is
/// gone: the window has a real `NSSearchToolbarItem` in its toolbar, which is where Finder and Mail
/// publish search. The toggle is gone into `HomeScope.live`, because a narrowing switch beside a
/// set of narrowing chips is two mechanisms for one question. And the readout is gone down to
/// `HomeStatusBar` at the foot of the pane: a count belongs beside the thing it counts, and this
/// bar was carrying five chips, a picker and a sentence at one weight, so nothing on it led.
///
/// **It was glass and it is not any more.** It was a `GlassEffectContainer` with `.regular` on the
/// strip and a tinted chip for the selected one, floating over the list on its own rounded plate.
/// The owner's words were "Bloom doesn't need that glassy stuff behind it", and he is right about
/// this app in particular: Bloom's ground is a stated ramp rather than a material, the whole
/// argument for which is on `Palette`, and a strip that samples what is under it is the one
/// surface in the window whose colour nobody chose.
///
/// So it is a band of `Palette.sidebar` with a rule under it, which is what the palette already
/// names for "the sidebar column, the title bar, and every strip of small controls". Because the
/// title bar is that same colour, the band reads as attached to it rather than as a plate floating
/// over the rows, which is where Finder puts a scope bar and where Safari puts its favourites.
///
/// It does not scroll. The list under it is hundreds of rows on a real install, and a strip that
/// leaves the screen takes the state of the filters with it, which is how a user ends up staring
/// at eleven rows wondering where the rest went.
struct HomeBar: View {
    var repos: [Repo]
    var counts: HomeScopeCounts
    var isSearching: Bool
    @Binding var filter: HomeFilter

    /// The chip under the pointer. Held here rather than in each chip so crossing the strip lights
    /// one at a time, which is the same arrangement Home's rows use.
    @State private var hovered: HomeScope?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Metrics.spacingSmall) {
                ForEach(HomeScope.offered(searching: isSearching), id: \.self) { scope in
                    chip(scope)
                }

                Spacer(minLength: Metrics.gutter)

                projectMenu
            }
            .padding(.horizontal, HomeMetrics.gutter)
            .frame(height: Metrics.barHeight)

            Hairline()
        }
        .background(Palette.sidebar)
    }

    // MARK: - Scopes

    /// One scope, with the number that says what clicking it would show.
    ///
    /// **A chip at nought draws no number.** The strip read "Needs you 0, Running 0" at rest, which
    /// is the state most of the time, so the noughts were what the eye learned to skip and the two
    /// numbers that matter got skipped with them. See `HomeScopeCounts.badge`.
    private func chip(_ scope: HomeScope) -> some View {
        let isOn = filter.scope == scope
        let badge = counts.badge(of: scope, searching: isSearching)
        let label = scope.label(searching: isSearching)

        return Button {
            filter.scope = scope
        } label: {
            HStack(spacing: Metrics.spacingSmall) {
                Text(label)
                    .font(Typo.caption)

                if let badge {
                    Text(badge, format: .number)
                        .font(Typo.micro)
                        .monospacedDigit()
                        .foregroundStyle(isOn ? Palette.textInverted.opacity(0.8) : countTint(scope))
                }
            }
            .foregroundStyle(isOn ? Palette.textInverted : Palette.textSecondary)
            .padding(.horizontal, Metrics.spacing)
            .frame(height: Metrics.controlHeight)
            .background(fill(isOn: isOn, isHovered: hovered == scope), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHoverChange { hovered = $0 ? scope : (hovered == scope ? nil : hovered) }
        .accessibilityLabel(badge.map { "\(label), \($0)" } ?? label)
        .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
        .help(help(for: scope))
    }

    /// The selected chip is filled with Bloom's own accent rather than tinted glass, which is the
    /// same fill an emphasized selection uses everywhere else in the window.
    private func fill(isOn: Bool, isHovered: Bool) -> Color {
        if isOn { return Palette.accentFill }
        return isHovered ? Palette.hover : .clear
    }

    /// The one chip whose number is worth noticing before it is read. Everything else on the strip
    /// is a count; this one is a queue with a person at the end of it.
    private func countTint(_ scope: HomeScope) -> Color {
        scope == .needsYou && counts.needsYou > 0 ? Palette.warning : Palette.textTertiary
    }

    private func help(for scope: HomeScope) -> String {
        switch scope {
        case .all:
            isSearching ? "Every kind of result" : "Everything on this Mac, archived work included"
        case .needsYou: "An agent has asked something, or a finished turn has not been read"
        case .running: "An agent is mid turn"
        case .live: "Still has a worktree on disk"
        case .archived: "Archived: readable, restorable, with nothing left on disk"
        case .workspaces: "Matched by name, branch or project"
        case .transcripts: "Matched in what the agents said"
        }
    }

    // MARK: - Projects

    /// A real menu with real toggles rather than a hand-drawn checklist. Seventeen projects is a
    /// scrolling menu for free, every row is reachable by keyboard and by Voice Control, and the
    /// checkmarks are AppKit's rather than a column of drawn ticks that has to be kept in step
    /// with the selection by hand.
    ///
    /// **It stays up here rather than going down to the status bar with the counts.** It changes
    /// what the list shows, and a status bar is a place for reading rather than pressing: Finder's
    /// says how many items there are and offers nothing to click.
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
}
