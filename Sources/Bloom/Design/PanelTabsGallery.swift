import SwiftUI
import BloomCore

/// `PanelTabs`, at the width it really opens at, in the states it is really in, and inside the
/// panel it was written for.
///
/// It exists because the control it replaced shipped with three faults that one look would have
/// caught and no test could: a selected cell in the system accent beside a panel of Bloom's teal,
/// a strip that stopped short of the right edge because a segmented control sizes to its content,
/// and a label clipped rather than truncated when there was not room. None of the three is visible
/// from the tests, the panel is a popover so the window probes cannot open it, and two of them are
/// about width, which is exactly what a picture answers and a ratio does not.
///
///     Bloom --snapshot-gallery <dir> --gallery panel-tabs
///
/// The bottom half is the strip on its own at four widths, down to one narrower than its own two
/// labels, because "does it truncate or does it clip" was the fault nobody could name from the
/// screenshot. Hover is drawn by handing the strip a fixed hovered cell rather than by pretending
/// to move a pointer, which offscreen there is none of.
struct PanelTabsGallery: View {
    var app: AppModel

    private static let panelWidth: CGFloat = 460

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.pane) {
            HStack(alignment: .top, spacing: Metrics.pane) {
                captioned("The panel, on the tab that cuts a branch") {
                    panel(tab: .newBranch)
                }
                captioned("The panel, on the tab that carries one on") {
                    panel(tab: .existingBranch)
                }
            }

            captioned("The strip alone, at four widths") {
                VStack(alignment: .leading, spacing: Metrics.spacingWide) {
                    ForEach([Self.panelWidth - Metrics.gutter * 2, 320, 220, 150], id: \.self) {
                        width in
                        strip(width: width)
                    }
                }
            }

            HStack(alignment: .top, spacing: Metrics.pane) {
                captioned("Resting, nothing under the pointer") {
                    strip(width: 300)
                }
                captioned("The pointer on the cell that is not chosen") {
                    strip(width: 300, hovering: true)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(Metrics.pane)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Palette.surface)
        .environment(app)
    }

    /// The whole head of the panel, drawn from the real strip and the real sentence, so the two
    /// things this pass changed are photographed together: the strip reaching both gutters, and
    /// both explanations sitting on one line so the search row does not move when the tab does.
    private func panel(tab: WorkspaceSourceTab) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            PanelTabsHarness(tab: tab)
                .padding(.horizontal, Metrics.gutter)
                .padding(.vertical, Metrics.spacingWide)

            Text(tab.explanation)
                .font(Typo.caption)
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, Metrics.gutter)
                .padding(.bottom, Metrics.spacingWide)

            Hairline()

            HStack(spacing: Metrics.spacing) {
                Image(systemName: "magnifyingglass")
                    .imageScale(.small)
                    .foregroundStyle(Palette.textTertiary)
                Text(tab.searchPlaceholder)
                    .font(Typo.body)
                    .foregroundStyle(Palette.textPlaceholder)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Metrics.gutter)
            .padding(.vertical, Metrics.spacingSmall)
            .frame(height: Metrics.rowHeight)

            Hairline()
        }
        .frame(width: Self.panelWidth)
        // The popover's own plate, since a popover's chrome is not here to draw it.
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: Metrics.corner + 2))
        .overlay {
            RoundedRectangle(cornerRadius: Metrics.corner + 2)
                .strokeBorder(Palette.border, lineWidth: Metrics.hairline)
        }
    }

    private func strip(width: CGFloat, hovering: Bool = false) -> some View {
        PanelTabsHarness(tab: .newBranch, hovering: hovering ? .existingBranch : nil)
            .frame(width: width)
    }

    private func captioned(_ caption: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: Metrics.spacingWide) {
            Text(caption)
                .font(Typo.caption)
                .foregroundStyle(Palette.textTertiary)
            content()
        }
    }
}

/// A strip with somewhere for its binding to point, and with a hovered cell that can be stated
/// rather than pointed at.
///
/// The hover is a real `onHover`, and offscreen there is no pointer to fire one, so the state a
/// reviewer most needs to see is the one that cannot be photographed. This drives the same view
/// through the same code and posts the hover itself.
private struct PanelTabsHarness: View {
    var tab: WorkspaceSourceTab
    var hovering: WorkspaceSourceTab?

    @State private var selection: WorkspaceSourceTab = .newBranch

    var body: some View {
        PanelTabs(
            "Start from",
            tabs: WorkspaceSourceTab.allCases,
            selection: $selection,
            title: { $0.title },
            hovering: hovering
        )
        .onAppear { selection = tab }
    }
}

extension Gallery {
    /// The registry entry for this page. See `Gallery`.
    ///
    /// No field is being typed into, so it needs nobody's keyboard.
    static let panelTabs = Gallery(
        name: "panel-tabs",
        title: "Panel tabs",
        size: CGSize(width: 1040, height: 780),
        needsFocus: false,
        view: { app in AnyView(PanelTabsGallery(app: app)) }
    )
}
