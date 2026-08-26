import SwiftUI
import BloomCore

/// A block of literal text inside an expanded row: a command, a file's new contents, one side of an
/// edit. Long blocks are cut until asked for, because the row is a detail view and not a pager.
struct DetailCodeBlock: View {
    var text: String
    var tint: Color = Palette.surfaceSunken
    /// What a copy of this block is called, in the caller's words.
    var copyTitle: String = "Copy"

    var body: some View {
        DetailBlock(text: text, font: Typo.code, tint: tint, copyTitle: copyTitle)
    }
}

/// The same block, set in the face prose is read in.
///
/// **Mono is for what a machine said or will run.** A command, a patch, a pattern, a file's new
/// contents: those line up in columns and the columns mean something. The sentence a subagent was
/// handed and the plan an agent wrote before asking to leave plan mode are neither. They are
/// English, often several paragraphs of it, and set in `Typo.code` they read as data: the measure
/// goes to about two thirds of the characters, the line breaks land where nothing broke, and the
/// whole block claims to be something you would paste into a terminal.
///
/// `ToolRowSnapshotGallery` is the page this rule was written on, one surface over, and its own
/// header says the mistake it guards against is "English set in mono". The two blocks under
/// `Task` and `ExitPlanMode` were that mistake in the drawer under the row the gallery
/// photographs.
///
/// Plain text rather than markdown, deliberately. A plan is usually written in markdown, and
/// rendering it here would put a fenced block on a plate inside this plate, and a heading at
/// heading size inside a detail drawer. The row is a receipt of what was asked, not a second
/// place to read a document.
struct DetailProseBlock: View {
    var text: String
    var copyTitle: String = "Copy"

    var body: some View {
        DetailBlock(
            text: text, font: Typo.body, tint: Palette.surfaceSunken, copyTitle: copyTitle
        )
    }
}

/// The plate, the cut and the copy button the two share, so the only thing that varies between
/// them is the face the words are set in.
private struct DetailBlock: View {
    var text: String
    var font: ScaledFont
    var tint: Color
    var copyTitle: String

    @State private var showsAll = false
    @State private var isHovered = false

    var body: some View {
        if !text.isEmpty {
            // Measured at the FOLDED cap whichever way round the block is, because that is the
            // only question worth asking: is there more here than the fold shows. Asking the
            // opened-out text whether it was truncated answers no, which is how the way back used
            // to leave the screen the moment somebody took it.
            let folded = TextCap.cap(text, lines: TextCap.lineCap)
            let shown = showsAll ? TextCap.cap(text, lines: .max).text : folded.text

            VStack(alignment: .leading, spacing: TranscriptLayout.tight * 2) {
                // The button sits in its own column beside the text rather than over it. The text
                // wraps and can be a hundred lines, so an overlay would land on the first line of
                // exactly the blocks worth copying.
                HStack(alignment: .top, spacing: TranscriptLayout.glyphGap) {
                    Text(shown)
                        .font(font)
                        .foregroundStyle(Palette.textPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    // Whole, and deliberately not `shown`: a block that has been folded to
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

                if folded.truncated {
                    Button(TextFold.title(isExpanded: showsAll)) { showsAll.toggle() }
                        .linkButton()
                        .font(Typo.caption)
                }
            }
        }
    }
}
