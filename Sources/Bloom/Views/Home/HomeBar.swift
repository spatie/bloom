import SwiftUI
import BloomCore

/// The one strip of chrome Home has: which chip is lit, which projects are listed, and what the
/// answer adds up to.
///
/// **What came off it, and why the strip is glass now.** It used to hold a hand built search field
/// with a hand drawn focus ring, a project menu, a "Hide archived" toggle and the readout. The
/// field is gone: the window has a real `NSSearchToolbarItem` in its toolbar, which is where
/// Finder and Mail publish search, and which draws its own glass and its own focus ring rather
/// than an approximation of both. The toggle is gone too, into `HomeScope.live`, because a
/// narrowing switch beside a set of narrowing chips is two mechanisms for one question.
///
/// What is left floats. A bar of controls over a list that scrolls under it is exactly what a
/// material is for, so this is `.regular` glass in a `GlassEffectContainer` with the chips, which
/// means a chip lighting up is one shape morphing rather than two surfaces disagreeing about the
/// ground they stand on. The rows underneath are not glass and must not be: a row is content, and
/// forty glass rows is noise.
///
/// It does not scroll. The list under it is hundreds of rows on a real install, and a strip that
/// leaves the screen takes the state of the filters with it, which is how a user ends up staring
/// at eleven rows wondering where the rest went.
struct HomeBar: View {
    /// What the list adds up to, worked out by `HomeView`. Empty means there is nothing to say.
    var summary: String
    var repos: [Repo]
    var counts: HomeScopeCounts
    var isSearching: Bool
    @Binding var filter: HomeFilter

    /// The chip under the pointer. Held here rather than in each chip so crossing the strip lights
    /// one at a time, which is the same arrangement Home's rows use.
    @State private var hovered: HomeScope?

    var body: some View {
        // One sampling pass for the strip and every chip on it rather than one each, which is what
        // the container is for. `spacing: 0` so two chips that come close do not merge into one
        // blob, which is the other thing it does.
        GlassEffectContainer(spacing: 0) {
            HStack(spacing: Metrics.spacingSmall) {
                ForEach(HomeScope.offered(searching: isSearching), id: \.self) { scope in
                    chip(scope)
                }

                Spacer(minLength: Metrics.gutter)

                projectMenu

                // Trailing, and the whole reason the count is still on screen at all: it describes
                // the list rather than the database whenever the two differ, so it has to sit with
                // the controls that made them differ.
                //
                // First to be given up when the pane is narrow. The controls are how the user gets
                // out of a narrowed list; the readout only explains it.
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
            .padding(.horizontal, Metrics.spacingWide)
            .frame(height: Self.height)
            .glassEffect(
                .regular, in: RoundedRectangle(cornerRadius: Metrics.corner, style: .continuous)
            )
        }
        .padding(.horizontal, HomeMetrics.gutter)
        .padding(.top, Metrics.inset)
    }

    /// A chip and its clearance above and below. Not `Metrics.barHeight`: this strip floats over
    /// the list rather than being a band ruled off from it, so it is sized by what it holds.
    private static let height: CGFloat = Metrics.controlHeight + Metrics.spacing * 2

    // MARK: - Scopes

    /// One scope, with the number that says what clicking it would show.
    ///
    /// The count is the half that earns the chip its place on the strip. "Needs you 3" answers the
    /// question the window was opened with at a glance, without drawing a second list of the same
    /// rows above the first one.
    private func chip(_ scope: HomeScope) -> some View {
        let isOn = filter.scope == scope
        let count = counts.count(of: scope, searching: isSearching)
        let label = scope.label(searching: isSearching)

        return Button {
            filter.scope = scope
        } label: {
            HStack(spacing: Metrics.spacingSmall) {
                Text(label)
                    .font(Typo.caption)

                Text(count, format: .number)
                    .font(Typo.micro)
                    .monospacedDigit()
                    .foregroundStyle(isOn ? Palette.textInverted.opacity(0.8) : countTint(scope))
            }
            .foregroundStyle(isOn ? Palette.textInverted : Palette.textSecondary)
            .padding(.horizontal, Metrics.spacing)
            .frame(height: Metrics.controlHeight)
            .background(hovered == scope && !isOn ? Palette.hover : .clear, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        // A tinted glass chip is one control, rather than a coloured control standing next to a
        // glass one. `.identity` for the unlit ones rather than dropping the modifier: the shape
        // stays in the container either way, so a chip lighting up morphs instead of appearing,
        // and the strip is already glass, so a second material inside it would be a surface on a
        // surface.
        .glassEffect(isOn ? .regular.tint(Palette.accentFill) : .identity, in: Capsule())
        .onHoverChange { hovered = $0 ? scope : (hovered == scope ? nil : hovered) }
        .accessibilityLabel("\(label), \(count)")
        .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
        .help(help(for: scope))
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
    /// `.menuStyle(.button)` because a borderless `Menu` on macOS throws a custom label away and
    /// draws only the chevron, which is what the sidebar's account row used to look like.
    ///
    /// No glass on it. It is system drawn already, and a material on top of a control that has its
    /// own treatment freezes it at this year's version of that treatment.
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
