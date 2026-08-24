import Foundation

/// Shared geometry for the bar above an open file, so the two bars that draw it cannot drift.
///
/// `FileHeaderBar` sits over a changed file and `FilePreview` draws its own over one nobody
/// changed, and the reader walks between them by clicking around a single column. The folder
/// threshold was written out as a `private static let` in each, with a comment in the second
/// asking whoever changed one to remember the other, which is the arrangement that ends with two
/// bars giving the folder up a few points apart.
public enum FileBarLayout {
    /// Below this the bar keeps the filename and the controls and drops the folder beside it.
    /// A readable filename, the collapsed control cluster and the pane's own insets, with just
    /// enough left over for a folder worth reading.
    public static let folderThreshold: CGFloat = 340

    /// Whether there is room for the containing folder beside the filename.
    ///
    /// Asked of the bar's own measured width, never of a `ViewThatFits`: the layout has already
    /// apportioned the row by the time a fitting view is offered a share of it, so the folder was
    /// dropped while there was still most of a pane to spare.
    public static func showsDirectory(width: CGFloat) -> Bool {
        width >= folderThreshold
    }
}
