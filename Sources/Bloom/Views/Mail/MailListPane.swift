import SwiftUI
import BloomCore

/// The list in the app-wide Mail destination: Mailpit's mailbox, newest first and live.
///
/// Built the way `ChangedFileList` is, as a `ScrollView` of rows with `ListKeyboardHost` behind
/// it, for the reason that list gives: a `List` brings drawing these rows would lose, and the
/// keyboard is what the host is for.
struct MailListPane: View {
    @Bindable private var mailbox = Mailbox.shared
    @State private var keyboard = ListKeyboard()
    @State private var hasKeyboard = false
    /// Bumped by every click on a row, which is what hands the keyboard to the list.
    @State private var arm = 0
    @State private var isConfirmingDeleteAll = false

    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(spacing: 0) {
            InspectorFilterField(
                query: $mailbox.query,
                onEscape: { mailbox.query = "" },
                onReturn: enterList,
                placeholder: "Search incoming mails"
            )
            Hairline()

            if mailbox.hasReadList, mailbox.list.total > 0 {
                countBand
                Hairline()
            }

            if let notice = mailbox.notice {
                PaneNotice(notice: notice) { mailbox.notice = nil }
                Hairline()
            }
            // Whenever a list that has been read stops being live, whether or not it has rows. With
            // none, "No incoming mails" under no band read as a mailbox waiting for mail that
            // could not arrive. Before the first read the empty state below says it instead, and a password
            // prompt has a state of its own.
            if case .disconnected(let failure) = mailbox.connection, failure != .unauthorised, mailbox.hasReadList {
                disconnected(failure)
                Hairline()
            }

            ScrollViewReader { proxy in
                content
                    .onChange(of: mailbox.selection) { _, id in
                        guard hasKeyboard, let id else { return }
                        proxy.scrollTo(id)
                    }
            }
            .listKeyboard(hasKeyboard: $hasKeyboard, armToken: arm, onKey: handle)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onChange(of: hasKeyboard) { _, focused in
            if !focused { keyboard.forgetTyping() }
        }
        .confirmationDialog(
            mailbox.list.deleteAllQuestion,
            isPresented: $isConfirmingDeleteAll,
            titleVisibility: .visible
        ) {
            Button("Delete All", role: .destructive) { mailbox.deleteAll() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This deletes every message from the connected inbox at \(mailbox.address). It cannot be undone.")
        }
    }

    /// How much mail there is, and the one control that removes all of it.
    ///
    /// A labelled button behind a confirmation rather than the bare trash glyph it started as, in
    /// the toolbar beside the worktree menu. That glyph was reported as unclear, and it deleted the
    /// whole mailbox on one click: in a row of icons about the worktree it read as something about
    /// files. Here it sits next to the count it would clear, and says what it does.
    private var countBand: some View {
        HStack(spacing: InspectorLayout.gap) {
            Text(mailbox.list.countLine)
                .font(Typo.caption)
                .foregroundStyle(Palette.textSecondary)
                .lineLimit(1)
            Spacer(minLength: 0)
            Button("Delete All…") { isConfirmingDeleteAll = true }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .foregroundStyle(Palette.negative)
                .help("Delete every incoming message, after asking")
        }
        .padding(.horizontal, InspectorLayout.inset)
        .frame(height: InspectorLayout.barHeight)
    }

    @ViewBuilder
    private var content: some View {
        let list = mailbox.list
        if let error = mailbox.bundledError, list.messages.isEmpty {
            EmptyStateView(
                glyph: "envelope.badge.shield.half.filled",
                title: "Can't start incoming mails",
                message: error,
                actionTitle: "Try Again",
                action: mailbox.retry
            )
        } else if case .disconnected(.unauthorised) = mailbox.connection {
            EmptyStateView(
                glyph: "lock",
                title: "Inbox requires a password",
                message: MailpitFailure.unauthorised.message,
                actionTitle: "Incoming mail settings",
                action: showSettings
            )
        } else if list.messages.isEmpty, !mailbox.hasReadList {
            if case .disconnected(let failure) = mailbox.connection {
                EmptyStateView(
                    glyph: "envelope.badge.shield.half.filled",
                    title: "Can't connect to the inbox",
                    message: "\(failure.message) Bloom will retry at \(mailbox.address).",
                    actionTitle: "Try Again",
                    action: mailbox.retry
                )
            } else {
                LoadingView("Loading incoming mails")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else if list.messages.isEmpty {
            if list.query.isEmpty {
                EmptyStateView(
                    glyph: "tray",
                    title: "No incoming mails",
                    message: "Messages your app sends to the connected test inbox appear here."
                )
            } else {
                EmptyStateView(
                    glyph: "magnifyingglass",
                    title: "No matches",
                    message: "No incoming mails match \(list.query)."
                )
            }
        } else {
            rows(list)
        }
    }

    private func rows(_ list: MailboxList) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(list.messages) { summary in
                    HoverRow(isSelected: mailbox.selection == summary.id, isFocused: hasKeyboard) {
                        MailRow(summary: summary)
                    }
                    .padding(.horizontal, InspectorLayout.tight)
                    .id(summary.id)
                    .onTapGesture { activate(summary.id) }
                    .contextMenu {
                        Button("Open") { activate(summary.id) }
                        Divider()
                        Button("Delete", role: .destructive) { mailbox.deleteAndSelectNext(summary.id) }
                    }
                    .onAppear {
                        if summary.id == list.messages.last?.id { mailbox.loadMore() }
                    }
                    if summary.id != list.messages.last?.id,
                       mailbox.selection != summary.id {
                        Rectangle()
                            .fill(Palette.border)
                            .frame(height: Metrics.outline)
                            .padding(.leading, InspectorLayout.tight + Metrics.inset)
                            .padding(.trailing, InspectorLayout.tight)
                            .accessibilityHidden(true)
                    }
                }
                if mailbox.isLoadingPage {
                    ProgressView()
                        .controlSize(.small)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, Metrics.spacing)
                }
            }
            .padding(.vertical, InspectorLayout.tight)
        }
    }

    /// The band over a list that is no longer live: the rows are what Mailpit last said, and the
    /// band says so rather than letting them pass for current.
    private func disconnected(_ failure: MailpitFailure) -> some View {
        HStack(spacing: InspectorLayout.gap) {
            ProgressView()
                .controlSize(.mini)
            Text("Inbox disconnected, retrying")
                .font(Typo.caption)
                .foregroundStyle(Palette.textSecondary)
                .lineLimit(1)
                .help(mailbox.bundledError ?? failure.message)
            Spacer(minLength: 0)
            Button("Try Again", action: mailbox.retry)
                .buttonStyle(.borderless)
                .controlSize(.small)
        }
        .padding(.horizontal, InspectorLayout.inset)
        .frame(height: InspectorLayout.barHeight)
    }

    // MARK: - Doing

    private func activate(_ id: MailpitMessageID) {
        arm += 1
        mailbox.select(id)
    }

    /// Return in the search field: the keyboard goes to the list, on the first row if nothing is
    /// selected yet.
    private func enterList() {
        if mailbox.selection.map({ mailbox.list.contains($0) }) != true,
           let first = mailbox.list.messages.first?.id {
            mailbox.select(first)
        }
        arm += 1
    }

    private func showSettings() {
        SettingsTabRequest.post(.mail)
        openSettings()
    }

    private func handle(key: ListKey) -> Bool {
        let messages = mailbox.list.messages
        let index = mailbox.selection.flatMap { id in messages.firstIndex { $0.id == id } }

        // Delete and Backspace arrive as characters, and type-select would otherwise take them as
        // the start of a word.
        if case .character(let character) = key, character == "\u{7F}" || character == "\u{08}" {
            guard let selection = mailbox.selection, index != nil else { return false }
            mailbox.deleteAndSelectNext(selection)
            return true
        }

        switch keyboard.outcome(for: key, titles: messages.map(\.subject), current: index) {
        case .move(let row):
            mailbox.select(messages[row].id)
            return true
        case .activate:
            guard let selection = mailbox.selection else { return false }
            mailbox.select(selection)
            return true
        case .handled:
            return true
        case .ignored:
            return false
        }
    }
}
