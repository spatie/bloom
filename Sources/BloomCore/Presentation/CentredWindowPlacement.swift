import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Keeps a content-sized utility centred on its owner, including when its content changes height.
/// Screen bounds win near an edge so the title bar and primary action remain reachable.
public enum CentredWindowPlacement {
    public static func frame(size: CGSize, around anchor: CGRect, visible: CGRect) -> CGRect {
        let x = min(max(anchor.midX - size.width / 2, visible.minX), max(visible.minX, visible.maxX - size.width))
        let y = min(max(anchor.midY - size.height / 2, visible.minY), max(visible.minY, visible.maxY - size.height))
        return CGRect(origin: CGPoint(x: x, y: y), size: size)
    }
}
