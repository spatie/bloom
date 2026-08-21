import SwiftUI

/// The strip pinned to the bottom of the sidebar: what is running, and the three controls that
/// narrow or explain the list.
///
/// The filter lives down here rather than in a header, which is where Xcode and Finder put the
/// controls that narrow a source list.
struct SidebarStatusBar: View {
    @Environment(AppModel.self) private var app

    @Binding var filter: SidebarFilter
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
                    Picker("Filter", selection: $filter) {
                        ForEach(SidebarFilter.allCases, id: \.self) { option in
                            Label(option.rawValue, systemImage: option.icon).tag(option)
                        }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Label(
                        "Filter workspaces",
                        systemImage: filter == .all ? "line.3.horizontal.decrease" : filter.icon
                    )
                }
                // Icon only visually, but the label is still there for VoiceOver and Voice
                // Control, and the tint says whether a filter is in force.
                .labelStyle(.iconOnly)
                .menuStyle(.button)
                .buttonStyle(.accessoryBar)
                .menuIndicator(.hidden)
                .fixedSize()
                .tint(filter == .all ? Palette.textSecondary : Palette.accent)
                .help("Filter workspaces")
                .accessibilityValue(filter.rawValue)

                Button("What the sidebar glyphs mean", systemImage: "questionmark.circle") {
                    isShowingLegend.toggle()
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.accessoryBar)
                .help("What the sidebar glyphs mean")
                .popover(isPresented: $isShowingLegend, arrowEdge: .top) {
                    SidebarLegend()
                }

                SettingsLink {
                    Label("Settings", systemImage: "gearshape")
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.accessoryBar)
                .help("Settings")
            }
            .padding(.horizontal, Metrics.spacingSmall)
            .frame(height: Metrics.barHeight)
        }
        .background(.bar)
    }

    /// A readout, so it is set as text rather than as the filled `Chip` it used to be. A pill in a
    /// status bar reads as a control that does nothing when clicked, and this one sits beside three
    /// controls that really are clickable.
    private var status: some View {
        let running = app.runningCount
        // A drag that could not land where it was let go borrows this line rather than raising
        // anything of its own. It is the one place in the pane that already talks about the pane,
        // a workspace being kept in its project is exactly that kind of fact, and an alert or a
        // toast for a drop that went one row further than it could would be an answer several
        // sizes too big for the question.
        return Label(
            note ?? (running == 0 ? "Idle" : "\(running) running"),
            systemImage: note != nil
                ? "arrow.uturn.backward"
                : (running == 0 ? "moon.zzz" : "bolt.fill")
        )
        .font(Typo.caption)
        .foregroundStyle(noteInk ?? (running == 0 ? Palette.textTertiary : Palette.running))
        .padding(.leading, Metrics.spacing)
        .lineLimit(1)
        .accessibilityLabel(
            note ?? (running == 0 ? "No agents running" : "\(running) agents running")
        )
    }

    /// Secondary ink, one step up from the idle readout it stands in for and well short of a
    /// warning colour. Nothing went wrong: a row was put where it was allowed to go.
    private var noteInk: Color? {
        note == nil ? nil : Palette.textSecondary
    }
}
