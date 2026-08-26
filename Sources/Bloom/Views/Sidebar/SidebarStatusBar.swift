import SwiftUI
import BloomCore

/// The strip pinned to the bottom of the sidebar: the two controls that narrow or explain the
/// list, and a line the pane borrows when it has something to say about itself.
///
/// The filter lives down here rather than in a header, which is where Xcode and Finder put the
/// controls that narrow a source list.
struct SidebarStatusBar: View {
    @Environment(AppModel.self) private var app

    @Binding var filter: SidebarFilter
    /// Whether the projects the owner has hidden are in the list. A preference rather than this
    /// window's state, which is why it is `@AppStorage` here and in `SidebarView` rather than a
    /// second `@State` passed down. See `ProjectVisibility.showsHiddenKey`.
    @AppStorage(ProjectVisibility.showsHiddenKey) private var showsHiddenProjects = false
    /// Something the pane has to say about itself, for a moment, in place of the running count.
    /// The sidebar owns both the sentence and how long it lasts. See `SidebarView.move(from:to:)`.
    var note: String?

    @State private var isShowingLegend = false

    var body: some View {
        VStack(spacing: 0) {
            Hairline()

            HStack(spacing: Metrics.spacingSmall) {
                status

                Spacer(minLength: Metrics.spacingSmall)

                // All three are `.accessoryBar`, which is the system's own style for a strip of
                // small controls along the edge of a pane. It brings one hit box, one hover fill
                // and one pressed state to the set, where a `.borderless` button beside a
                // `.borderlessButton` menu sized each control to its own glyph and left the gaps
                // between them uneven.
                Menu {
                    SidebarFilterMenuItems(
                        filter: $filter,
                        showsHiddenProjects: $showsHiddenProjects,
                        hiddenCount: ProjectVisibility.hiddenCount(app.repos)
                    )
                } label: {
                    Label(
                        "Filter the sidebar",
                        systemImage: filter == .all ? "line.3.horizontal.decrease" : filter.icon
                    )
                }
                // Icon only visually, but the label is still there for VoiceOver and Voice
                // Control, and the tint says whether the pane is showing something other than its
                // default set. Showing hidden projects lights it as much as narrowing the
                // workspaces does, because both answer the question somebody asks when the pane
                // is not what they expected: is this control doing something.
                .labelStyle(.iconOnly)
                .menuStyle(.button)
                .buttonStyle(.accessoryBar)
                .menuIndicator(.hidden)
                .fixedSize()
                .tint(isDefaultView ? Palette.textSecondary : Palette.accent)
                .help("Filter the sidebar")
                .accessibilityValue(filterValue)

                Button("What the sidebar glyphs mean", systemImage: "questionmark.circle") {
                    isShowingLegend.toggle()
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.accessoryBar)
                .help("What the sidebar glyphs mean")
                .popover(isPresented: $isShowingLegend, arrowEdge: .top) {
                    SidebarLegend()
                }

                // **No Settings cogwheel.** There was one here, and it was the one control in this
                // strip that duplicated something every Mac user already knows: Command-comma, and
                // the Bloom menu. The other two earn their place because neither is reachable any
                // other way, and a third glyph beside them spent the strip's width saying what the
                // menu bar says for free.
            }
            .padding(.horizontal, Metrics.spacingSmall)
            .frame(height: Metrics.barHeight)
        }
        // `Palette.sidebar`, not `.bar`. Home grew a status bar of its own at the foot of the
        // detail column, so these two strips now run side by side across the bottom of the window
        // and have to read as one line rather than as two competing ones. `.bar` is a material: it
        // sat a few units off the column it stands in, and it would have sat a few units off the
        // flat strip next to it. The palette already names one colour for "the sidebar column, the
        // title bar, and every strip of small controls", and this is one of those.
        .background(Palette.sidebar)
    }

    /// Whether the pane is showing what it shows when nothing has been asked of it.
    private var isDefaultView: Bool {
        filter == .all && !showsHiddenProjects
    }

    /// Both halves of the control, in words, since the glyph can only show one of them.
    private var filterValue: String {
        showsHiddenProjects ? "\(filter.rawValue), hidden projects showing" : filter.rawValue
    }

    /// A readout, so it is set as text rather than as the filled `Chip` it used to be. A pill in a
    /// status bar reads as a control that does nothing when clicked, and this one sits beside three
    /// controls that really are clickable.
    /// **The running count went, and the line stayed.**
    ///
    /// It read "Idle" most of the time and "2 running" the rest, and the list above it says both
    /// already: a running workspace carries a glyph and its project carries one too, so the strip
    /// was a second, quieter copy of a fact the reader was already looking at. A permanent readout
    /// of the resting state is a thing the eye learns to skip, and it took the leading end of the
    /// strip to do it.
    ///
    /// What is left is the note, and it is why this is not simply deleted. A drag that could not
    /// land where it was let go borrows this line rather than raising anything of its own: it is
    /// the one place in the pane that talks about the pane, and an alert for a drop that went one
    /// row too far would be an answer several sizes too big for the question. With nothing to say
    /// the strip is now the controls alone.
    @ViewBuilder
    private var status: some View {
        if let note {
            Label(note, systemImage: "arrow.uturn.backward")
                .font(Typo.caption)
                .foregroundStyle(Palette.textSecondary)
                .padding(.leading, Metrics.spacing)
                .lineLimit(1)
                .accessibilityLabel(note)
        }
    }

}
