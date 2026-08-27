import Foundation

/// Shared geometry for the bar above an open file, so the three bars that draw it cannot drift.
///
/// `FileHeaderBar` sits over a changed file, `FilePreview` draws its own over one nobody changed
/// and `FileMediaView` over one that is a picture, and the reader walks between them by clicking
/// around a single column. The folder threshold was written out as a `private static let` in each,
/// with a comment in the second asking whoever changed one to remember the other, which is the
/// arrangement that ends with three bars giving the folder up a few points apart.
///
/// **What is decided here is which folders survive a given width, not what they look like.** The
/// bar used to hand the whole relative directory to a chip capped at 170 points and let the text
/// truncate itself, which truncates at the tail: `app/Domain/Channels/Jobs` came out as
/// `app/Domain/Chann...`, losing the components nearest the filename, which are the only ones that
/// answer "which of the four `Handler.php` files is this". Below 340 points it dropped the folder
/// outright. So the owner reading `config/horizon.php` and asking for the full path was not asking
/// for data the bar did not have: `ChangedFile.directory` is `deletingLastPathComponent` and has
/// always been the whole relative directory. He was asking to be shown it.
public enum FileBarLayout {
    /// What the bar spends before the folder gets a point: the filename set at `Typo.body`, the
    /// collapsed control cluster beside it, the gaps between them and the pane's two insets.
    ///
    /// Taken from what shipped rather than picked fresh. The bar dropped the folder below 340
    /// points and capped it at 170, so 170 is the number it already held for everything that is
    /// not the folder. Keeping it means a bar at the old threshold offers the folder exactly the
    /// room the old chip had, and every width below it, which used to show nothing at all, now
    /// buys as many components as it can pay for.
    public static let reserve: CGFloat = 170

    /// The most the folder may take, however wide the pane gets.
    ///
    /// Forty characters, which is `app/Domain/Channels/Jobs` with a component to spare. The
    /// filename is the loudest thing in this bar and the folder is there to qualify it; a folder
    /// allowed to grow with the window stops being a qualifier somewhere around here and starts
    /// being the sentence.
    public static let ceiling: CGFloat = 240

    /// Below this much room the folder is dropped rather than squeezed.
    ///
    /// About seven characters and the slash after them, which is `Sources/` or `Domain/`. Under
    /// it the leading ellipsis and the separators are most of what is drawn, and a pill holding
    /// one ellipsis answers nothing while still costing the row the space a readable folder would
    /// have wanted.
    public static let floor: CGFloat = 44

    /// One character of the folder's type, near enough to budget with.
    ///
    /// `Typo.caption` is `.subheadline`, which resolves to 11 point on macOS, and path components
    /// are lowercase words. Six is deliberately generous rather than an average: the view draws
    /// the components as a single `Text` that head-truncates, so an estimate that is too tight
    /// only wastes a few points, while one that is too loose is caught by the layout and eats the
    /// leading end, which is the end this was all built to lose.
    static let characterWidth: CGFloat = 6

    /// The `/` between two components and the air either side of it.
    static let separatorWidth: CGFloat = 10

    /// The path relative to the worktree root, cut to what the bar can show.
    public struct FolderCrumbs: Equatable, Sendable {
        /// The components to draw, in path order, so the one nearest the filename is last.
        public let components: [String]

        /// Whether components were dropped off the leading end. The view marks it with an
        /// ellipsis before the first component it did keep.
        public let isElided: Bool

        /// Nothing to draw at all, which is a bar too narrow to spend anything on a folder, or a
        /// file sitting at the root of the worktree.
        public var isEmpty: Bool { components.isEmpty }

        public init(components: [String], isElided: Bool) {
            self.components = components
            self.isElided = isElided
        }
    }

    /// How much of the bar's width the folder may have.
    ///
    /// Asked of the bar's own measured width, never of a `ViewThatFits`: the layout has already
    /// apportioned the row by the time a fitting view is offered a share of it, so the folder was
    /// dropped while there was still most of a pane to spare.
    public static func folderWidth(width: CGFloat) -> CGFloat {
        min(max(width - reserve, 0), ceiling)
    }

    /// Which components of a file's containing directory the bar can show at this width.
    ///
    /// **Trimmed from the leading end, always.** `app/` is the half worth losing and the component
    /// touching the filename is the half worth keeping, so this walks backwards from the end and
    /// stops when the budget runs out. Once there is any budget at all the last component is kept
    /// whatever it costs, because one folder the reader has to squint at beats the bare filename
    /// that width used to buy.
    ///
    /// - Parameters:
    ///   - directory: the file's directory relative to the worktree root, which is what
    ///     `ChangedFile.directory` already holds. Empty for a file at the root.
    ///   - width: the bar's own measured width, in points.
    public static func crumbs(for directory: String, width: CGFloat) -> FolderCrumbs {
        let budget = folderWidth(width: width)
        let components = directory.split(separator: "/").map(String.init)
        guard budget >= floor, !components.isEmpty else {
            return FolderCrumbs(components: [], isElided: false)
        }

        var kept = 0
        var spent: CGFloat = 0
        for component in components.reversed() {
            let cost = CGFloat(component.count) * characterWidth + separatorWidth
            // The last component is taken before the budget is consulted: see above.
            if kept > 0, spent + cost > budget { break }
            spent += cost
            kept += 1
        }

        return FolderCrumbs(
            components: Array(components.suffix(kept)),
            isElided: kept < components.count
        )
    }
}
