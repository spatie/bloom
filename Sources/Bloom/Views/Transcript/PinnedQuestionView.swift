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

/// A quiet reminder of the question whose answer is under the reader.
///
/// It follows the trailing edge where user turns live, but stays chrome rather than becoming a
/// second blue bubble. The full bubble is conversation content; this is navigation. A raised Mac
/// surface keeps that distinction while the position still makes the relationship immediate.
struct PinnedQuestionView: View {
    var question: PinnedQuestion
    var onOpen: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 0) {
            Spacer(minLength: UserTurnRowView.inset)

            Button(action: onOpen) {
                CappedWidth(width: UserTurnRowView.uncappedFallback) {
                    HStack(spacing: Metrics.spacing) {
                        Text("You")
                            .font(Typo.captionEmphasis)
                            .foregroundStyle(Palette.accent)

                        Text(question.summary)
                            .font(Typo.label)
                            .foregroundStyle(Palette.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.tail)

                        Image(systemName: "arrow.up")
                            .font(Typo.captionEmphasis)
                            .foregroundStyle(Palette.accent)
                            .offset(y: isHovered ? -Self.arrowLift : 0)
                            .accessibilityHidden(true)
                    }
                    .padding(.leading, Metrics.gutter)
                    .padding(.trailing, Metrics.inset)
                    .frame(minHeight: Self.height, maxHeight: Self.height)
                    .contentShape(
                        RoundedRectangle(cornerRadius: Self.corner, style: .continuous)
                    )
                }
            }
            .buttonStyle(.plain)
            .background {
                RoundedRectangle(cornerRadius: Self.corner, style: .continuous)
                    .fill(Palette.surfaceRaised)
                    .overlay {
                        RoundedRectangle(cornerRadius: Self.corner, style: .continuous)
                            .fill(isHovered ? Palette.hover : .clear)
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: Self.corner, style: .continuous)
                            .strokeBorder(Palette.border, lineWidth: Metrics.outline)
                    }
            }
            .clipShape(RoundedRectangle(cornerRadius: Self.corner, style: .continuous))
            .elevation(isHovered ? .lifted : .resting)
            .onHover { isHovered = $0 }
            .animation(reduceMotion ? nil : Motion.hover, value: isHovered)
            .help("Show the full question")
            .accessibilityLabel("Show question: \(question.summary)")
        }
        .padding(.top, Metrics.spacingSmall)
        .padding(.horizontal, TranscriptLayout.inset)
    }

    /// A large enough target to acquire without turning the pinned question into a toolbar band.
    static let height: CGFloat = 40
    /// Softer than a speech bubble and rounder than a six-point control.
    private static let corner: CGFloat = 10
    /// Just enough travel to confirm that the control returns to something above.
    private static let arrowLift: CGFloat = 2
}
