import SwiftUI

/// The word above the project sections, and the button that adds one.
///
/// It exists because adding a project was reachable only from the arrow of the toolbar's `+`
/// split button and from Settings, neither of which is where anyone looks for it in an app whose
/// empty state is "Add your first project".
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
    var onAddProject: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: Metrics.spacing) {
            Text("Projects")
                .font(Typo.captionEmphasis)
                .foregroundStyle(Palette.textSecondary)
                .accessibilityAddTraits(.isHeader)

            Spacer(minLength: Metrics.spacingSmall)

            // Lit on hover rather than revealed by it, and drawn exactly as the per-project `+`
            // is, so the sidebar has one convention for a header's button rather than two.
            Button(action: onAddProject) {
                Label("Add project", systemImage: "folder.badge.plus")
                    .labelStyle(.iconOnly)
                    .font(Typo.label)
                    .frame(
                        width: SidebarMetrics.headerButton.width,
                        height: SidebarMetrics.headerButton.height
                    )
                    .contentShape(RoundedRectangle(cornerRadius: Metrics.cornerSmall))
                    .background(
                        isHovered ? Palette.hover : .clear,
                        in: RoundedRectangle(cornerRadius: Metrics.cornerSmall)
                    )
            }
            .buttonStyle(.plain)
            .foregroundStyle(isHovered ? Palette.textPrimary : Palette.textSecondary)
            // The shortcut hangs off the button rather than off `BloomCommands`, which is where a
            // menu bar item would carry it. Command Option A collides with nothing Bloom binds
            // (Command Option I, B, Up and Down are the others) and with nothing macOS reserves.
            .keyboardShortcut("a", modifiers: [.command, .option])
            .help("Add a project folder (⌥⌘A)")
        }
        .contentShape(Rectangle())
        .onHoverChange { isHovered = $0 }
    }
}
