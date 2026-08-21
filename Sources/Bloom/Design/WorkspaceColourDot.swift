import SwiftUI
import AppKit
import BloomCore

/// The colour a workspace was marked with, as it appears on a row.
///
/// **No colour draws nothing, and takes up nothing.** That is the whole rule. The normal state of
/// a workspace is unmarked, so a placeholder, a hollow ring or a grey tag standing in for "none"
/// would put a mark on every row in the pane to say that almost none of them are marked. The pin
/// beside it already works this way and the two read as one habit: a row shows what is true about
/// it and is otherwise quiet.
///
/// **Where it sits.** Immediately after the name, in both lists, which is where Finder puts a tag
/// on a file in list view and is what the owner was pointing at. It is deliberately NOT in the
/// leading column: that column is the status glyph's in the sidebar and the project mark's on
/// Home, it is shared with the project tile and the disclosure gutter, and those alignments were
/// measured to the point. Nothing here moves them.
///
/// **Why a dot and not a tint on the name.** The name already carries the unread mark in its
/// weight, and a second signal in the same glyphs would mean a row could not say both things at
/// once. It also has to survive AppKit inverting a selected row's text, which a coloured name
/// would not.
struct WorkspaceColourDot: View {
    /// The stored hex, straight off the workspace. Nil, empty or unreadable all draw nothing.
    var hex: String?
    /// What a screen reader calls it. Nil while the row speaks for itself, which is what Home
    /// does: its row is one merged accessibility element, so a label here would be swallowed.
    var accessibilityName: String?

    /// Small enough to read as a mark on the name rather than as a badge of its own, and the same
    /// in both lists so one workspace cannot be two sizes two hundred points apart.
    private static let size: CGFloat = 7

    var body: some View {
        if let tint {
            Circle()
                .fill(tint)
                // A hairline of the ink colour at low opacity, for the two colours that vanish
                // against their own ground: yellow on a light pane, grey on a dark one. The
                // project swatches in settings are ringed for the same reason.
                .overlay {
                    Circle().strokeBorder(Palette.textPrimary.opacity(0.12), lineWidth: Metrics.hairline)
                }
                .frame(width: Self.size, height: Self.size)
                .accessibilityLabel(accessibilityName.map { "Colour \($0)" } ?? "")
                .accessibilityHidden(accessibilityName == nil)
        }
    }

    /// Nil for no colour and for a stored value that is not one.
    ///
    /// Asked of `HexColor` first and only then handed to `Color(hexString:)`, which falls back to
    /// the app's blue for anything it cannot read. That fallback is right for a project, which
    /// must have a colour, and wrong here: a workspace whose column holds something unreadable is
    /// a workspace with no mark, and it has to draw nothing rather than draw blue.
    private var tint: Color? {
        guard let hex, HexColor(hex: hex) != nil else { return nil }
        return Color(hexString: hex)
    }
}

/// A colour swatch baked into an `NSImage`, for the menu, where a SwiftUI view cannot go.
///
/// The same problem `RepoIconImage` solves for a project's tile, and solved the same way, for the
/// same measured reason: a menu item has a title slot, an image slot and the state column the tick
/// is drawn in, and the image slot takes an `NSImage` and nothing else. Handed a SwiftUI shape it
/// draws no image at all. See `WorkspaceMenuItems` for the full set of variants that were built
/// and read back.
///
/// Drawn with AppKit rather than rendered from `WorkspaceColourDot` through `ImageRenderer`. A dot
/// is two calls, `ImageRenderer` is a whole SwiftUI layout pass per swatch per redraw of the menu,
/// and ten of those on every right click is not a trade worth making for a filled circle.
@MainActor
enum WorkspaceColourImage {
    private struct Key: Hashable {
        var hex: String
        var size: CGFloat
    }

    private static var cache: [Key: NSImage] = [:]

    /// Twelve points, which is what a menu item's image slot is sized for on this platform: the
    /// row's text is 13 and a taller image makes every row in the menu taller with it.
    static let size: CGFloat = 12

    static func of(_ hex: String, size: CGFloat = size) -> NSImage? {
        guard let colour = HexColor(hex: hex) else { return nil }
        let key = Key(hex: hex.lowercased(), size: size)
        if let cached = cache[key] { return cached }

        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            NSColor(
                srgbRed: CGFloat(colour.red) / 255,
                green: CGFloat(colour.green) / 255,
                blue: CGFloat(colour.blue) / 255,
                alpha: 1
            ).setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            return true
        }
        // Not a template. A template image in a menu is repainted flat in the label's colour,
        // which is exactly how a menu of ten colours comes up as a menu of ten grey dots.
        image.isTemplate = false
        cache[key] = image
        return image
    }
}
