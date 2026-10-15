import SwiftUI
import BloomCore

/// One message in Mail's list: who sent it, when, what it is about, and the first
/// line of it.
///
/// Three lines rather than the one a changed file gets, because the question a reader brings to
/// this list is "which of these is the email I just triggered", and the sender and the time answer
/// it faster than the subject does when an app sends five of the same subject in a row.
struct MailRow: View {
    var summary: MailpitSummary

    @Environment(\.isOnEmphasizedSelection) private var isOnSelection

    var body: some View {
        HStack(alignment: .top, spacing: InspectorLayout.gap) {
            // The unread dot, in a column of its own so read and unread rows keep one left edge.
            Circle()
                .fill(summary.isRead ? Color.clear : (isOnSelection ? Palette.selectedEmphasizedText : Palette.accent))
                .frame(width: 7, height: 7)
                .padding(.top, 5)
                .frame(width: InspectorLayout.glyphWidth / 2)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: Metrics.spacingSmall) {
                    Text(summary.from?.display ?? "Unknown sender")
                        .font(summary.isRead ? Typo.body : Typo.bodyEmphasis)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: Metrics.spacingSmall)
                    if summary.attachments > 0 {
                        Image(systemName: "paperclip")
                            .font(Typo.micro)
                            .imageScale(.small)
                            .foregroundStyle(secondary)
                            .accessibilityLabel(summary.attachments == 1 ? "1 attachment" : "\(summary.attachments) attachments")
                    }
                    // A minute's resolution, so "4 min. ago" keeps counting while the list sits
                    // still instead of saying it until the next message redraws the row.
                    TimelineView(.everyMinute) { context in
                        Text(Self.when(summary.created, now: context.date))
                            .font(Typo.micro)
                            .monospacedDigit()
                            .foregroundStyle(secondary)
                            .lineLimit(1)
                    }
                }
                Text(summary.subject.isEmpty ? "No subject" : summary.subject)
                    .font(Typo.caption)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if !summary.snippet.isEmpty {
                    Text(summary.snippet)
                        .font(Typo.caption)
                        .foregroundStyle(secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
        }
        .padding(.horizontal, InspectorLayout.gap)
        .padding(.vertical, Metrics.spacingSmall)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityValue(summary.isRead ? "" : "Unread")
    }

    private var secondary: Color {
        isOnSelection ? Palette.selectedEmphasizedText : Palette.textSecondary
    }

    /// "4 min. ago" for today's mail, which is nearly all of it, and the date for anything older,
    /// where how many hours ago stops being the useful half.
    static func when(_ date: Date, now: Date = .now) -> String {
        guard date != .distantPast else { return "" }
        if Calendar.current.isDate(date, inSameDayAs: now) {
            return date.formatted(.relative(presentation: .named, unitsStyle: .abbreviated))
        }
        return date.formatted(.dateTime.day().month(.abbreviated))
    }
}
