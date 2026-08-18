import CoreGraphics

/// The inspector's spacing scale.
///
/// One set of numbers rather than a literal per call site, because three stacked panes only read
/// as one column if their rows, insets and gutters agree.
enum InspectorLayout {
    /// Between two things that belong to each other.
    static let tight: CGFloat = 2
    /// Between controls in a row.
    static let gap: CGFloat = 6
    /// The inset a list row keeps from the edge of the pane.
    static let inset: CGFloat = 10
    /// The pull request strip and the toolbar under it.
    static let barHeight: CGFloat = 32
    /// A meaning colour used as a background rather than as ink. One value, so a green badge and a
    /// blue chip carry the same weight.
    static let tintOpacity: Double = 0.12
    /// Status glyphs share one box, so the names beside them line up whichever symbol lands in it.
    static let glyphWidth: CGFloat = 16
    /// One level of indent in the file tree.
    static let indentStep: CGFloat = 12
    /// How much room a list keeps once a detail pane has opened beneath it.
    static let listHeight: CGFloat = 220
}
