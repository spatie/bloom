import SwiftUI
import AppKit
import BloomCore

/// The X that takes a chip off: a drawn glyph on a plate, in the chip's leading slot.
///
/// One view for the three chips that are views. `AttachmentChip`, `SlashCommandChip` and
/// `ReviewCommentChip` all swap their leading icon for this under the pointer, so the chip keeps
/// exactly the width it had and the row does not reflow while somebody is aiming at it.
///
/// It reads `isOnEmphasizedSelection` itself rather than being told which ground it is on. Only
/// the attachment chip is ever drawn inside a sent turn's accent bubble, and a caller that has to
/// pass the ground through is a caller that can forget to, which is the shape of the bug this
/// whole file is here about. The environment value is already set by whatever drew the bubble.
///
/// The fourth chip is not here and cannot be. See `ChipRemoveImage` below, and `ChipRemoveMark`
/// for the numbers the two of them share.
struct ChipRemoveButton: View {
    /// The disc's diameter, which is the chip's icon slot rather than a size of its own: the
    /// control replaces the icon, it does not sit beside it.
    var diameter: CGFloat
    /// The tooltip and the accessibility label, both. It names the thing being removed, because a
    /// strip of four chips whose buttons all say "Remove" is a strip of four identical controls
    /// to anybody not looking at it.
    var label: String
    var action: @MainActor () -> Void

    /// The pointer on the control itself, which is a smaller target than the chip around it.
    @State private var isHovered = false

    @Environment(\.isOnEmphasizedSelection) private var isOnSelection

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: ChipRemoveMark.glyphPointSize(diameter: diameter), weight: .bold))
                .foregroundStyle(ink)
                .frame(width: diameter, height: diameter)
                .background(plate, in: Circle())
                .overlay {
                    Circle().strokeBorder(ring, lineWidth: Metrics.hairline)
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHoverChange { isHovered = $0 }
        .help(label)
        .accessibilityLabel(label)
    }

    /// Full strength, because this glyph is the whole control. The rest of the chip is allowed to
    /// be quiet; the thing that throws the file away is not.
    private var ink: Color {
        isOnSelection ? Palette.selectedEmphasizedText : Palette.textPrimary
    }

    /// The plate the X sits on, which darkens under the pointer so the press has somewhere to
    /// land before it happens.
    ///
    /// `surface` under a chip whose own plate is `surfaceRaised`: a shade off it in dark, and in
    /// light the same white with the ring doing the separating, which is the same step the chip
    /// itself takes off the strip it is in.
    private var plate: Color {
        guard isOnSelection else {
            return isHovered ? Palette.hover : Palette.surface
        }
        return Palette.selectedEmphasizedText
            .opacity(isHovered ? ChipRemoveMark.emphasisPlateHovered : ChipRemoveMark.emphasisPlate)
    }

    private var ring: Color {
        isOnSelection
            ? Palette.selectedEmphasizedText.opacity(ChipRemoveMark.emphasisRing)
            : Palette.border
    }
}

/// The same mark as an `NSImage`, for the one chip that cannot hold a view.
///
/// `AttachmentChipCell` draws a file inside the composer's line of text, through TextKit 1, which
/// has nowhere to put a `ChipRemoveButton`. So the control is built here instead, out of the same
/// numbers, and the two are two drawings of one decision rather than two guesses at it. It is the
/// same split `WorkspaceColourDot` and `WorkspaceColourImage` already live on, for the same
/// reason: a slot that takes an `NSImage` and nothing else.
///
/// Not rendered from the SwiftUI view through `ImageRenderer`. This is a disc and a glyph, and
/// `ImageRenderer` is a whole SwiftUI layout pass, run inside a text view's draw.
@MainActor
enum ChipRemoveImage {
    /// Nil where the symbol will not load, so the caller can fall back to the file's own icon
    /// rather than draw a plate with nothing on it.
    ///
    /// The colours are handed in rather than read from the palette here, because the ground a
    /// chip in a line of text sits on is the caller's fact: see `AttachmentChipCell.Ground` for
    /// why an `NSColor` inside a text view cannot simply be a dynamic pair.
    static func of(
        diameter: CGFloat, ink: NSColor, plate: NSColor, border: NSColor, label: String
    ) -> NSImage? {
        let size = NSImage.SymbolConfiguration(
            pointSize: ChipRemoveMark.glyphPointSize(diameter: diameter), weight: .bold
        )
        // The X carries a colour of its own, so it is drawn with a palette rather than left as a
        // template to be repainted in whatever ink the surrounding text is set in.
        let colour = NSImage.SymbolConfiguration(paletteColors: [ink])
        guard let glyph = NSImage(systemSymbolName: "xmark", accessibilityDescription: label)?
            .withSymbolConfiguration(size.applying(colour)) else { return nil }

        let hairline = Metrics.hairline
        // Sized in POINTS, with the drawing deferred: an `NSCustomImageRep` is asked to draw
        // again at whatever scale the display it lands on has, so the disc is a circle on a
        // Retina screen rather than a fourteen pixel bitmap stretched over twenty-eight.
        let image = NSImage(size: NSSize(width: diameter, height: diameter), flipped: false) { rect in
            // Inset by half the line, because a stroked path straddles it: without this the ring
            // is drawn half outside the disc and the control is a point wider than the slot the
            // line was laid out around.
            let disc = NSBezierPath(ovalIn: rect.insetBy(dx: hairline / 2, dy: hairline / 2))
            plate.setFill()
            disc.fill()
            border.setStroke()
            disc.lineWidth = hairline
            disc.stroke()

            let glyphSize = glyph.size
            glyph.draw(
                in: NSRect(
                    x: rect.midX - glyphSize.width / 2,
                    y: rect.midY - glyphSize.height / 2,
                    width: glyphSize.width,
                    height: glyphSize.height
                ),
                from: .zero,
                operation: .sourceOver,
                fraction: 1
            )
            return true
        }
        // Not a template. A template image is repainted flat in one ink, which would knock the
        // plate and the X back into the single grey smudge this control was rebuilt to stop
        // being. It carries two colours of its own now.
        image.isTemplate = false
        image.accessibilityDescription = label
        return image
    }
}
