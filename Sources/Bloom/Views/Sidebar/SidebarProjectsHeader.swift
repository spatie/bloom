import SwiftUI
import BloomCore

/// The word above the project sections, and the button that adds one.
///
/// It exists because adding a project was reachable only from the arrow of the toolbar's `+`
/// split button and from Settings, neither of which is where anyone looks for it in an app whose
/// empty state is "No projects yet".
///
/// Three ranks now run down this column and they have to be told apart at a glance in 260 points:
/// this group label at 11 medium in secondary ink, a project at 13 semibold in primary ink with
/// its own coloured tile, and a workspace at 13 regular. The step from the group to the project
/// is a size step, the step from the project to its workspaces is a weight and a colour step. A
/// group label set larger than the projects under it would have inverted the whole thing, which
/// is the mistake the per-project header was making before this change.
///
/// No filter here, though there is one in `SidebarStatusBar`. That control filters WORKSPACES by
/// state, so hanging it off a heading that says Projects would label it as something it is not,
/// and a second one would be two filters for one list. It stays at the foot of the pane, which is
/// where Xcode and Finder put the control that narrows a source list.
struct SidebarProjectsHeader: View {
    var onNewProject: () -> Void
    var onAddProject: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: Metrics.spacing) {
            Text("Projects")
                .font(Typo.captionEmphasis)
                .foregroundStyle(Palette.textSecondary)
                .accessibilityAddTraits(.isHeader)

            Spacer(minLength: Metrics.spacingSmall)

            // A menu rather than a button, because there are two things to do here and they are
            // not the same act with two names: New makes a folder and a repository for somebody
            // who has an idea, Add takes a repository that already exists. This control said Add
            // for as long as it existed, which is the word that only means anything to the second
            // of the two.
            //
            // Lit on hover rather than revealed by it, and drawn exactly as the per-project `+`
            // is, so the sidebar has one convention for a header's button rather than two.
            Menu {
                Button(MenuBarCatalogue[.newProject].title, action: onNewProject)
                Button(MenuBarCatalogue[.addProjectFolder].title, action: onAddProject)
            } label: {
                Label("New or add a project", systemImage: "folder.badge.plus")
                    .labelStyle(.iconOnly)
                    .font(Typo.label)
                    .frame(
                        width: Metrics.headerButton.width,
                        height: Metrics.headerButton.height
                    )
                    .contentShape(RoundedRectangle(cornerRadius: Metrics.cornerSmall))
                    .background(
                        isHovered ? Palette.hover : .clear,
                        in: RoundedRectangle(cornerRadius: Metrics.cornerSmall)
                    )
            }
            // `.button` over `.plain` rather than `.borderlessButton`, for the reason
            // `WorkspaceRow`'s ellipsis has written down and measured: a borderless menu draws its
            // label in an ink of its own and ignores the colour it is given, wherever that colour
            // is stated, so the hover lift below would have moved the background and left the
            // glyph where it was.
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .foregroundStyle(isHovered ? Palette.textPrimary : Palette.textSecondary)
            // Neither row carries a key equivalent of its own, and the titles come from
            // `MenuBarCatalogue` so this and the File menu cannot name one action two ways. A
            // `Menu` in a view cannot fire a key equivalent anyway, and registering one here as
            // well would be a second binding on a hidden control that wins over the menu bar's
            // and announces nothing. See `BloomCommands`, and `MenuCommand` for where the keys
            // really live.
            .help("New project (⌥⌘N), or add a project folder (⇧⌘O)")
        }
        .contentShape(Rectangle())
        .onHoverChange { isHovered = $0 }
    }
}
