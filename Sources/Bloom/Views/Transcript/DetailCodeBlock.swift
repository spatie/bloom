import SwiftUI

/// A block of literal text inside an expanded row: a command, a file's new contents, one side of an
/// edit. Long blocks are cut until asked for, because the row is a detail view and not a pager.
struct DetailCodeBlock: View {
    var text: String
    var tint: Color = Palette.surfaceSunken
    /// What a copy of this block is called, in the caller's words.
    var copyTitle: String = "Copy"

    @State private var showsAll = false
    @State private var isHovered = false

    var body: some View {
        if !text.isEmpty {
            let capped = TextCap.cap(text, lines: showsAll ? .max : TextCap.lineCap)

            VStack(alignment: .leading, spacing: TranscriptLayout.tight * 2) {
                // The button sits in its own column beside the text rather than over it. The text
                // wraps and can be a hundred lines, so an overlay would land on the first line of
                // exactly the blocks worth copying.
                HStack(alignment: .top, spacing: TranscriptLayout.glyphGap) {
                    Text(capped.text)
                        .font(Typo.code)
                        .foregroundStyle(Palette.textPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    // Whole, and deliberately not `capped.text`: a block that has been folded to
                    // its first forty lines still copies the file. What is on the pasteboard is
                    // never the version the pane had room for.
                    //
                    // Revealed by the pointer, and at opacity zero rather than absent when it is
                    // not, so an open row does not reflow the moment somebody points at it. The
                    // same bargain `TranscriptDisclosure` makes with the chevron beside it: an
                    // expanded turn can hold a dozen of these, and a dozen sheet icons down the
                    // pane is the noise the transcript spends its whole design avoiding.
                    CopyButton(text: text, title: copyTitle, isVisible: isHovered)
                }
                .padding(TranscriptLayout.inset)
                // `Metrics.corner`, the radius a code fence in prose uses. The two are the
                // same kind of surface and were rounded differently.
                .background(tint, in: RoundedRectangle(cornerRadius: Metrics.corner))
                .onHover { isHovered = $0 }

                if capped.truncated, !showsAll {
                    Button("Show all") { showsAll = true }
                        .linkButton()
                        .font(Typo.caption)
                }
            }
        }
    }
}
