import SwiftUI
import BloomCore

/// The agent stopped in a way it did not choose. One sentence, with the whole of stderr behind it.
///
/// The row draws `AgentExit` and decides nothing itself. What used to be here was the last lines
/// of stderr passed straight to a `Text`, which for a CLI that dies inside its own bundle is a
/// screenful of minified JavaScript where the explanation should be.
struct AgentErrorRowView: View {
    var exit: AgentExit
    var isExpanded: Bool
    var onToggle: () -> Void

    @State private var isHovered = false
    @State private var showsAll = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ExpandableRowHeader(isExpanded: isExpanded, onToggle: onToggle) {
                header
            }

            if isExpanded {
                opened
            }
        }
        .modifier(ExpandableRow(isHovered: isHovered))
        .onHover { isHovered = $0 }
    }

    private var header: some View {
        HStack(spacing: TranscriptLayout.glyphGap) {
            TranscriptGlyph(symbol: "exclamationmark.triangle", tint: Palette.negative)

            Text(exit.title)
                .font(Typo.label)
                .foregroundStyle(Palette.negative)
                .lineLimit(1)
                .truncationMode(.tail)
                .transcriptLabelColumn(exit.title, font: Typo.label)

            Text(exit.summary)
                .font(Typo.label)
                .foregroundStyle(Palette.textTertiary)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: TranscriptLayout.tight)

            TranscriptDisclosure(isExpanded: isExpanded, isVisible: isHovered)
        }
        .transcriptRowFrame()
    }

    /// What the row says once it is open: the way out first, then the output it was read from.
    ///
    /// The advice comes first on purpose. A turn that ends in red leaves a person wondering
    /// whether their worktree survived, and that answer must not be underneath a crash dump.
    @ViewBuilder
    private var opened: some View {
        VStack(alignment: .leading, spacing: TranscriptLayout.tight * 2) {
            HStack(alignment: .firstTextBaseline, spacing: TranscriptLayout.glyphGap) {
                Image(systemName: "lifepreserver")
                    .font(Typo.caption)
                    .imageScale(.small)
                    .foregroundStyle(Palette.textTertiary)
                    .accessibilityHidden(true)

                Text(exit.advice)
                    .font(Typo.label)
                    .foregroundStyle(Palette.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }

            if exit.hasDetail {
                detail
            }
        }
        .padding(.leading, TranscriptLayout.block)
        .padding(.vertical, TranscriptLayout.tight)
        .overlay(alignment: .leading) {
            // The quote mark for the block, in the colour every quote rule in the transcript uses.
            Rectangle()
                .fill(Palette.border)
                .frame(width: TranscriptLayout.rule)
        }
        .padding(.leading, TranscriptLayout.detailIndent)
        .padding(.trailing, TranscriptLayout.inset)
        .padding(.bottom, TranscriptLayout.block)
    }

    /// Everything the process wrote, folded the way a long tool result is folded.
    ///
    /// Capped by characters as well as by lines, because a bundle arrives as one line and a line
    /// count cannot hold it. Opening it out is one click, so nothing is lost, but the row does not
    /// unfold twenty five thousand characters at a person who only wanted to know what broke.
    @ViewBuilder
    private var detail: some View {
        // Measured at the FOLDED cap whichever way round the dump is, because the question the
        // control answers is whether there is more here than the fold shows, and the opened-out
        // text answers no to that. Asked of whatever was on screen, the way back left the screen
        // the moment somebody took it.
        let folded = TextCap.cap(
            exit.detail, lines: Self.detailLines, characters: Self.detailCharacters
        )
        let shown = showsAll
            ? TextCap.cap(exit.detail, lines: .max, characters: TextCap.characterCap).text
            : folded.text

        VStack(alignment: .leading, spacing: TranscriptLayout.tight * 2) {
            Text(shown)
                .font(Typo.code)
                // The ordinary ink, not `negative`. `WorkspaceEvent.failureSummary` makes exactly
                // this argument for the setup log and acted on it: a script that created a
                // symlink, restarted nginx and issued a certificate before it stopped is mostly
                // success, and painting all of it red said the opposite. The headline above is
                // already `negative` and is what says the turn failed; this block is the evidence.
                .foregroundStyle(Palette.textSecondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

            if folded.truncated {
                Button(TextFold.title(isExpanded: showsAll)) { showsAll.toggle() }
                    .linkButton()
                    .font(Typo.caption)
            }
        }
    }

    /// A crash dump is a screenful before it is anything else, so the fold is tighter than the one
    /// on a tool result.
    private static let detailLines = 40
    private static let detailCharacters = 4_000
}
