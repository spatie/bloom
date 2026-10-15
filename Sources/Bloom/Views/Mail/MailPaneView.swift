import SwiftUI
import QuickLook
import BloomCore

/// The message selected in the app-wide Mail destination, with headers and body.
///
/// This view asks Mailpit again whenever anything leaves the mailbox, so a message deleted here
/// or in Mailpit's own UI turns into
/// "Message deleted" rather than staying on screen as if it were still there.
struct MailPaneView: View {
    @Environment(\.openURL) private var openURL

    private enum Loaded: Equatable {
        case loading
        case message(MailpitMessage)
        case failed(MailpitFailure)
    }

    private enum Part: String, CaseIterable, Identifiable {
        case html = "HTML"
        case text = "Text"
        case source = "Source"
        var id: String { rawValue }
    }

    private struct Ask: Equatable {
        var message: MailpitMessageID?
        var removals: Int
    }

    private var mailbox: Mailbox { .shared }

    @State private var loaded: Loaded = .loading
    @State private var part: Part = .html
    @State private var source: Result<String, MailpitFailure>?
    @State private var preview: URL?
    /// What the last attachment saved said, under the chips, until the next message.
    @State private var saved: String?

    var body: some View {
        Group {
            if let id = mailbox.selection {
                switch loaded {
                case .loading:
                    LoadingView("Opening the message")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .failed(.notFound):
                    EmptyStateView(
                        glyph: "trash",
                        title: "Message deleted",
                        message: "This message is no longer in the inbox. Pick another from the list."
                    )
                case .failed(let failure):
                    EmptyStateView(
                        glyph: "exclamationmark.triangle",
                        title: "Could not open the message",
                        message: failure.message,
                        actionTitle: "Try Again",
                        action: { Task { await load(id, quietly: false) } }
                    )
                case .message(let message):
                    reading(message)
                }
            } else {
                EmptyStateView(
                    glyph: "envelope",
                    title: "No message open",
                    message: "Pick a message from the list."
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.surface)
        .task(id: Ask(message: mailbox.selection, removals: mailbox.removals)) {
            guard let id = mailbox.selection else { return }
            // Asked again after a removal elsewhere, the message on screen stays on screen while
            // the answer comes back; only a different message starts from a spinner.
            let isSame = if case .message(let shown) = loaded { shown.id == id } else { false }
            await load(id, quietly: isSame)
        }
        .quickLookPreview($preview)
    }

    private func load(_ id: MailpitMessageID, quietly: Bool) async {
        if !quietly {
            loaded = .loading
            source = nil
            saved = nil
        }
        let result = await mailbox.message(id)
        // The selection moved on while this was in flight.
        guard mailbox.selection == id, !Task.isCancelled else { return }
        switch result {
        case .success(let message):
            if loaded != .message(message) { loaded = .message(message) }
            if !quietly { part = message.html.isEmpty ? .text : .html }
        case .failure(let failure):
            loaded = .failed(failure)
        }
    }

    // MARK: - The message

    private func reading(_ message: MailpitMessage) -> some View {
        VStack(spacing: 0) {
            MailMessageHeader(
                message: message,
                saved: saved,
                onPreview: { attachment in Task { await quickLook(attachment, of: message.id) } },
                onSave: { attachment in Task { await save(attachment, of: message.id) } }
            )
            Hairline()
            bar(message)
            Hairline()
            content(of: message)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func bar(_ message: MailpitMessage) -> some View {
        HStack(spacing: InspectorLayout.gap) {
            Picker("Show", selection: $part) {
                ForEach(parts(of: message)) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .controlSize(.small)

            Spacer(minLength: 0)

            Button("Delete", systemImage: "trash") {
                mailbox.deleteAndSelectNext(message.id)
            }
            .labelStyle(.iconOnly)
            .inspectorBarControl()
            .help("Delete this message")
        }
        .padding(.horizontal, InspectorLayout.inset)
        .frame(height: InspectorLayout.barHeight)
    }

    /// HTML only when the message has some: a plain text email offered an HTML view that is blank
    /// would read as the view having failed.
    private func parts(of message: MailpitMessage) -> [Part] {
        message.html.isEmpty ? [.text, .source] : Part.allCases
    }

    @ViewBuilder
    private func content(of message: MailpitMessage) -> some View {
        switch part {
        case .html:
            if let url = mailbox.htmlURL(of: message.id) {
                MailBodyWebView(url: url) { link in openURL(link) }
            }
        case .text:
            ScrollView {
                Text(message.text.isEmpty ? "This message has no plain text part." : message.text)
                    .font(Typo.body)
                    .foregroundStyle(message.text.isEmpty ? Palette.textSecondary : Palette.textPrimary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Metrics.inset)
            }
        case .source:
            switch source {
            case .success(let text):
                ScrollView([.vertical, .horizontal]) {
                    Text(text)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(Metrics.inset)
                }
            // Said, with a way to ask again, rather than a spinner that never stops: the source is
            // a second request, and it can fail when the message did not.
            case .failure(let failure):
                EmptyStateView(
                    glyph: "exclamationmark.triangle",
                    title: "Could not read the source",
                    message: failure.message,
                    actionTitle: "Try Again",
                    action: { source = nil }
                )
            case nil:
                LoadingView("Reading the source")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .task(id: message.id) { source = await mailbox.source(of: message.id) }
            }
        }
    }

    // MARK: - Attachments

    private func quickLook(_ attachment: MailpitAttachment, of id: MailpitMessageID) async {
        if let url = await mailbox.preview(attachment, of: id) { preview = url }
    }

    private func save(_ attachment: MailpitAttachment, of id: MailpitMessageID) async {
        guard let url = await mailbox.saveToDownloads(attachment, of: id) else { return }
        saved = "Saved \(url.lastPathComponent) to Downloads."
    }
}
