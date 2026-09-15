import SwiftUI

/// The side conversation card's outline: a rounded rectangle with a popover's tail on its bottom
/// edge.
///
/// One contour rather than a rectangle with a triangle laid over it, because the glass and the rim
/// are both drawn in this shape. Two shapes gave two panes of glass meeting in a visible seam, and
/// a rim around each with a line across the base of the tail.
struct SideConversationCardShape: Shape {
    var cornerRadius: CGFloat
    /// The tip, from the leading edge. Nil draws the card with no tail and no room kept for one.
    var tailX: CGFloat?
    var tailSize: CGSize

    func path(in rect: CGRect) -> Path {
        let tailHeight = tailX == nil ? 0 : tailSize.height
        let body = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: max(0, rect.height - tailHeight))
        let radius = max(0, min(cornerRadius, body.width / 2, body.height / 2))

        var path = Path()
        path.move(to: CGPoint(x: body.minX + radius, y: body.minY))
        path.addArc(
            tangent1End: CGPoint(x: body.maxX, y: body.minY),
            tangent2End: CGPoint(x: body.maxX, y: body.maxY),
            radius: radius
        )
        path.addArc(
            tangent1End: CGPoint(x: body.maxX, y: body.maxY),
            tangent2End: CGPoint(x: body.minX, y: body.maxY),
            radius: radius
        )
        if let tailX {
            let tip = CGPoint(x: rect.minX + tailX, y: body.maxY + tailHeight)
            let half = tailSize.width / 2
            // Eased into the edge on both sides, which is what makes it read as the system's
            // arrow rather than as a triangle stuck on.
            path.addLine(to: CGPoint(x: tip.x + half, y: body.maxY))
            path.addCurve(
                to: tip,
                control1: CGPoint(x: tip.x + half * 0.45, y: body.maxY),
                control2: CGPoint(x: tip.x + half * 0.2, y: tip.y)
            )
            path.addCurve(
                to: CGPoint(x: tip.x - half, y: body.maxY),
                control1: CGPoint(x: tip.x - half * 0.2, y: tip.y),
                control2: CGPoint(x: tip.x - half * 0.45, y: body.maxY)
            )
        }
        path.addArc(
            tangent1End: CGPoint(x: body.minX, y: body.maxY),
            tangent2End: CGPoint(x: body.minX, y: body.minY),
            radius: radius
        )
        path.addArc(
            tangent1End: CGPoint(x: body.minX, y: body.minY),
            tangent2End: CGPoint(x: body.maxX, y: body.minY),
            radius: radius
        )
        path.closeSubpath()
        return path
    }
}
