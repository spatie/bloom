import SwiftUI

/// The tab controls share a glass finish while active and a flatter fill in inactive windows.
struct TabGlassBackground<ShapeType: InsettableShape>: View {
    var shape: ShapeType
    var fill: Color

    @Environment(\.appearsActive) private var appearsActive
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        if appearsActive && !reduceTransparency && contrast != .increased {
            // Preserve the pane colour under clear glass so custom terminal labels stay legible.
            shape.fill(fill.opacity(0.85))
                .glassEffect(.clear, in: shape)
        } else {
            shape.fill(fill.opacity(appearsActive || reduceTransparency || contrast == .increased ? 1 : 0.45))
                .overlay {
                    shape.strokeBorder(
                        Palette.border.opacity(contrast == .increased ? 1 : 0.65),
                        lineWidth: Metrics.outline
                    )
                }
        }
    }
}
