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
/// **What went on it.** One control, and only under the Archived chip: whether that list is in
/// date order or in size order. It is the last piece of the Settings > Storage pane, whose
/// Largest/Oldest switch was the only part of it Home had no answer for. See `orderControl`.
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

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Metrics.spacingSmall) {
                Picker("Scope", selection: $filter.scope) {
                    ForEach(HomeScope.offered(searching: isSearching), id: \.self) { scope in
                        Text(title(for: scope))
                            .tag(scope)
                            .accessibilityLabel(accessibilityLabel(for: scope))
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
                .help("Choose which work Home lists")

                Spacer(minLength: Metrics.gutter)

                HStack(spacing: Metrics.spacing) {
                    orderControl
                    projectMenu
                }
            }
            .padding(.horizontal, HomeMetrics.gutter)
            .frame(height: Metrics.barHeight)

            Hairline()
        }
        .background(Palette.sidebar)
    }

    // MARK: - Scopes

    /// One native segmented title, with the number that says what choosing it would show.
    private func title(for scope: HomeScope) -> String {
        let label = scope.label(searching: isSearching)
        guard let badge = counts.badge(of: scope, searching: isSearching) else { return label }
        return "\(label) \(badge)"
    }

    private func accessibilityLabel(for scope: HomeScope) -> String {
        let label = scope.label(searching: isSearching)
        return counts.badge(of: scope, searching: isSearching).map { "\(label), \($0)" } ?? label
    }

    // MARK: - Order

    /// Date order or size order, offered on the Archived chip and on no other.
    ///
    /// **It appears with that chip and goes with it**, which is a control moving on a strip and is
    /// normally the thing not to do. The alternative is a picker present and disabled everywhere
    /// else, which makes the strip permanently wider in order to say "not here" on four screens
    /// out of five. It moves in answer to a click on the chip beside it, which is the one case
    /// where a reader can see why the strip changed.
    ///
    /// A segmented pair rather than a menu, because there are only two and both are worth reading
    /// at rest: a menu would say "Recent" and hide the fact that a size order exists at all, on
    /// the one chip that exists to answer what the archive costs.
    @ViewBuilder
    private var orderControl: some View {
        if HomeOrder.applies(scope: filter.scope, searching: isSearching) {
            Picker("Order", selection: $filter.order) {
                ForEach(HomeOrder.allCases, id: \.self) { order in
                    Text(order.label).tag(order)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .fixedSize()
            .help("Order the archived work by when it finished, or by what it still holds")
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
