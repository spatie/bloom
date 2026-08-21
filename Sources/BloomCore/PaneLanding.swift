import CoreGraphics
import Foundation

/// Which part of a pane something being dragged is over, and therefore what letting go there means.
///
/// One vocabulary for both of the things that can be dropped on a pane, and one place the geometry
/// is written down. It used to be a private enum inside `CenterPaneView` that answered only for the
/// pane it belonged to, which meant the wash drawn while a drag was in flight and the decision
/// taken when it was let go were two readings of the same rule, in a view, where nothing could
/// check that they agreed.
public enum PaneRegion: String, Sendable, Hashable, CaseIterable, Codable {
    /// The middle. Not a placement: a tab let go here replaces what the pane is showing, and a
    /// pane let go here exchanges places with it.
    case whole
    case leading
    case trailing
    case top
    case bottom

    /// How much of the pane, on each side, counts as an edge rather than the middle. A quarter:
    /// wide enough to hit without aiming, narrow enough that the middle is still most of the pane.
    public static let edgeShare: Double = 0.25

    /// Where the thing being dropped goes, or nil for the middle, which is not a placement at all.
    public var placement: (axis: SplitAxis, before: Bool)? {
        switch self {
        case .whole: nil
        case .leading: (.horizontal, true)
        case .trailing: (.horizontal, false)
        case .top: (.vertical, true)
        case .bottom: (.vertical, false)
        }
    }

    /// Which region of a pane a point inside it falls in.
    ///
    /// The corners belong to whichever side is tested first, which is the horizontal pair. That is
    /// arbitrary and it does not matter: the two answers differ only in a corner a sixteenth of the
    /// pane across, and picking one of them consistently is worth more than a rule about diagonals
    /// that nobody could predict from looking.
    public static func at(_ point: CGPoint, in size: CGSize) -> PaneRegion {
        guard size.width > 0, size.height > 0 else { return .whole }
        let horizontal = size.width * edgeShare
        let vertical = size.height * edgeShare

        if point.x < horizontal { return .leading }
        if point.x > size.width - horizontal { return .trailing }
        if point.y < vertical { return .top }
        if point.y > size.height - vertical { return .bottom }
        return .whole
    }

    /// The part of a pane's frame this region covers, which is what gets washed while a drag is
    /// over it. The whole pane for the middle, a quarter along the named side otherwise.
    public func frame(in pane: CGRect) -> CGRect {
        let share = Self.edgeShare
        switch self {
        case .whole:
            return pane
        case .leading:
            return CGRect(x: pane.minX, y: pane.minY, width: pane.width * share, height: pane.height)
        case .trailing:
            let width = pane.width * share
            return CGRect(x: pane.maxX - width, y: pane.minY, width: width, height: pane.height)
        case .top:
            return CGRect(x: pane.minX, y: pane.minY, width: pane.width, height: pane.height * share)
        case .bottom:
            let height = pane.height * share
            return CGRect(x: pane.minX, y: pane.maxY - height, width: pane.width, height: height)
        }
    }
}

/// Where a drag over the centre column would land: which pane, which part of it, and the rectangle
/// to wash so the person dragging can see it before they let go.
///
/// A value rather than a pair of `@State`s in a view, because the same answer is needed in three
/// places at once and they have to agree: the wash while the pointer moves, the refusal of a drop
/// that would change nothing, and the edit itself.
public struct PaneLanding: Equatable, Sendable {
    public var pane: String
    public var region: PaneRegion
    /// In the coordinate space the geometry was computed in.
    public var frame: CGRect

    public init(pane: String, region: PaneRegion, frame: CGRect) {
        self.pane = pane
        self.region = region
        self.frame = frame
    }
}

extension SplitGeometry {
    /// What a point in the column is over.
    ///
    /// Nil for a point outside every pane, which is the dividers and the space beyond the column.
    /// A drag let go there is let go over nothing and does nothing, rather than being snapped to
    /// the nearest pane: a divider is a point of a few pixels between two panes, and guessing which
    /// of them somebody meant is how a drag lands in the wrong half.
    ///
    /// The panes are searched in reverse, so a pane drawn later wins an overlap. They do not
    /// overlap as `SplitLayout` computes them, and the rule is stated anyway rather than left to
    /// the coincidence that they do not.
    public func landing(at point: CGPoint) -> PaneLanding? {
        guard let hit = panes.reversed().first(where: { $0.frame.contains(point) }) else { return nil }
        let local = CGPoint(x: point.x - hit.frame.minX, y: point.y - hit.frame.minY)
        let region = PaneRegion.at(local, in: hit.frame.size)
        return PaneLanding(pane: hit.pane, region: region, frame: region.frame(in: hit.frame))
    }
}
