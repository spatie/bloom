import SwiftUI

/// A single outline shared by sent and queued messages. The tail has its own layout space, so
/// it never changes the text's padding or relies on drawing beyond the row's measured bounds.
struct OutgoingBubbleShape: InsettableShape {
    static let tailWidth: CGFloat = 6
    static let tailDrop: CGFloat = 3

    var cornerRadius: CGFloat
    private var insetAmount: CGFloat = 0

    init(cornerRadius: CGFloat) {
        self.cornerRadius = cornerRadius
    }

    func path(in bounds: CGRect) -> Path {
        let rect = bounds.insetBy(dx: insetAmount, dy: insetAmount)
        guard rect.width > Self.tailWidth, rect.height > Self.tailDrop else { return Path() }
        let right = rect.maxX - Self.tailWidth
        let bottom = rect.maxY - Self.tailDrop
        let radius = max(0, min(cornerRadius - insetAmount, (right - rect.minX) / 2, (bottom - rect.minY) / 2))
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + radius, y: rect.minY))
        path.addLine(to: CGPoint(x: right - radius, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: right, y: rect.minY + radius), control: CGPoint(x: right, y: rect.minY))
        path.addLine(to: CGPoint(x: right, y: bottom - radius))
        path.addCurve(
            to: CGPoint(x: rect.maxX, y: rect.maxY),
            control1: CGPoint(x: right, y: bottom),
            control2: CGPoint(x: right + 1, y: rect.maxY - 1)
        )
        path.addCurve(
            to: CGPoint(x: right - min(5, radius), y: bottom - min(2, radius)),
            control1: CGPoint(x: right + 1, y: rect.maxY),
            control2: CGPoint(x: right - min(3, radius), y: bottom)
        )
        path.addQuadCurve(to: CGPoint(x: right - radius, y: bottom), control: CGPoint(x: right - radius / 2, y: bottom))
        path.addLine(to: CGPoint(x: rect.minX + radius, y: bottom))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: bottom - radius), control: CGPoint(x: rect.minX, y: bottom))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + radius))
        path.addQuadCurve(to: CGPoint(x: rect.minX + radius, y: rect.minY), control: CGPoint(x: rect.minX, y: rect.minY))
        path.closeSubpath()
        return path
    }

    func inset(by amount: CGFloat) -> Self {
        var copy = self
        copy.insetAmount += amount
        return copy
    }
}
