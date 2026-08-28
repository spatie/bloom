import BloomCore
import SwiftUI

/// One user turn that can stand for the output beneath it while its full bubble is off screen.
struct PinnedQuestion: Equatable {
    var seq: Int
    var summary: String
}

/// The user turns seen in one session, extended only over rows that have just arrived.
///
/// `TranscriptListView.measured` runs on every scroll frame. Looking backwards through the whole
/// transcript there would put a session-length scan on the hottest path in the chat. This index
/// makes that lookup logarithmic and rebuilding it remains an append-only cost.
struct PinnedQuestionIndex {
    private var session: SessionID?
    private var scannedRows = 0
    private var questions: [PinnedQuestion] = []

    mutating func update(session: SessionID, rows: [TranscriptRow]) {
        if self.session != session || scannedRows > rows.count {
            self.session = session
            scannedRows = 0
            questions = []
        }

        guard scannedRows < rows.count else { return }
        for row in rows[scannedRows...] where row.kind == .user {
            guard let summary = UserTurnPrompt.summary(in: row.payload) else { continue }
            questions.append(PinnedQuestion(seq: row.seq, summary: summary))
        }
        scannedRows = rows.count
    }

    func latest(atOrBefore seq: Int) -> PinnedQuestion? {
        var low = 0
        var high = questions.count
        while low < high {
            let middle = low + (high - low) / 2
            if questions[middle].seq <= seq {
                low = middle + 1
            } else {
                high = middle
            }
        }
        return low > 0 ? questions[low - 1] : nil
    }
}

/// A quiet, toolbar-like reminder of the question whose answer is under the reader.
///
/// It is deliberately not another blue bubble. The full bubble is conversation content; this is
/// navigation, so it uses a translucent Mac header surface, one line and an upward arrow. The
/// entire forty-point band is the hit target and the full question remains at its real position.
struct PinnedQuestionView: View {
    var question: PinnedQuestion
    var onOpen: () -> Void

    /// The space navigation to a question must leave above its real bubble.
    static let height: CGFloat = 40

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: Metrics.spacingWide) {
                Image(systemName: "arrow.up")
                    .font(Typo.captionEmphasis)
                    .foregroundStyle(Palette.accent)
                    .accessibilityHidden(true)

                Text("You")
                    .font(Typo.captionEmphasis)
                    .foregroundStyle(Palette.accent)

                Text(question.summary)
                    .font(Typo.label)
                    .foregroundStyle(Palette.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, TranscriptLayout.inset + Metrics.spacingSmall)
            .frame(
                maxWidth: .infinity,
                minHeight: Self.height,
                maxHeight: Self.height,
                alignment: .leading
            )
            .contentShape(Rectangle())
            .background(isHovered ? Palette.hover : .clear)
        }
        .buttonStyle(.plain)
        .background(.regularMaterial)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Palette.border).frame(height: Metrics.outline)
        }
        .onHover { hovered in
            withAnimation(reduceMotion ? nil : Motion.hover) { isHovered = hovered }
        }
        .help("Show the full question")
        .accessibilityLabel("Show question: \(question.summary)")
    }
}
