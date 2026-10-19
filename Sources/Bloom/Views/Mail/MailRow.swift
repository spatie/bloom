import SwiftUI
import BloomCore

/// One message in Mail's list: who sent it, when, what it is about, and the first
/// line of it.
///
/// Sender, subject and preview share a left edge, with the time at the far right of the sender.
/// The sender and subject carry the unread emphasis without moving every row for a separate dot.
struct MailRow: View {
    var summary: MailpitSummary

    @Environment(\.isOnEmphasizedSelection) private var isOnSelection

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.spacingHair) {
            HStack(alignment: .firstTextBaseline, spacing: Metrics.spacingSmall) {
                Text(summary.from?.display ?? "Unknown sender")
                    .font(summary.isRead ? Typo.labelEmphasis : Typo.title)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(1)
                Spacer(minLength: Metrics.spacingSmall)
                TimelineView(.everyMinute) { context in
                    Text(Self.when(summary.created, now: context.date))
                        .font(Typo.caption)
                        .monospacedDigit()
                        .foregroundStyle(secondary)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }

            HStack(spacing: Metrics.spacingSmall) {
                Text(summary.subject.isEmpty ? "No subject" : summary.subject)
                    .font(summary.isRead ? Typo.label : Typo.labelEmphasis)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if summary.attachments > 0 {
                    Spacer(minLength: Metrics.spacingSmall)
                    Image(systemName: "paperclip")
                        .font(Typo.caption)
                        .foregroundStyle(secondary)
                        .accessibilityLabel(summary.attachments == 1 ? "1 attachment" : "\(summary.attachments) attachments")
                }
            }
            if !summary.snippet.isEmpty {
                Text(summary.snippet)
                    .font(Typo.caption)
                    .foregroundStyle(secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .padding(.horizontal, Metrics.inset)
        .padding(.vertical, Metrics.spacingWide)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityValue(summary.isRead ? "" : "Unread")
    }

    private var secondary: Color {
        isOnSelection ? Palette.selectedEmphasizedText : Palette.textSecondary
    }

    /// Clock time for today's mail, yesterday by name, and a calendar date for older mail.
    static func when(_ date: Date, now: Date = .now) -> String {
        guard date != .distantPast else { return "" }
        let calendar = Calendar.current
        if calendar.isDate(date, inSameDayAs: now) {
            return date.formatted(.dateTime.hour().minute())
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) { return "Yesterday" }
        if calendar.isDate(date, equalTo: now, toGranularity: .year) {
            return date.formatted(.dateTime.day().month(.abbreviated))
        }
        return date.formatted(.dateTime.day().month(.abbreviated).year())
    }
}
