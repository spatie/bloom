import SwiftUI
import BloomCore

/// The word above the project sections, and the one button that starts one.
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
    var onStartProject: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: Metrics.spacing) {
            Text("Projects")
                .font(Typo.captionEmphasis)
                .foregroundStyle(Palette.textSecondary)
                .accessibilityAddTraits(.isHeader)

            Spacer(minLength: Metrics.spacingSmall)

            // A button, where it was a menu with New Project and Add Project Folder on it. The
            // owner's objection to that menu was that it made him choose before he had said
            // anything, and he was right: both items ended in a project in the sidebar, and which
            // of the two a folder needs is Bloom's to work out from the folder. See
            // `StartProjectSheet`, and `ProjectTargetVerdict` for the rule that decides.
            //
            // Lit on hover rather than revealed by it, and drawn exactly as the per-project `+`
            // is, so the sidebar has one convention for a header's button rather than two.
            Button(action: onStartProject) {
                Label(MenuBarCatalogue[.startProject].title, systemImage: "folder.badge.plus")
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
            .buttonStyle(.plain)
            .foregroundStyle(isHovered ? Palette.textPrimary : Palette.textSecondary)
            // No key equivalent of its own, and the title comes from `MenuBarCatalogue` so this
            // and the File menu cannot name one action two ways. Registering the key here as well
            // would be a second binding on a hidden control that wins over the menu bar's and
            // announces nothing. See `BloomCommands`, and `MenuCommand` for where the keys really
            // live.
            .help("Start a project (⌥⌘N)")
        }
        .contentShape(Rectangle())
        .onHoverChange { isHovered = $0 }
    }
}
