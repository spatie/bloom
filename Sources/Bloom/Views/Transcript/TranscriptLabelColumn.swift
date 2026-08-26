import SwiftUI
import AppKit

/// The label at the head of a one line row: as wide as its own text, and never wider than
/// `TranscriptLayout.labelCeiling`.
///
/// It was a fixed 176 point column, which started every detail on the same x. That reads well down
/// a page of long labels and badly down a page of short ones, and short is what most of them are:
/// `Read` measures 28 points, so 147 points of the column it sat in were empty and the eye crossed
/// them to reach the file the row was about. Details no longer line up with each other, which is
/// the trade, and it is the one that was asked for.
///
/// The ceiling is what the column was, so no row is drawn in less room than it had: a label that
/// filled 176 points still fills it and is cut in the same place, and every shorter one hands the
/// difference to its own detail rather than to the gap.
///
/// Measured rather than proposed, because SwiftUI has no "as wide as the text, up to N".
/// `frame(maxWidth:)` fills whatever width it is offered, which is the fixed column again, and
/// `fixedSize()` has no ceiling at all, which lets one long label push a command off the row.
struct TranscriptLabelColumn: ViewModifier {
    /// The same string the label draws, in the same rung it is set in, for the reason
    /// `TruncationProbe` gives: a ruler laid against another face reports a width nothing has.
    var text: String
    var font: ScaledFont

    /// Was a `@ScaledMetric`, which on macOS never moves because there is no Dynamic Type for it to
    /// track, so the ceiling stayed at 176 however large the conversation was set.
    @Environment(\.fontScale) private var fontScale
    @Environment(\.chatFont) private var face

    func body(content: Content) -> some View {
        content.frame(
            width: min(
                TranscriptLabelWidth.of(text, font: font, scale: fontScale, face: face),
                TranscriptLayout.labelCeiling * fontScale
            ),
            alignment: .leading
        )
    }
}

extension View {
    func transcriptLabelColumn(_ text: String, font: ScaledFont) -> some View {
        modifier(TranscriptLabelColumn(text: text, font: font))
    }
}

/// What a label wants, measured once per string.
///
/// AppKit's ruler rather than a hidden `Text`: a second `Text` behind every row is a second layout
/// pass per row per pass, which is the cost `TruncationProbe` goes to the trouble of building for
/// the hovered row alone. This is one CoreText run, 6.6 microseconds measured, and the table means
/// a transcript of four hundred `Read` rows pays for one of them.
@MainActor
enum TranscriptLabelWidth {
    private struct Key: Hashable {
        var text: String
        var font: ScaledFont
        var scale: CGFloat
        var face: ChatFont
    }

    private static var widths: [Key: CGFloat] = [:]

    /// A Bash row's label is the model's own sentence, so this is not a table of tool names and
    /// cannot be left to grow for the life of a window.
    private static let limit = 512

    static func of(_ text: String, font: ScaledFont, scale: CGFloat, face: ChatFont) -> CGFloat {
        let key = Key(text: text, font: font, scale: scale, face: face)
        if let known = widths[key] { return known }

        let measured = (text as NSString)
            .size(withAttributes: [.font: font.resolvedNSFont(scale: scale, face: face)])
            .width
        // A point of slack, rounded up: the ruler is AppKit's and the label is SwiftUI's, and a
        // frame a hair under what the text wants draws an ellipsis where nothing was cut.
        let width = (measured + 1).rounded(.up)

        if widths.count >= limit { widths.removeAll(keepingCapacity: true) }
        widths[key] = width
        return width
    }
}
