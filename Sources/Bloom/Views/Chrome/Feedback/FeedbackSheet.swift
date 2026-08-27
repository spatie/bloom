import AppKit
import SwiftUI
import BloomCore

/// Help ▸ Send Feedback. What is not working, what is missing, and optionally what Bloom said to
/// its own log while it happened.
///
/// **The box is the composer's box**, not a `TextEditor`. That is worth the dependency: it is the
/// surface where pasting a screenshot works, where dragging a picture onto the text works, and
/// where Command+Return already means send. Writing a second text box here would have meant
/// writing a second paste path, and the one that was written this week is the one that knows a
/// CleanShot capture arrives as a file and a screenshot arrives as bytes. See `PastedAttachment`.
///
/// **Nothing is ever lost.** The draft lives on `FeedbackPresenter`, so Escape, a failed send, and
/// a server that is down all leave the paragraph exactly where it was. Only a report the server
/// actually took clears it.
///
/// **The logs checkbox starts on, and then remembers.** It used to start off every time, on the
/// argument that ticking it once was not consent for the next excerpt; what that produced in
/// practice was reports without the one thing that explains them. So it defaults to on, the log
/// is capped and scrubbed by `AppLogExcerpt`, the View link shows exactly what would go, and an
/// untick is remembered rather than overridden. See `Feedback.includesLogs`.
struct FeedbackSheet: View {
    @Environment(AppModel.self) private var app

    @Bindable private var presenter = FeedbackPresenter.shared

    @State private var caret = 0
    @State private var isFocused = false
    @State private var contentHeight = ComposerTextEditor.lineHeight
    @State private var phase: FeedbackPhase = .idle
    @State private var isShowingLogs = false
    @State private var attachmentProblem: String?
    /// Started when the sheet appears and awaited when Send is pressed, so the slowest fact about
    /// this machine is gathered while somebody types rather than while they wait. See
    /// `FeedbackEnvironment`.
    @State private var facts: Task<Feedback.Environment, Never>?
    /// The read of the log, held so a send can wait for the read the checkbox started rather than
    /// starting a second one that could differ from what the View link showed.
    @State private var logsRead: Task<Void, Never>?
    /// Whether Send has been pressed on this opening of the sheet. All this view owns of the
    /// validation story; what it means is `Feedback.sheetProblems`' business.
    @State private var hasTriedToSend = false
    /// Where focus lands when a send is blocked, which on this sheet can only be the address.
    @FocusState private var problemField: Feedback.SheetField?

    /// Five lines to start with, which is a paragraph, and it grows from there.
    private static let minimumEditorLines: CGFloat = 5
    /// Where it stops growing and starts scrolling, so the sheet cannot walk off the screen.
    private static let maximumEditorLines: CGFloat = 14

    private static let width: CGFloat = 620

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.gutter) {
            FeedbackHeader(title: Feedback.Copy.reportTitle, blurb: Feedback.Copy.reportBlurb)

            editor

            if !presenter.images.isEmpty { images }

            if let attachmentProblem {
                Label(attachmentProblem, systemImage: "exclamationmark.triangle.fill")
                    .font(Typo.caption)
                    .foregroundStyle(Palette.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }

            logsRow

            FeedbackEmailField(
                label: Feedback.Copy.reportEmail,
                email: $presenter.email,
                problem: problems.email,
                problemField: $problemField
            )

            FeedbackEnvironmentNote()

            footer
        }
        .padding(Metrics.pane)
        .frame(width: Self.width)
        .background(Palette.surface)
        .task {
            facts = Task { await FeedbackEnvironment.current(app: app) }
            // The keyboard goes to the box, which is the only thing on this sheet anybody came
            // here to use.
            isFocused = true
            // The checkbox can now arrive already ticked, and a tick whose read never started
            // would send `logs` as the empty string it still is. The `onChange` below only fires
            // on a change, so the opening state is this line's job.
            if presenter.includesLogs { readLogs() }
        }
        .onDisappear {
            facts?.cancel()
            phase = .idle
            // The next opening starts clean: a warning held over from last week's attempt would
            // be about text nobody can see any more.
            hasTriedToSend = false
        }
        // `--feedback-logs` opens the excerpt straight away on a capture run, which is the only
        // way a sheet on top of a sheet can be looked at without a human at the keyboard, and
        // `--feedback-problems` stands in for the press of Send that makes the warnings visible.
        .task {
            #if DEBUG
            if CommandLine.arguments.contains("--feedback-problems") { hasTriedToSend = true }
            guard CommandLine.arguments.contains("--feedback-logs") else { return }
            showLogs()
            #endif
        }
        .sheet(isPresented: $isShowingLogs) {
            FeedbackLogSheet(text: presenter.logs) { isShowingLogs = false }
        }
    }

    // MARK: - The box

    private var editor: some View {
        ComposerEditor(
            text: $presenter.message,
            caret: $caret,
            isFocused: $isFocused,
            height: editorHeight,
            onContentHeightChange: { contentHeight = $0 },
            onKey: handle(key:),
            onAttach: attach(sources:replacing:),
            placeholder: Feedback.Copy.reportPlaceholder
        )
        .composerBox(isFocused: $isFocused)
    }

    private var editorHeight: CGFloat {
        let line = ComposerTextEditor.lineHeight
        return min(max(contentHeight, line * Self.minimumEditorLines), line * Self.maximumEditorLines)
    }

    // MARK: - Pictures

    private var images: some View {
        ChipFlow(spacing: Metrics.spacing, lineSpacing: Metrics.spacing) {
            ForEach(presenter.images) { image in
                FeedbackImageChip(image: image) { remove(image) }
            }
        }
    }

    // MARK: - The log

    private var logsRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: Metrics.spacingWide) {
            Toggle(Feedback.Copy.logsToggle, isOn: $presenter.includesLogs)
                .toggleStyle(.checkbox)
                // Explicit so every interactive control reads from the shared semantic token.
                .tint(Palette.controlAccent)
                .font(Typo.caption)

            Button(Feedback.Copy.logsView) { showLogs() }
                .linkButton()
                .font(Typo.caption)
                .help("Read exactly what would be sent")

            Spacer(minLength: Metrics.gutter)

            // Only near the limit, and only then. A counter that is always on turns writing a
            // sentence into filling in a form, and the number matters exactly once: when the
            // endpoint is about to refuse what has been typed. See `Feedback.remainingMessage`.
            if let remaining = Feedback.remainingMessage(
                count: presenter.message.count, limit: Feedback.maxMessageCharacters
            ) {
                Text(remaining)
                    .font(Typo.micro)
                    .foregroundStyle(
                        presenter.message.count > Feedback.maxMessageCharacters
                            ? Palette.warning
                            : Palette.textTertiary
                    )
                    .monospacedDigit()
            }
        }
        .onChange(of: presenter.includesLogs) { _, isOn in
            guard isOn else { return }
            readLogs()
        }
    }

    // MARK: - The buttons

    private var footer: some View {
        HStack(spacing: Metrics.gutter) {
            Button(Feedback.Copy.attachImages, systemImage: "photo.on.rectangle") { pickImages() }
                .disabled(presenter.images.count >= Feedback.maxImages || phase.isSending)
                .help("Up to \(Feedback.maxImages) pictures. You can also paste or drop one on the box above.")

            Spacer(minLength: Metrics.gutter)

            FeedbackStatus(phase: phase)

            Button("Cancel", role: .cancel) { presenter.close() }
                .keyboardShortcut(.cancelAction)
                .disabled(phase.isSending)

            FeedbackSendButton(
                title: Feedback.Copy.reportSend,
                isEnabled: canSend,
                isSending: phase.isSending,
                action: send
            )
        }
    }

    // MARK: - Keys

    /// Returns true when the key was taken, which is how the text view knows not to type it.
    private func handle(key: ComposerKey) -> Bool {
        switch key {
        case .commandReturn:
            send()
            return true
        case .escape:
            guard !phase.isSending else { return true }
            presenter.close()
            return true
        case .up, .down, .returnKey, .tab:
            return false
        }
    }

    // MARK: - The log, read

    /// Reads the excerpt once, and keeps it.
    ///
    /// What is sent is what this produced, not a second read taken at the moment Send is pressed.
    /// The View link is a promise about the bytes, and a re-read a minute later could contain a
    /// line that arrived after somebody read it and decided it was fine to send.
    private func readLogs() {
        logsRead?.cancel()

        // The names this Mac uses for its own work, which BloomCore cannot know and this view can:
        // they are the rows in the sidebar. See `AppLogExcerpt.Redaction`.
        let redaction = AppLogExcerpt.Redaction.of(
            projects: app.repos.map(\.name),
            workspaces: app.workspaces.map(\.name),
            branches: app.workspaces.map(\.branch),
            user: NSUserName(),
            host: ProcessInfo.processInfo.hostName
        )

        logsRead = Task {
            // Off the main actor: reading the log store decodes every entry it walks past.
            let excerpt = await Task.detached(priority: .userInitiated) {
                AppLogExcerpt.excerpt(AppLogReader.recent(), redaction: redaction)
            }.value
            guard !Task.isCancelled else { return }
            presenter.logs = excerpt
        }
    }

    /// The View link. Reads the log first if the box has not been ticked, so the link answers the
    /// question it is there to answer whether or not somebody has committed to sending anything.
    private func showLogs() {
        readLogs()
        Task {
            await logsRead?.value
            isShowingLogs = true
        }
    }

    // MARK: - Pictures, attached

    /// A drop or a paste on the text. Returns true so the text system does not also write the
    /// file's path into the message as words.
    private func attach(sources: [AttachmentSource], replacing range: NSRange) -> Bool {
        guard !sources.isEmpty else { return false }
        add(sources)
        return true
    }

    private func pickImages() {
        Task {
            let panel = NSOpenPanel()
            panel.canChooseFiles = true
            panel.canChooseDirectories = false
            panel.allowsMultipleSelection = true
            panel.allowedContentTypes = [.image]
            panel.prompt = "Attach"

            // A sheet rather than `runModal()`, which stops the run loop and with it every
            // transcript streaming in the window behind this one. See `PanelPresentation`.
            guard await panel.present() == .OK else { return }
            add(panel.urls.map { .file($0) })
        }
    }

    private func add(_ sources: [AttachmentSource]) {
        let existing = presenter.images
        Task {
            do {
                // Off the main actor: this reads files and can re-encode a picture.
                let read = try await Task.detached(priority: .userInitiated) {
                    try FeedbackImages.read(sources, existing: existing)
                }.value
                presenter.images += read
                attachmentProblem = nil
            } catch {
                attachmentProblem = error.localizedDescription
            }
            isFocused = true
        }
    }

    private func remove(_ image: FeedbackImage) {
        presenter.images.removeAll { $0.id == image.id }
        attachmentProblem = nil
    }

    // MARK: - Sending

    /// The facts gathered when the sheet appeared, or a gather started now because the sheet was
    /// sent from before the first one finished.
    ///
    /// Written out rather than as `await facts?.value ?? …`, because the right hand side of `??`
    /// is an autoclosure and an autoclosure cannot await.
    private func gatheredFacts() async -> Feedback.Environment {
        if let facts { return await facts.value }
        return await FeedbackEnvironment.current(app: app)
    }

    /// Silent until Send has been pressed once, live from then on, so the address is never marked
    /// wrong while it is still being typed for the first time. The policy and the check are
    /// `Feedback.sheetProblems`, where they can be tested; this view only asks.
    private var problems: Feedback.SheetProblems {
        Feedback.sheetProblems(email: presenter.email, afterSendAttempt: hasTriedToSend)
    }

    /// Everything that has to be true before the button does anything. Read by the button and
    /// again by `send`, because a keyboard shortcut reaches the action without going through the
    /// button's disabled state.
    ///
    /// The address is deliberately not in it. A button that goes grey over a field problem cannot
    /// say which field or why; pressing it is what surfaces the sentence that can.
    private var canSend: Bool {
        Feedback.canSend(message: presenter.message) && !phase.isSending
    }

    private func send() {
        guard canSend else { return }

        // Checked on the way out rather than while somebody types, so a half-typed address is
        // never marked wrong. A blocked send turns the warning on, live from here, and puts the
        // keyboard in the field it names.
        let problems = Feedback.sheetProblems(email: presenter.email, afterSendAttempt: true)
        guard problems.isEmpty else {
            hasTriedToSend = true
            problemField = problems.firstField
            return
        }

        phase = .sending

        Task {
            // Whatever the sheet started when it appeared, rather than a second gather: this is
            // the moment the wait for it is paid, and by now there is usually nothing to wait for.
            let environment = await gatheredFacts()
            // And whatever the checkbox started, so a send pressed a second after ticking the box
            // still carries the log rather than an empty string.
            if presenter.includesLogs { await logsRead?.value }

            let report = Feedback.Report(
                message: presenter.message,
                email: presenter.email,
                logs: presenter.includesLogs ? presenter.logs : nil,
                images: presenter.images.map(\.wire),
                token: FeedbackEnvironment.token(),
                environment: environment
            )

            let result = await FeedbackClient.send(report)

            guard result.isSent else {
                phase = .failed(Feedback.failureMessage(result.outcome) ?? "That did not send.")
                return
            }

            phase = .sent
            // Cleared only here, on the one outcome that means the words have arrived somewhere.
            // The address is not part of it: it stays, because it is the same person next time.
            presenter.clearReport()
            // The form is replaced by the thank you rather than closing on a timer. See
            // `FeedbackSentCard` for why it is the same sheet rather than a second one.
            presenter.open(.reportSent)
        }
    }
}

/// One attached picture: what it is called and how big it is, with a way to take it off again.
///
/// A chip rather than a thumbnail. The composer says an attachment with an icon and a name, so
/// this says it the same way, and it costs nothing per keystroke: decoding a two megabyte PNG to
/// draw a forty point square would be paid for on every redraw of a sheet somebody is typing into.
private struct FeedbackImageChip: View {
    var image: FeedbackImage
    var onRemove: @MainActor () -> Void

    var body: some View {
        HStack(spacing: Metrics.spacingSmall) {
            Image(systemName: "photo")
                .font(.system(size: Metrics.glyph - 2))
                .foregroundStyle(Palette.textSecondary)

            Text(image.filename)
                .font(Typo.caption)
                .foregroundStyle(Palette.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)

            Text(ByteCountFormatter.string(fromByteCount: Int64(image.byteCount), countStyle: .file))
                .font(Typo.micro)
                .foregroundStyle(Palette.textTertiary)

            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: Metrics.glyph - 4, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Palette.textTertiary)
            .help("Take this image off")
            .accessibilityLabel("Remove \(image.filename)")
        }
        .padding(.horizontal, Metrics.spacing)
        .padding(.vertical, Metrics.spacingSmall)
        .background(Palette.surfaceSunken, in: RoundedRectangle(cornerRadius: Metrics.cornerSmall))
        .overlay(
            RoundedRectangle(cornerRadius: Metrics.cornerSmall)
                .strokeBorder(Palette.border, lineWidth: Metrics.outline)
        )
        .frame(maxWidth: 260, alignment: .leading)
    }
}
