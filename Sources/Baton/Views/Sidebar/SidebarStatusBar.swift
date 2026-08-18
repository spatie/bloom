import SwiftUI

/// The strip pinned to the bottom of the sidebar: what is running, and the three controls that
/// narrow or explain the list.
///
/// The filter lives down here rather than in a header, which is where Xcode and Finder put the
/// controls that narrow a source list.
struct SidebarStatusBar: View {
    @Environment(AppModel.self) private var app

    @Binding var filter: SidebarFilter

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

                // The deployment target is macOS 15, so `SettingsLink` is always available and
                // there is no need for the older `showSettingsWindow:` selector dance.
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
        return Label(
            running == 0 ? "Idle" : "\(running) running",
            systemImage: running == 0 ? "moon.zzz" : "bolt.fill"
        )
        .font(Typo.caption)
        .foregroundStyle(running == 0 ? Palette.textTertiary : Palette.running)
        .padding(.leading, Metrics.spacing)
        .accessibilityLabel(running == 0 ? "No agents running" : "\(running) agents running")
    }
}
