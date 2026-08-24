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
    @State private var facts: Task<Feedback.Environment, Never>?
    /// Whether Submit has been pressed on this opening of the sheet. All this view owns of the
    /// validation story; what it means is `Feedback.sheetProblems`' business.
    @State private var hasTriedToSend = false
    /// Where focus lands when a send is blocked: the first field the block named.
    @FocusState private var problemField: Feedback.SheetField?

    private static let minimumEditorLines: CGFloat = 6
    private static let maximumEditorLines: CGFloat = 14
    private static let width: CGFloat = 620

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.gutter) {
            FeedbackHeader(title: Feedback.Copy.promptTitle, blurb: Feedback.Copy.promptBlurb)

            editor

            nameField

            FeedbackEmailField(
                label: Feedback.Copy.promptEmail,
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
            isFocused = true
        }
        .onDisappear {
            facts?.cancel()
            phase = .idle
            // The next opening starts clean: a warning held over from last week's attempt would
            // be about text nobody can see any more.
            hasTriedToSend = false
        }
        .task {
            // A capture run cannot press Submit, so the flag stands in for the press that makes
            // the warnings visible. See `FeedbackPresenter.presentIfRequested`.
            #if DEBUG
            if CommandLine.arguments.contains("--prompt-problems") { hasTriedToSend = true }
            #endif
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
                .focused($problemField, equals: .name)

            FeedbackFieldProblem(message: Feedback.nameProblem, isShown: problems.name != nil)
        }
    }

    /// Silent until Submit has been pressed once, live from then on, so a field is never marked
    /// wrong while it is still being typed for the first time. The policy and the checks are
    /// `Feedback.sheetProblems`, where they can be tested; this view only asks.
    private var problems: Feedback.SheetProblems {
        Feedback.sheetProblems(
            name: presenter.name, email: presenter.email, afterSendAttempt: hasTriedToSend
        )
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

            FeedbackStatus(phase: phase)

            Button("Cancel", role: .cancel) { presenter.close() }
                .keyboardShortcut(.cancelAction)
                .disabled(phase.isSending)

            FeedbackSendButton(
                title: Feedback.Copy.promptSend,
                isEnabled: canSend,
                isSending: phase.isSending,
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

    /// Everything that has to be true before the button does anything. Read by the button and
    /// again by `send`, because a keyboard shortcut reaches the action without going through the
    /// button's disabled state.
    ///
    /// The name and the address are deliberately not in it. A button that goes grey over a field
    /// problem cannot say which field or why; pressing it is what surfaces the sentence that can.
    private var canSend: Bool {
        Feedback.canSend(message: presenter.prompt) && !phase.isSending
    }

    private func send() {
        guard canSend else { return }

        // Checked on the way out rather than while somebody types, so a half-typed address is
        // never marked wrong. A blocked send turns the warnings on, live from here, and puts the
        // keyboard in the first field that needs it.
        let problems = Feedback.sheetProblems(
            name: presenter.name, email: presenter.email, afterSendAttempt: true
        )
        guard problems.isEmpty else {
            hasTriedToSend = true
            problemField = problems.firstField
            return
        }

        phase = .sending

        Task {
            let environment = await gatheredFacts()

            let submission = Feedback.PromptSubmission(
                prompt: presenter.prompt,
                name: presenter.name,
                email: presenter.email,
                token: FeedbackEnvironment.token(),
                environment: environment
            )

            let result = await FeedbackClient.send(submission)

            guard result.isSent else {
                phase = .failed(Feedback.failureMessage(result.outcome) ?? "That did not send.")
                return
            }

            phase = .sent
            // The prompt goes; the name and the address stay, because it is the same person next
            // time and typing either again is a silly thing to ask.
            presenter.clearPrompt()
            // The form is replaced by the thank you rather than closing on a timer. See
            // `FeedbackSentCard` for why it is the same sheet rather than a second one.
            presenter.open(.promptSent)
        }
    }
}
