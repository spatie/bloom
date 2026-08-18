import CoreGraphics

/// The inspector's spacing scale.
///
/// One set of numbers rather than a literal per call site, because three stacked panes only read
/// as one column if their rows, insets and gutters agree.
///
/// The shared values are the window's, not the inspector's own: a file row and a sidebar row are
/// the same kind of thing and used to sit a point or two apart because each column kept its own
/// copy of the number. What is left here is genuinely local to a diff.
enum InspectorLayout {
    /// Between two things that belong to each other.
    static let tight = Metrics.spacingTight
    /// Between controls in a row.
    static let gap = Metrics.spacing
    /// The inset a list row keeps from the edge of the pane.
    static let inset = Metrics.inset
    /// The pull request strip and the toolbar under it.
    static let barHeight = Metrics.barHeight
    /// A meaning colour used as a background rather than as ink. One value, so a green badge and a
    /// blue chip carry the same weight.
    static let tintOpacity: Double = 0.12
    /// The same meaning colour on something that sits ON the wash above, such as the pull request
    /// number. One step denser, or the chip disappears into the bar it is drawn on.
    static let tintOpacityStrong: Double = 0.24
    /// Status glyphs share one box, so the names beside them line up whichever symbol lands in it.
    static let glyphWidth: CGFloat = 16
    /// One level of indent in the file tree.
    static let indentStep: CGFloat = 12
    /// How much room a list keeps once a detail pane has opened beneath it, until the reader
    /// drags the boundary somewhere else.
    static let listHeight: CGFloat = 220
}
