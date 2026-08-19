import SwiftUI
import BloomCore

/// What an opened row says when the call never ran.
///
/// It takes the place of `ToolResultView` rather than sitting beside it, because for a refusal the
/// result *is* this sentence: the CLI hands back one line of explanation where output would have
/// been. Set in the reading face rather than the code face for the same reason, since none of it
/// came from a tool.
///
/// The remedy is the point of the whole row. A denial is the one kind of thing in a transcript the
/// user can undo from where they are standing, by picking a different permission mode under the
/// composer, and a row that only says "denied" leaves them to work that out.
struct ToolRefusalView: View {
    var refusal: ToolRefusal
    /// The sentence the CLI gave. Falls back to the refusal's own wording when it gave none.
    var reason: String

    private var sentence: String {
        reason.isEmpty ? refusal.summary : reason
    }

    var body: some View {
        VStack(alignment: .leading, spacing: TranscriptLayout.tight * 2) {
            HStack(alignment: .firstTextBaseline, spacing: TranscriptLayout.glyphGap) {
                Image(systemName: "hand.raised")
                    .font(Typo.caption)
                    .imageScale(.small)
                    .foregroundStyle(Palette.warning)
                    .accessibilityHidden(true)

                Text(sentence)
                    .font(Typo.label)
                    .foregroundStyle(Palette.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let remedy = refusal.remedy {
                Text(remedy)
                    .font(Typo.caption)
                    .foregroundStyle(Palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    // Lined up under the sentence rather than under the glyph, the way a caption
                    // sits under the line it belongs to.
                    .padding(.leading, TranscriptLayout.glyphWidth + TranscriptLayout.glyphGap)
            }
        }
        .padding(.leading, TranscriptLayout.block)
        .padding(.vertical, TranscriptLayout.tight)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(Palette.warning)
                .frame(width: TranscriptLayout.rule)
        }
    }
}
