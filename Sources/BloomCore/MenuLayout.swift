import Foundation

/// Shared geometry for the two completion menus, so the slash menu and the file menu cannot drift
/// apart, and the rule for where a menu may open at all.
public enum MenuLayout {
    /// About eight rows. Past that a menu stops being a glance and starts being a list, and the
    /// composer it floats over disappears behind it.
    public static let maxHeight: CGFloat = 240

    /// Roughly three rows plus the panel's padding. A menu shorter than this is not a menu, it is
    /// a letterbox: the create sheet has about seventy points above its composer, and a panel cut
    /// to that showed two arbitrary rows with the ranked ones scrolled off inside it.
    public static let minimumHeight: CGFloat = 100

    /// Where a completion menu opens relative to the composer, and how tall it may be.
    ///
    /// `above` hangs the panel's bottom over the box's top edge, which is the transcript's shape:
    /// the composer sits at the foot of the window with the whole conversation above it. `below`
    /// hangs the panel's top under the line being typed, which is the create sheet's shape: the
    /// box sits near the top of a small window, and a panel that opened upwards there was clipped
    /// at the sheet's edge with the best ranked rows, the selected one among them, off screen.
    public enum Placement: Equatable, Sendable {
        case above(room: CGFloat)
        case below(room: CGFloat)

        /// The room on the chosen side, uncapped. The hover cards fit themselves to this, because
        /// a card is allowed to be taller than a menu ever is.
        public var room: CGFloat {
            switch self {
            case .above(let room), .below(let room): room
            }
        }

        /// What the completion menus draw at: the room, stopped at the cap a menu keeps anyway.
        public var menuHeight: CGFloat {
            min(MenuLayout.maxHeight, room)
        }

        public var isBelow: Bool {
            if case .below = self { return true }
            return false
        }
    }

    /// Decides for the room actually on offer. `above` is the room between the top of the window
    /// and the top of the box; `below` is the room between the underside of the line being typed
    /// and the bottom of the window. Above wins whenever it holds a useful menu, because that is
    /// the shape every existing composer has and a menu that flips sides for no reason is motion
    /// nobody asked for. Only when above cannot hold `minimumHeight` and below holds more does
    /// the menu open downwards.
    public static func placement(above: CGFloat, below: CGFloat) -> Placement {
        let aboveRoom = max(above, 0)
        let belowRoom = max(below, 0)
        if aboveRoom >= minimumHeight || aboveRoom >= belowRoom {
            return .above(room: aboveRoom)
        }
        return .below(room: belowRoom)
    }
}
