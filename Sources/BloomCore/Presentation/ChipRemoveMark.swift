import CoreGraphics

/// The close control on a chip, as the numbers every renderer of it reads.
///
/// **The X is ink on a plate, never `xmark.circle.fill`.** That symbol knocks its X out of a
/// filled disc, so the X is a hole showing whatever is behind the chip: grey on grey at eleven
/// points, which is a smudge rather than a control.
///
/// This file exists because that was fixed once, on one chip. `AttachmentChip` draws the pills
/// above the composer and in the transcript and was corrected; the chip *inside* the box is an
/// `NSTextAttachmentCell` drawn by TextKit, and `SlashCommandChip` and `ReviewCommentChip` sit in
/// the same strip, and all three kept the smudge. Four drawings of one control, one decision
/// taken about it, and three of them never heard.
///
/// The drawing cannot be shared. TextKit 1 has no way to put a view inside a line of text, so the
/// chip in the box will always draw itself with AppKit while the other three are one SwiftUI
/// view. What can be shared is the decision, which is what was actually wrong: how heavy the X is
/// against the disc it sits on, and how far the plate stands off the chip behind it. A renderer
/// that reads these cannot silently disagree with the others again.
///
/// In the core rather than beside the palette because none of it is a colour. It is one ratio and
/// three alphas, which is exactly the kind of thing a view decides and nothing can test.
public enum ChipRemoveMark {
    /// How much of the disc the X takes, leaving the rest as plate around it.
    ///
    /// A little over half. The glyph is set bold, because at this size a regular stroke is the
    /// thin grey scratch that started the whole complaint, and bold at the full diameter would
    /// have the arms running into the ring. What is left is a ring of plate wide enough to read
    /// as a disc at eleven points, which is the size the composer actually draws it at.
    public static let glyphScale: CGFloat = 0.58

    /// The point size to set the X at inside a disc of `diameter`.
    ///
    /// Not rounded. A symbol is drawn from an outline rather than snapped to a grid, and rounding
    /// this to a whole point is how the AppKit chip and the SwiftUI one would come out a shade
    /// different from each other at the same nominal size.
    public static func glyphPointSize(diameter: CGFloat) -> CGFloat {
        diameter * glyphScale
    }

    /// The plate, where the chip is on an emphasized fill rather than on the page: that much of
    /// the inverted ink, which reads as a lighter patch of the bubble rather than as a white
    /// card lying on it. The same twenty-ish percent `Chip` and `DiffStatLabel` take on the same
    /// colour, a notch below the chip's own so the control still stands off the chip.
    public static let emphasisPlate: CGFloat = 0.16

    /// And with the pointer on the control itself, which is a smaller target than the chip it
    /// sits in, so the press has somewhere to land before it happens.
    public static let emphasisPlateHovered: CGFloat = 0.28

    /// The disc's edge on that same fill. A hairline in the page's border colour disappears into
    /// an accent fill, so there the edge is drawn in the label's own ink, kept faint enough to
    /// stay an edge. `AttachmentChip.stroke` records the same finding for the chip's own border.
    public static let emphasisRing: CGFloat = 0.35
}
