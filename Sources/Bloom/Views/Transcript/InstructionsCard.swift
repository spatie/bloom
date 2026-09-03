import SwiftUI
import BloomCore

/// The words a chip stands for, when it stands for words rather than for a file.
///
/// **The same card as the one over a file chip, deliberately, down to the numbers.** A text file is
/// drawn by `AttachmentPreview` as `SourceLines`, cut by `TextHead`, inside a `MenuPanel`, with a
/// caption under a hairline saying where it came from. So is this. The reader hovers a pull
/// request's instructions and a merge's instructions in the same transcript, often two turns apart,
/// and the only honest difference between them is what that caption can say: one of the two has a
/// path and the other one is in the message.
///
/// **It shows what the agent was given and never a summary**, which is the whole point of being
/// able to look. It is cut at `TextHead.lines` and says so with the ellipsis `SourceLines` draws,
/// which is exactly how the file beside it is cut: a glance rather than a reader, and the same
/// glance in both.
struct InstructionsCard: View {
    /// The block, as it went down the wire.
    var text: String
    /// What the pane has to give, which is what the card may take.
    var availableWidth: CGFloat

    /// The box every card over the centre pane takes, which is `HoverCardWidth.ceiling`.
    private static var maxWidth: CGFloat { HoverCardWidth.ceiling }
    private static let minWidth: CGFloat = 240

    var body: some View {
        MenuPanel {
            VStack(alignment: .leading, spacing: 0) {
                if let head = TextHead.head(of: text) {
                    SourceLines(lines: head.lines, truncated: head.truncated)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(Metrics.inset)
                }

                Hairline()

                // Where a file's card puts its path. It is the one line that has to differ, and it
                // is the answer to the question a reader asks of a chip with no filename on it: not
                // a file, and nothing to go and open, because it is in the message above.
                Text("In the message itself")
                    .font(Typo.caption)
                    .foregroundStyle(Palette.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Metrics.inset)
                    .padding(.vertical, Metrics.spacing)
            }
            // A definite width rather than a cap, for `ToolRowCard`'s reason: the overlay measures
            // this card under `fixedSize`, where a `maxWidth` frame is honoured for the card and
            // ignored by the text inside it, and a line of instructions offered no width at all is
            // one very long line.
            .frame(width: width, alignment: .leading)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var width: CGFloat {
        max(min(availableWidth - Metrics.gutter * 2, Self.maxWidth), Self.minWidth)
    }
}
