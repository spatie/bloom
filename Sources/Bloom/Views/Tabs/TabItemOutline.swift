import SwiftUI

/// The line around a selected tab.
///
/// It closes the selected tab on all four sides. The bottom edge is deliberate: it keeps the tab
/// visually attached to the strip instead of letting its white fill bleed into the pane below.
///
/// Insettable so it can be drawn with `strokeBorder`. A centred `stroke` puts half its width
/// outside the tab, and the strip sits directly under a unified toolbar, so that half would be
/// painted into the toolbar's inset rather than onto the tab.
struct TabItemOutline: InsettableShape {
    var radius: CGFloat
    /// Whether the leading side is left undrawn, for a tab whose leading edge IS the edge of the
    /// pane. See `TabItemView.isAtPaneEdge`, which is where the measurement is written down.
    var skipsLeadingEdge = false
    var inset: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let box = rect.insetBy(dx: inset, dy: inset)
        var path = Path()

        if skipsLeadingEdge {
            // From the pane's own rule rather than from the inset box, so the top line starts
            // hard against it. Half a point of daylight between the two would be the same
            // mismatch this branch exists to remove, only smaller.
            path.move(to: CGPoint(x: rect.minX, y: box.minY))
        } else {
            path.move(to: CGPoint(x: box.minX, y: rect.maxY))
            path.addArc(
                tangent1End: CGPoint(x: box.minX, y: box.minY),
                tangent2End: CGPoint(x: box.maxX, y: box.minY),
                radius: radius
            )
        }

        path.addArc(
            tangent1End: CGPoint(x: box.maxX, y: box.minY),
            tangent2End: CGPoint(x: box.maxX, y: box.maxY),
            radius: radius
        )
        path.addLine(to: CGPoint(x: box.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: box.minX, y: rect.maxY))
        if !skipsLeadingEdge {
            path.closeSubpath()
        }
        return path
    }

    func inset(by amount: CGFloat) -> Self {
        var copy = self
        copy.inset += amount
        return copy
    }
}
