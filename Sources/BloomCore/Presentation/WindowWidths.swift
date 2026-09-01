import CoreGraphics

/// The thicknesses the main window's minimum width is built out of, and what has to move when the
/// inspector opens in a window too narrow for it.
///
/// # Why the arithmetic left the window
///
/// It was one line in `BloomApp`: the sidebar's maximum, plus the detail half's minimum, plus a
/// divider. 420 + 701 + 1 = 1122, a constant, correct in every state and therefore correct in none
/// of them. It is not wrong as arithmetic. It is wrong as a STATEMENT: it says this window always
/// needs room for three panes, while two of them are showing. On a laptop those 281 points are the
/// difference between two windows side by side and one.
///
/// So the minimum is conditional now, and the moment a minimum is conditional it stops being
/// arithmetic and becomes a rule with a hole in it. **The hole is that a minimum going UP does not
/// move a window.** `NSWindow` does not resize itself when its minimum size is raised above what it
/// currently is, so a window at 841 points that is handed a minimum of 1122 stays at 841 and the
/// split view lays out 281 points more than it was given, which is the clipped sidebar rows and the
/// clipped Create Pull Request button that `BloomApp`'s old comment is about. `presenting` is the
/// answer to that and `minimum` is only half the story without it.
///
/// Four numbers, a condition, and one number out is exactly the shape that should not live in a
/// view, which is why it is here.
///
/// # What the sidebar's number is, and why it is the maximum
///
/// `sidebar` is what the window RESERVES for the first column, and it is that column's maximum
/// rather than the width it happens to be at. `NavigationSplitView` does not shrink its sidebar to
/// satisfy the detail column's minimum, measured, so a window sized against a 260 point sidebar
/// clips the moment the sidebar is dragged out to 420.
///
/// **Using the column's real width instead is worth up to 220 more points and it is deliberately
/// not done.** It moves the hole above onto a control the owner drags constantly: every sidebar
/// drag would raise a minimum under a window that will not grow, so every drag would need the same
/// companion the inspector now has, on a gesture rather than on a click. One risky change at a
/// time, and this is the smaller prize of the two.
public struct WindowWidths: Equatable, Sendable {
    /// What the window reserves for the first column: its MAXIMUM. See the note above.
    public let sidebar: CGFloat

    /// The narrowest the first column may be squeezed to before it should fold away instead.
    public let sidebarMinimum: CGFloat

    /// The centre column's own minimum thickness, which is a hard AppKit constraint on the split
    /// view rather than something SwiftUI negotiates away.
    public let detail: CGFloat

    /// The inspector's, the same way.
    public let inspector: CGFloat

    /// One divider. Counted once per boundary: one between the sidebar and the detail half, and
    /// one more inside it when the inspector is on screen.
    public let divider: CGFloat

    public init(
        sidebar: CGFloat,
        sidebarMinimum: CGFloat,
        detail: CGFloat,
        inspector: CGFloat,
        divider: CGFloat
    ) {
        self.sidebar = sidebar
        self.sidebarMinimum = sidebarMinimum
        self.detail = detail
        self.inspector = inspector
        self.divider = divider
    }

    /// The narrowest the window's CONTENT may be drawn, which is what a `.frame(minWidth:)` on the
    /// scene's root sets and what `NSWindow.contentMinSize` ends up holding.
    public func minimum(withInspector: Bool) -> CGFloat {
        sidebar + divider + detailHalf(withInspector: withInspector)
    }

    /// The narrowest the detail HALF may be drawn: the centre column, plus the inspector and the
    /// divider between them while the inspector is on screen.
    ///
    /// The other half of the same rule as `minimum`, and here rather than beside the split view so
    /// that the two cannot drift: what the representable reports as its fitting size and what the
    /// window refuses to go below are the same statement about the same panes.
    public func detailHalf(withInspector: Bool) -> CGFloat {
        withInspector ? detail + divider + inspector : detail
    }

    /// What the first column may be dragged out to when there are `total` points to share, or nil
    /// when not even its minimum fits and it should fold away instead.
    ///
    /// `total` is the screen's width where this is asked before a window exists to measure, and the
    /// window's own width where it is asked after `presenting` has grown it as far as it can. Those
    /// are the same number in the case that matters, and where they differ the window's is the one
    /// the panes are actually laid out in.
    ///
    /// **This is the answer to "the window is already as wide as the screen and the inspector is
    /// opened".** Clipping is not an answer and refusing to open the inspector is worse, so the
    /// sidebar is what gives: it is the only pane of the three whose content survives being narrow,
    /// because it is a list of rows that truncate, where the centre column holds a transcript and
    /// the inspector holds a diff and a button that do not. Below `sidebarMinimum` there is nothing
    /// left worth showing and folding it is honest, which is a state this window already has and
    /// already puts a New Workspace button in the toolbar for.
    ///
    /// On any screen that can afford the reserve, which is every Mac display, this answers with the
    /// reserve and nothing moves. It is the small external display and the Sidecar iPad that reach
    /// the rest of it.
    public func sidebarMaximum(sharing total: CGFloat, withInspector: Bool) -> CGFloat? {
        let room = total - divider - detailHalf(withInspector: withInspector)
        if room >= sidebar { return sidebar }
        if room >= sidebarMinimum { return room }
        return nil
    }

    /// What has to move for the inspector to open in a window this wide on a screen this wide.
    ///
    /// The window grows before the sidebar shrinks, because growing a window takes nothing away
    /// from the user and narrowing the sidebar takes rows. It never shrinks the window: a window
    /// wider than its screen is one the user has dragged there, and the inspector opening is not
    /// the moment to argue with that.
    public func presenting(windowWidth: CGFloat, screenWidth: CGFloat) -> InspectorFit {
        let needed = minimum(withInspector: true)
        guard windowWidth < needed else { return .settled }

        let grown = max(windowWidth, min(needed, screenWidth))
        let widened = grown > windowWidth ? grown : nil
        guard grown < needed else {
            return InspectorFit(windowWidth: widened, sidebarWidth: nil, foldsSidebar: false)
        }

        // The screen cannot afford the reserve, so the sidebar gives up the difference.
        guard let room = sidebarMaximum(sharing: grown, withInspector: true) else {
            return InspectorFit(windowWidth: widened, sidebarWidth: nil, foldsSidebar: true)
        }
        return InspectorFit(windowWidth: widened, sidebarWidth: room, foldsSidebar: false)
    }
}

/// What opening the inspector costs the window it is opening in. See `WindowWidths.presenting`.
public struct InspectorFit: Equatable, Sendable {
    /// The content width the window has to be given, or nil while it is already wide enough.
    public let windowWidth: CGFloat?

    /// The width the first column has to come down to, or nil while it can keep what it has.
    public let sidebarWidth: CGFloat?

    /// Whether even the first column's minimum does not fit, and it has to fold away.
    public let foldsSidebar: Bool

    /// Nothing moves. The overwhelmingly common answer, and the one every window on a normal
    /// display gets.
    public static let settled = InspectorFit(
        windowWidth: nil, sidebarWidth: nil, foldsSidebar: false
    )

    public init(windowWidth: CGFloat?, sidebarWidth: CGFloat?, foldsSidebar: Bool) {
        self.windowWidth = windowWidth
        self.sidebarWidth = sidebarWidth
        self.foldsSidebar = foldsSidebar
    }

    public var isSettled: Bool { self == .settled }
}
