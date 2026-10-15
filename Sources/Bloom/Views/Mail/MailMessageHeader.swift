import SwiftUI
import BloomCore

/// The top of the message reader: the subject, who it is from and to, when, and what it carries.
///
/// The headers are usually what a test email is opened to check (did the reset go to the right
/// address, is the sender the one the app is configured with), so they are drawn in full and
/// selectable rather than folded into a "to me" summary the way a mail client would.
struct MailMessageHeader: View {
    var message: MailpitMessage
    /// What the last save said, if anything has been saved from this message.
    var saved: String?
    var onPreview: (MailpitAttachment) -> Void
    var onSave: (MailpitAttachment) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing) {
            Text(message.subject.isEmpty ? "No subject" : message.subject)
                .font(Typo.heading)
                .foregroundStyle(Palette.textPrimary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: Metrics.spacing, verticalSpacing: 2) {
                if let from = message.from { line("From", [from]) }
                line("To", message.to)
                line("Cc", message.cc)
                line("Bcc", message.bcc)
                line("Reply-To", message.replyTo)
                if message.date != .distantPast {
                    GridRow {
                        label("Date")
                        Text(message.date.formatted(date: .abbreviated, time: .standard))
                            .font(Typo.caption)
                            .foregroundStyle(Palette.textPrimary)
                            .textSelection(.enabled)
                    }
                }
            }

            if !message.attachments.isEmpty {
                attachments
            }
            if let saved {
                Text(saved)
                    .font(Typo.caption)
                    .foregroundStyle(Palette.textSecondary)
            }
        }
        .padding(Metrics.inset)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func line(_ name: String, _ people: [MailpitAddressee]) -> some View {
        if !people.isEmpty {
            GridRow {
                label(name)
                Text(people.map(\.full).joined(separator: ", "))
                    .font(Typo.caption)
                    .foregroundStyle(Palette.textPrimary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func label(_ name: String) -> some View {
        Text(name)
            .font(Typo.caption)
            .foregroundStyle(Palette.textSecondary)
            .gridColumnAlignment(.trailing)
    }

    private var attachments: some View {
        // Wraps rather than scrolls: a message with three invoices should show all three.
        ChipFlow(spacing: Metrics.spacingSmall, lineSpacing: Metrics.spacingSmall) {
            ForEach(message.attachments) { attachment in
                chip(attachment)
            }
        }
    }

    /// The name opens Quick Look and the arrow saves to Downloads, both on the face of the chip.
    ///
    /// Saving was in the context menu alone, which is where nobody looks for the one thing most
    /// people want to do with an attachment, so the chip has two targets and says so. The menu
    /// keeps both for anybody who right clicks.
    private func chip(_ attachment: MailpitAttachment) -> some View {
        HStack(spacing: Metrics.spacingSmall) {
            Button { onPreview(attachment) } label: {
                HStack(spacing: Metrics.spacingSmall) {
                    Image(systemName: "paperclip")
                        .imageScale(.small)
                    Text(attachment.savedName)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(Int64(attachment.size).formatted(.byteCount(style: .file)))
                        .foregroundStyle(Palette.textSecondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Quick Look \(attachment.savedName)")

            Rectangle()
                .fill(Palette.border)
                .frame(width: Metrics.hairline, height: 12)
                .accessibilityHidden(true)

            Button { onSave(attachment) } label: {
                Image(systemName: "arrow.down.circle")
                    .imageScale(.small)
                    .foregroundStyle(Palette.textSecondary)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Save \(attachment.savedName) to Downloads")
            .accessibilityLabel("Save \(attachment.savedName) to Downloads")
        }
        .font(Typo.caption)
        .padding(.horizontal, Metrics.spacing)
        .padding(.vertical, Metrics.spacingSmall)
        .background(Capsule().fill(Palette.surfaceSunken))
        .overlay(Capsule().strokeBorder(Palette.border, lineWidth: Metrics.outline))
        .contextMenu {
            Button("Quick Look") { onPreview(attachment) }
            Button("Save to Downloads") { onSave(attachment) }
        }
    }
}
