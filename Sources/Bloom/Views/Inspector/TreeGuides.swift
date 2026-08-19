import SwiftUI

/// The faint vertical rules that run down the left of a tree row, one per level above it.
///
/// Indentation alone does not read as hierarchy in a 280pt column: the step has to stay small
/// enough to leave room for filenames, and at that size a row three levels down looks like a row
/// two levels down. A rule per ancestor is what makes the depth countable at a glance, and because
/// the rows below sit flush against each other the rules join up into one continuous line per
/// level.
///
/// Drawn behind the row's own content and with a hierarchical style rather than a fixed colour, so
/// a selected row inverts the rules along with everything else on it.
struct TreeGuides: View {
    var depth: Int

    /// How far in a row at this depth starts, before the row's own leading gap.
    static func indent(for depth: Int) -> CGFloat {
        CGFloat(max(depth, 0)) * InspectorLayout.indentStep
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(0..<max(depth, 0), id: \.self) { _ in
                Rectangle()
                    .fill(.tertiary)
                    .frame(width: Metrics.hairline)
                    // One glyph box per level, which is what `indentStep` is.
                    .frame(width: InspectorLayout.indentStep, alignment: .leading)
            }
        }
        // The rule runs down the column its level's own glyph STARTS in, rather than the column
        // that glyph's centre happens to fall in. Those were the same number while the glyph was
        // centred in its box, and are not any more: the glyphs are leading aligned now, so that
        // the first mark in a row lands on the column's inset like everything else in the pane
        // (see `InspectorLayout.glyphWidth`). Kept at the centre the rule came out four points to
        // the right of the chevron it belongs to, in the gap between the chevron and the name,
        // which reads as a rule at no particular place. This is also the simpler arithmetic: a
        // level steps by exactly one glyph box, so level k's rule is at the same offset as level
        // k's glyph.
        .padding(.leading, InspectorLayout.gap)
        .accessibilityHidden(true)
    }
}

extension View {
    /// Puts a tree row at its depth: the leading inset, and the guides for every level above it.
    ///
    /// Applied by all three rows of the two trees in the inspector so they cannot drift apart, and
    /// applied after the row has been given its height, because the guides have to run the whole
    /// way down the row for the column to look continuous.
    func treeIndent(depth: Int) -> some View {
        padding(.leading, TreeGuides.indent(for: depth) + InspectorLayout.gap)
            .padding(.trailing, InspectorLayout.gap)
            .frame(height: Metrics.rowHeight)
            .background(alignment: .leading) { TreeGuides(depth: depth) }
    }
}
