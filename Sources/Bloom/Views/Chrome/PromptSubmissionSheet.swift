import SwiftUI
import BloomCore

/// Help ▸ Submit a Prompt. Say what Bloom should do next, in the words you would say it to an
/// agent, because that is what will be done with it.
///
/// The same box as the feedback sheet and for the same reason, minus the attachments: a prompt is
/// words. What it has instead is a name, which is a credit line rather than an identity, and which
/// the endpoint validates narrowly enough that an email address is refused. So the field says that
/// before anybody types one, and a name that would be refused stops the send here with a sentence
/// rather than there with a 422.
///
/// The draft lives on `FeedbackPresenter`, so nothing typed here is lost to Escape or to a server
/// that is down. The name outlives even a successful submission: it is the same person next time.
struct PromptSubmissionSheet: View {
    @Environment(AppModel.self) private var app

    @Bindable private var presenter = FeedbackPresenter.shared

    @State private var caret = 0
    @State private var isFocused = false
    @State private var contentHeight = ComposerTextEditor.lineHeight
    @State private var phase: FeedbackPhase = .idle
    /// The handle the far end filed this under, once it has. Nil until then, and again on the next
    /// attempt. See `Feedback.reference(in:)`.
    @State private var reference: String?
    @State private var facts: Task<Feedback.Environment, Never>?

    private static let minimumEditorLines: CGFloat = 6
    private static let maximumEditorLines: CGFloat = 14
    private static let width: CGFloat = 620

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.gutter) {
            FeedbackHeader(title: Feedback.Copy.promptTitle, blurb: Feedback.Copy.promptBlurb)

            editor

            nameField

            FeedbackEnvironmentNote()

            footer
        }
        .padding(Metrics.pane)
        .frame(width: Self.width)
        .background(Palette.surface)
        .task {
            facts = Task { await FeedbackEnvironment.current(app: app) }
            isFocused = true
        }
        .onDisappear {
            facts?.cancel()
            phase = .idle
        }
    }

    // MARK: - The box

    private var editor: some View {
        ComposerEditor(
            text: $presenter.prompt,
            caret: $caret,
            isFocused: $isFocused,
            height: editorHeight,
            onContentHeightChange: { contentHeight = $0 },
            onKey: handle(key:),
            // A prompt is words, so a file dropped here is taken and dropped on the floor. It is
            // deliberately not refused either, because refusing hands it back to the text system,
            // which writes the file's own path into the prompt: the one field on this sheet that
            // goes out as free text is the last place a path should be able to arrive by accident.
            onAttach: { _, _ in true },
            placeholder: Feedback.Copy.promptPlaceholder
        )
        .composerBox(isFocused: $isFocused)
    }

    private var editorHeight: CGFloat {
        let line = ComposerTextEditor.lineHeight
        return min(max(contentHeight, line * Self.minimumEditorLines), line * Self.maximumEditorLines)
    }

    // MARK: - The credit line

    private var nameField: some View {
        VStack(alignment: .leading, spacing: Metrics.spacingSmall) {
            Text(Feedback.Copy.promptName)
                .font(Typo.caption)
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            TextField(Feedback.Copy.promptNamePlaceholder, text: $presenter.name)
                .textFieldStyle(.roundedBorder)
                .font(Typo.body)

            if !isNameAcceptable {
                Label(Feedback.nameProblem, systemImage: "exclamationmark.triangle.fill")
                    .font(Typo.micro)
                    .foregroundStyle(Palette.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Checked here rather than only on the way out, because the alternative is a submission that
    /// comes back 422 for a field nobody had to fill in at all.
    private var isNameAcceptable: Bool {
        Feedback.isAcceptableName(presenter.name)
    }

    // MARK: - The buttons

    private var footer: some View {
        HStack(spacing: Metrics.gutter) {
            if let remaining = Feedback.remainingMessage(
                count: presenter.prompt.count, limit: Feedback.maxPromptCharacters
            ) {
                Text(remaining)
                    .font(Typo.micro)
                    .foregroundStyle(
                        presenter.prompt.count > Feedback.maxPromptCharacters
                            ? Palette.warning
                            : Palette.textTertiary
                    )
                    .monospacedDigit()
            }

            Spacer(minLength: Metrics.gutter)

            FeedbackStatus(phase: phase, sentMessage: Feedback.Copy.sent(Feedback.Copy.promptSent, reference: reference))

            Button("Cancel", role: .cancel) { presenter.close() }
                .keyboardShortcut(.cancelAction)
                .disabled(phase.isSending)

            FeedbackSendButton(
                title: Feedback.Copy.promptSend,
                isEnabled: Feedback.canSend(message: presenter.prompt) && isNameAcceptable && !phase.isSending,
                action: send
            )
        }
    }

    // MARK: - Keys

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

    private func send() {
        guard !phase.isSending,
              Feedback.canSend(message: presenter.prompt),
              isNameAcceptable
        else { return }

        reference = nil
        phase = .sending

        Task {
            let environment = await gatheredFacts()

            let submission = Feedback.PromptSubmission(
                prompt: presenter.prompt,
                name: presenter.name,
                token: FeedbackEnvironment.token(),
                environment: environment
            )

            let result = await FeedbackClient.send(submission)

            guard result.isSent else {
                phase = .failed(Feedback.failureMessage(result.outcome) ?? "That did not send.")
                return
            }

            reference = result.reference
            phase = .sent
            // The prompt goes; the name stays, because it is the same person next time.
            presenter.clearPrompt()
            // Longer when there is a reference on the line, because it is only worth putting
            // there if somebody has time to read it.
            try? await Task.sleep(for: reference == nil ? feedbackSuccessPause : feedbackReferencePause)
            presenter.close()
        }
    }
}
