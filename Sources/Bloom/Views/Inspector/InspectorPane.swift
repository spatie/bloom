import SwiftUI

/// The inspector column's stable root: what the agent changed, with the terminal panel under it.
///
/// Structural stability is the whole point of this type. When the inspector's content was written
/// inline as `if let model { InspectorView(...).inspectorColumnWidth(...) }`, the column width
/// modifier itself came and went as the selection resolved, so AppKit kept adding and removing the
/// column's constraints and recreating the hosted platform view. That is an unbounded Update
/// Constraints loop, and it crashed the window. Here the pane is always the same view, the width
/// is always applied, and only what is drawn inside changes.
///
/// The panel sits here rather than under the transcript because setup output, run scripts and
/// shells are all things you watch while reading a diff, not while reading the conversation.
struct InspectorPane: View {
    let model: WorkspaceModel?

    @Environment(AppModel.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Survives relaunch, for the same reason the inspector's width does: a panel that forgets how
    /// tall you made it is worse than one that cannot be resized at all.
    @AppStorage("inspector.panelHeight") private var panelHeight: Double = InspectorPane.defaultHeight

    /// What the column has to divide between the files and the panel. Measured rather than assumed,
    /// because the ceiling on the panel is whatever still leaves the file list usable, and that
    /// moves with the window.
    @State private var columnHeight: Double = 0

    /// Roughly fifteen lines of terminal, which is enough to watch a build without burying the
    /// files above it.
    private static let defaultHeight: Double = 260
    /// Below these the pane on either side of the divider stops being worth drawing: a few file
    /// rows above, a few terminal lines below. The files' floor counts the pull request strip and
    /// the tab row above the list, which is two bars of it before a single row is drawn.
    private static let minimumFiles: Double = 220
    private static let minimumPanel: Double = 120

    /// The ceiling follows the window, so the stored height is clamped on the way out as well as
    /// during a drag. A panel dragged tall on a large display must not eat the whole column when
    /// the same window opens small.
    private var bounds: ClosedRange<Double> {
        Self.minimumPanel ... max(Self.minimumPanel, columnHeight - Self.minimumFiles)
    }

    /// The stored height, kept inside what the window can currently give it.
    private var currentHeight: CGFloat {
        CGFloat(panelHeight.clamped(to: bounds))
    }

    var body: some View {
        VStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if let model {
                // The boundary belongs to whichever pane owns the split, so the panel does not draw
                // its own rule. Collapsed there is nothing to size, so the grab strip would only be
                // a cursor change over a dead target.
                if app.isBottomPanelVisible {
                    PaneDivider(
                        axis: .vertical,
                        length: $panelHeight,
                        bounds: bounds,
                        reset: Self.defaultHeight,
                        label: "Terminal panel height"
                    )
                } else {
                    Hairline()
                }

                // Collapsed, the panel keeps its tab strip, which is why the closed height is the
                // strip's rather than zero. Both ends are a real number so there is something to
                // interpolate: against `nil` for the collapsed state SwiftUI has no two heights to
                // move between, and the panel jumped rather than slid.
                //
                // Aligned to the top, so the strip rides the panel's top edge up and down and the
                // panel reads as sliding out of the bottom of the window. The sunken fill is
                // applied outside the frame rather than inside the panel, so the strip has
                // somewhere to slide over while the panel is shorter than the space it is leaving.
                BottomPanelView(model: model)
                    .frame(
                        height: app.isBottomPanelVisible ? currentHeight : Metrics.barHeight,
                        alignment: .top
                    )
                    .background(Palette.surfaceSunken)
                    .clipped()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Keyed on the visibility alone, so dragging the divider and clamping to a shorter window
        // both stay instant.
        .animation(reduceMotion ? nil : Motion.pane, value: app.isBottomPanelVisible)
        .onGeometryChange(for: Double.self) { Double($0.size.height) } action: { columnHeight = $0 }
    }

    @ViewBuilder
    private var content: some View {
        if let model {
            InspectorView(model: model)
                // Rebuilt per workspace, so a diff selection never leaks across a switch.
                .id(model.workspace.id)
        } else {
            EmptyStateView(
                glyph: "sidebar.right",
                title: "No workspace selected",
                message: "Pick a workspace to see what its agent changed."
            )
        }
    }
}
