import SwiftUI

/// One file the turn touched, with what it did to it.
struct TurnFileChip: View {
    var file: TurnFile
    /// The worktree the path is shown relative to. See `TurnFile.display(in:)`.
    var worktree: String

    var body: some View {
        HStack(spacing: TranscriptLayout.tight * 2) {
            Text(file.name)
                // The rung `Chip` uses, because a real `Chip` sits beside this one in the same
                // footer whenever a turn touched more files than fit.
                .font(Typo.codeSmall)
                .foregroundStyle(Palette.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)

            DiffStatLabel(additions: file.additions, deletions: file.deletions, compact: true)
        }
        .padding(.horizontal, TranscriptLayout.chipInset)
        .padding(.vertical, Metrics.chipInsetV)
        .background(Palette.hover, in: RoundedRectangle(cornerRadius: Metrics.cornerSmall))
        // Never squashed. In a split pane the footer ran out of room and every chip compressed to
        // an empty grey box a few points wide: a row of rounded rectangles saying nothing at all.
        // `TurnFooterView` decides how many chips there is room for; a chip that is drawn is drawn
        // whole.
        .fixedSize()
        // Said once, in the form the rest of the window says it in.
        //
        // It was said three times: `.help` gives a tooltip AND an accessibility help string, and
        // `children: .combine` merged that string with the ones underneath it, so VoiceOver read
        // the same absolute path over and over. `.ignore` takes the label this row gives it and
        // nothing else.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken)
        .help(display)
    }

    private var display: String { file.display(in: worktree) }

    /// The chip as a sentence: what the file is called and what happened to it. The counts are
    /// drawn as two coloured numbers, which read as "plus nine minus one" and mean nothing.
    private var spoken: String {
        var parts = [display]
        if file.additions > 0 { parts.append("\(file.additions) added") }
        if file.deletions > 0 { parts.append("\(file.deletions) removed") }
        return parts.joined(separator: ", ")
    }
}
