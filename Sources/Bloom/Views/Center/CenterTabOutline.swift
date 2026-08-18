import SwiftUI

/// The line around a tab's top and two sides, with nothing along the bottom.
///
/// Stroking the fill shape would close the rectangle, and the bottom of that rectangle lands
/// exactly where the strip's own rule is: the selected tab would be boxed in again by the very
/// line its opaque fill exists to break. Three sides and a stop keeps the tab running into the
/// pane below it, which is what says this is a tab and not a button.
///
/// Insettable so it can be drawn with `strokeBorder`. A centred `stroke` puts half its width
/// outside the tab, and the strip sits directly under a unified toolbar, so that half would be
/// painted into the toolbar's inset rather than onto the tab.
struct CenterTabOutline: InsettableShape {
    var radius: CGFloat
    var inset: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let box = rect.insetBy(dx: inset, dy: inset)
        var path = Path()
        path.move(to: CGPoint(x: box.minX, y: rect.maxY))
        path.addArc(
            tangent1End: CGPoint(x: box.minX, y: box.minY),
            tangent2End: CGPoint(x: box.maxX, y: box.minY),
            radius: radius
        )
        path.addArc(
            tangent1End: CGPoint(x: box.maxX, y: box.minY),
            tangent2End: CGPoint(x: box.maxX, y: box.maxY),
            radius: radius
        )
        path.addLine(to: CGPoint(x: box.maxX, y: rect.maxY))
        return path
    }

    func inset(by amount: CGFloat) -> Self {
        var copy = self
        copy.inset += amount
        return copy
    }
}
