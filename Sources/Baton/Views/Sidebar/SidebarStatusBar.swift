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
            Divider()

            HStack(spacing: Metrics.spacingSmall) {
                statusChip

                Spacer(minLength: Metrics.spacingSmall)

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
                    .foregroundStyle(filter == .all ? Palette.textSecondary : Palette.accent)
                }
                // Icon only visually, but the label is still there for VoiceOver and Voice
                // Control, and the tint says whether a filter is in force.
                .labelStyle(.iconOnly)
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Filter workspaces")
                .accessibilityValue(filter.rawValue)

                Button("What the sidebar glyphs mean", systemImage: "questionmark.circle") {
                    isShowingLegend.toggle()
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
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
                .buttonStyle(.borderless)
                .help("Settings")
            }
            .imageScale(.medium)
            .foregroundStyle(Palette.textSecondary)
            .padding(.horizontal, Metrics.inset)
            .frame(height: Metrics.barHeight)
        }
        .background(.bar)
    }

    private var statusChip: some View {
        let running = app.runningCount
        return Chip(
            text: running == 0 ? "Idle" : "\(running) running",
            systemImage: running == 0 ? "moon.zzz" : "bolt.fill",
            tint: running == 0 ? Palette.textTertiary : Palette.running
        )
        .accessibilityLabel(running == 0 ? "No agents running" : "\(running) agents running")
    }
}
