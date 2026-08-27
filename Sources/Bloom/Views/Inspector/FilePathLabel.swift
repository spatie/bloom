import SwiftUI
import BloomCore

/// The file's path relative to the worktree root, drawn as the path it is: the folders quiet, a
/// slash between them, then the filename in bold.
///
/// **It was a grey pill holding the directory, and the pill was the problem.** The chip was capped
/// at 170 points with `.lineLimit(1)` and the default truncation, which cuts at the tail, so
/// `app/Domain/Channels/Jobs` came out as `app/Domain/Chann...`: the components that disappeared
/// were the ones nearest the filename, and those are the only ones that answer "which of the four
/// `Handler.php` files is this". Below 340 points the bar dropped the folder altogether. Looking
/// at `config/horizon.php` drawn as a grey `config` next to a bold `horizon.php`, the owner asked
/// for a better way to show the full path relative to the workspace root.
///
/// So the pill is gone and what is left is one path, read the way a path is read, with a weight
/// change where the filename starts. `.../Channels/Jobs/Handler.php` says what it is in the shape
/// everybody already knows; a row of four pills would have been the same information drawn as
/// furniture, in a bar the owner has twice asked to make quieter.
///
/// **The components are not pressable.** A breadcrumb that reveals a folder or filters the tree is
/// a real feature, and it doubles the number of hit targets in a strip whose whole brief is to
/// stay out of the way of the diff under it. The tree in the inspector beside this already opens
/// folders, and it is one click away.
struct FilePathLabel: View {
    /// Relative to the worktree root, exactly as a review tab and `ChangedFile` carry it.
    var path: String

    /// The bar's own measured width, which is the only thing that can decide how much path there
    /// is room for. `ViewThatFits` cannot: it is handed the share of the row the layout has
    /// already apportioned, so it dropped the folder while there was still most of a pane to
    /// spare. See `FileBarLayout`.
    var width: CGFloat

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            if let folder {
                folder
                    .font(Typo.caption)
                    .lineLimit(1)
                    // The safety net under `FileBarLayout.crumbs`, which budgets in estimated
                    // character widths rather than measuring the font. If the estimate comes out
                    // a little loose the layout squeezes this text, and `.head` means what it
                    // gives up is `app/` rather than the folder touching the name.
                    .truncationMode(.head)
                    // Lower priority than the name beside it, for the same reason: a bar with no
                    // slack spends what it has on the filename first.
                    .layoutPriority(-1)
            }

            Text(filename)
                .font(Typo.bodyEmphasis)
                .foregroundStyle(Palette.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .help(path)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(path)
    }

    /// The folders and their separators as one `Text`, so they lay out and truncate as one run of
    /// path rather than as a stack of boxes the layout can pull apart.
    ///
    /// Built by interpolating one styled `Text` per component, which is what macOS 26 leaves once
    /// `+` on two `Text`s is deprecated. `SlashCommandRow` records the rest of the reason: an
    /// `AttributedString` would be shorter and its SwiftUI scope carries `font` and no
    /// `fontWeight`, so a run would stop inheriting the bar's own type.
    private var folder: Text? {
        let crumbs = FileBarLayout.crumbs(for: directory, width: width)
        guard !crumbs.isEmpty else { return nil }

        var runs = LocalizedStringKey.StringInterpolation(literalCapacity: 0, interpolationCount: 0)
        if crumbs.isElided {
            runs.appendInterpolation(Text(verbatim: "…").foregroundStyle(Palette.textTertiary))
            runs.appendInterpolation(separator)
        }
        for component in crumbs.components {
            runs.appendInterpolation(Text(component).foregroundStyle(Palette.textTertiary))
            runs.appendInterpolation(separator)
        }
        return Text(LocalizedStringKey(stringInterpolation: runs))
    }

    /// A step quieter than the components either side of it, so what the eye lands on is the
    /// folder names and not the punctuation between them. The same half-strength slash `HomeListRow`
    /// puts between a project and its branch, which is the only other place in the window that
    /// draws one.
    private var separator: Text {
        Text(verbatim: "/").foregroundStyle(Palette.textTertiary.opacity(0.5))
    }

    private var filename: String { (path as NSString).lastPathComponent }

    private var directory: String { (path as NSString).deletingLastPathComponent }
}
