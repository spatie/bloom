import SwiftUI
import BloomCore

/// The agent asking a question, drawn as the question rather than as a permission prompt.
///
/// `AskUserQuestion` reaches Bloom as a `can_use_tool` control request like any other tool, so
/// before this existed it was drawn by `PermissionAskRowView`: "The agent asked to use
/// AskUserQuestion", one Allow button, and the question and its options nowhere on screen. Allowing
/// sent the input back unedited, with no `answers` in it, and the agent reported that no answer
/// came back. The person had answered a permission prompt, which is not the same act at all.
///
/// So a question gets its own card, and answering it is `PermissionDecision.answer`, which is an
/// allow whose `updatedInput` carries the reply. See `AgentQuestionnaire`.
///
/// **Every question can be answered in words.** The tool's own contract promises the asker that the
/// host will offer an Other row, on the strength of which the asker is told not to write one. Bloom
/// is the host. Without it a question whose options all miss the point could only be denied, and a
/// denial reads to the agent as a refusal rather than as an answer.
struct AgentQuestionCard: View {
    var ask: PermissionAsk
    /// Nil while the question is open. Anything else and the controls are gone: a question answered
    /// twice would write into a pipe nobody is reading.
    var decision: String?
    var onAnswer: (PermissionDecision) -> Void = { _ in }

    /// The chosen option labels, per question. A set even for a single-select question, so one code
    /// path draws both and the difference is only in what a tap does.
    @State private var chosen: [String: Set<String>] = [:]
    /// What was typed into the Other row, per question.
    @State private var other: [String: String] = [:]
    /// Which questions have the Other row showing, per question. Separate from whether anything is
    /// typed in it, so an empty Other row stays open while somebody thinks.
    @State private var isWritingOther: Set<String> = []
    @FocusState private var otherFocus: String?

    /// The questions this card is about. See `AgentQuestionCache`, which is why asking for them
    /// six or eight times in one pass is not six or eight parses.
    private var questions: [AgentQuestion] { AgentQuestionCache.questions(in: ask) }

    private var isOpen: Bool { decision == nil }

    var body: some View {
        VStack(alignment: .leading, spacing: TranscriptLayout.cardInset) {
            header

            ForEach(questions) { question in
                questionBlock(question)
            }

            if isOpen {
                actions
            } else {
                settledLine
            }
        }
        .padding(TranscriptLayout.cardInset)
        .background(
            RoundedRectangle(cornerRadius: Metrics.corner, style: .continuous)
                .fill(isOpen ? Palette.questionWash : Palette.questionWashSettled)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Metrics.corner, style: .continuous)
                .strokeBorder(
                    isOpen ? Palette.questionBorder : Palette.border,
                    lineWidth: Metrics.hairline
                )
        )
        .padding(.vertical, TranscriptLayout.tight)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(isOpen ? "The agent is asking a question" : "Question, answered")
        .task { applyCaptureStates() }
    }

    // MARK: Parts

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: TranscriptLayout.glyphGap) {
            Image(systemName: "questionmark.bubble.fill")
                .font(Typo.caption)
                .imageScale(.small)
                .foregroundStyle(isOpen ? Palette.accent : Palette.textTertiary)
                .accessibilityHidden(true)

            Text(headerTitle)
                .font(Typo.labelEmphasis)
                .foregroundStyle(Palette.textPrimary)

            Spacer(minLength: 0)
        }
    }

    /// Past tense once settled, matching `PermissionAskRowView`: a card that still says "has a
    /// question" over dead controls reads as a card that is waiting.
    private var headerTitle: String {
        if questions.count > 1 {
            return isOpen
                ? "The agent has \(questions.count) questions"
                : "The agent asked \(questions.count) questions"
        }
        return isOpen ? "The agent has a question" : "The agent asked a question"
    }

    private func questionBlock(_ question: AgentQuestion) -> some View {
        VStack(alignment: .leading, spacing: Metrics.spacingWide) {
            VStack(alignment: .leading, spacing: Metrics.spacingSmall) {
                if !question.header.isEmpty {
                    Text(question.header.uppercased())
                        .font(Typo.micro)
                        .tracking(Typo.microTracking)
                        .foregroundStyle(isOpen ? Palette.accent : Palette.textTertiary)
                }

                Text(question.question)
                    .font(Typo.bodyEmphasis)
                    .foregroundStyle(Palette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)

                // An instruction, so it goes when the controls it instructs go.
                if question.multiSelect, isOpen {
                    Text("Choose as many as apply.")
                        .font(Typo.caption)
                        .foregroundStyle(Palette.textTertiary)
                }
            }

            VStack(alignment: .leading, spacing: Metrics.spacingTight) {
                ForEach(question.options) { option in
                    optionRow(question, option)
                }

                otherRow(question)
            }
        }
    }

    private func optionRow(_ question: AgentQuestion, _ option: AgentQuestion.Option) -> some View {
        let isChosen = chosen[question.id]?.contains(option.label) ?? false

        return VStack(alignment: .leading, spacing: Metrics.spacingTight) {
            Button {
                toggle(question, option.label)
            } label: {
                rowLabel(
                    mark: markName(isChosen: isChosen, multiSelect: question.multiSelect),
                    isChosen: isChosen,
                    title: option.label,
                    detail: option.description
                )
            }
            .buttonStyle(
                QuestionOptionStyle(
                    isChosen: isChosen,
                    isOpen: isOpen,
                    forcesHover: forcesHover(question, option)
                )
            )
            .disabled(!isOpen)
            .accessibilityAddTraits(isChosen ? [.isSelected] : [])

            // Shown only for the option it belongs to, and only once that option is the one being
            // considered: a column of mockups all at once is the thing a preview exists to avoid.
            // Outside the button, because a block inside a button's label can be neither selected
            // nor unfolded, and hanging at the option's own text column so it reads as part of it.
            if let preview = option.preview, isChosen {
                DetailCodeBlock(text: preview)
                    .padding(.leading, TranscriptLayout.optionTextIndent)
                    .padding(.trailing, Metrics.spacingWide)
                    .padding(.bottom, Metrics.spacingSmall)
            }
        }
    }

    /// One option as one object: the mark in its own column, the label carrying the weight, and
    /// the description a clear step under it rather than a second line of the same voice.
    private func rowLabel(mark: String, isChosen: Bool, title: String, detail: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: TranscriptLayout.glyphGap) {
            markView(mark, isChosen: isChosen)

            VStack(alignment: .leading, spacing: Metrics.spacingTight) {
                Text(title)
                    .font(Typo.labelEmphasis)
                    .foregroundStyle(isOpen ? Palette.textPrimary : Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                if !detail.isEmpty {
                    Text(detail)
                        .font(Typo.caption)
                        .foregroundStyle(isOpen ? Palette.textSecondary : Palette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// The mark in a fixed column, so the labels line up down the card whatever shape each mark
    /// is, and at reading size rather than glyph size: it is the whole affordance of the row.
    private func markView(_ name: String, isChosen: Bool) -> some View {
        Image(systemName: name)
            .font(Typo.body)
            .foregroundStyle(markColour(isChosen: isChosen))
            .frame(width: TranscriptLayout.glyphWidth)
            .accessibilityHidden(true)
    }

    private func markColour(isChosen: Bool) -> Color {
        if isChosen { return Palette.accent }
        return isOpen ? Palette.textSecondary : Palette.textTertiary
    }

    /// The free text row every question gets. See the head of this file for why.
    @ViewBuilder
    private func otherRow(_ question: AgentQuestion) -> some View {
        if isWritingOther.contains(question.id) {
            HStack(alignment: .firstTextBaseline, spacing: TranscriptLayout.glyphGap) {
                // Drawn chosen: the words being typed are the selection.
                markView(
                    markName(isChosen: true, multiSelect: question.multiSelect),
                    isChosen: true
                )

                TextField(
                    "Say what you would rather do…",
                    text: Binding(
                        get: { other[question.id] ?? "" },
                        set: { other[question.id] = $0 }
                    ),
                    axis: .vertical
                )
                .textFieldStyle(.roundedBorder)
                .font(Typo.label)
                .lineLimit(1...4)
                .focused($otherFocus, equals: question.id)
                .disabled(!isOpen)
                // Focus moves here when the row appears, which it only does by being asked for.
                .task { otherFocus = question.id }
            }
            .padding(.vertical, Metrics.spacing)
            .padding(.horizontal, Metrics.spacingWide)
        } else if isOpen {
            Button {
                isWritingOther.insert(question.id)
                // Answering in words replaces whatever was ticked: the two would otherwise be sent
                // joined together as one string, which says two things at once.
                chosen[question.id] = []
            } label: {
                rowLabel(
                    mark: markName(isChosen: false, multiSelect: question.multiSelect),
                    isChosen: false,
                    title: AgentQuestionnaire.otherLabel,
                    detail: "Answer in your own words."
                )
            }
            .buttonStyle(QuestionOptionStyle(isChosen: false, isOpen: true))
        }
    }

    private var actions: some View {
        HStack(spacing: TranscriptLayout.tight) {
            Button("Send answer") { send() }
                .buttonStyle(.borderedProminent)
                // Bloom's fill rather than the system accent, as every other prominent
                // button in the app carries. See `EmptyStateView`.
                .tint(Palette.accentFill)
                .keyboardShortcut(.defaultAction)
                .disabled(!isComplete)

            Spacer(minLength: 0)

            // Not "Deny". Nothing is being refused: the agent asked and is being told to decide for
            // itself, which is a different sentence and produces a different answer.
            Button("Let the agent decide") {
                onAnswer(.deny(message: Self.skipMessage, endsTurn: false))
            }
            .buttonStyle(.bordered)
        }
        .controlSize(.small)
    }

    /// What a settled card says instead of its buttons. The tick is the one accent left on it:
    /// enough to say the question was really answered, without the card still asking for the eye.
    private var settledLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: TranscriptLayout.glyphGap) {
            if decision == "answered" {
                Image(systemName: "checkmark.circle.fill")
                    .font(Typo.caption)
                    .foregroundStyle(Palette.accent)
                    .accessibilityHidden(true)
            }

            Text(settledText)
                .font(Typo.caption)
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var settledText: String {
        let decision = decision ?? ""
        // The three ways a question dies unanswered, in the words the permission card uses for
        // them: a card that says "Answered." over a question nobody answered is a small lie.
        let unanswered = PermissionAskOutcome.summary(decision)
        if !unanswered.isEmpty { return unanswered }
        return decision == "answered" ? "Answered." : "The agent was asked to decide for itself."
    }

    // MARK: Answering

    /// Written to the model rather than to a person: it is handed straight back as the tool result,
    /// and it has to leave the agent able to carry on rather than stopped waiting for a person.
    private static let skipMessage =
        "No answer was given. Choose whichever option you judge best, say which you chose and why, "
            + "and carry on without asking again."

    private var isComplete: Bool {
        AgentQuestionnaire.isComplete(questions, answers: answers)
    }

    /// What each question would be answered with, as the protocol files it: one string per
    /// question, keyed by the question's own text.
    private var answers: [String: String] {
        var answers: [String: String] = [:]

        for question in questions {
            let typed = (other[question.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

            if !typed.isEmpty {
                answers[question.id] = typed
                continue
            }

            // In the order the asker offered them, not the order they were tapped: the asker put
            // its recommendation first and an answer that reorders them says something it did not.
            let picked = question.options.map(\.label).filter { chosen[question.id]?.contains($0) ?? false }

            if !picked.isEmpty {
                answers[question.id] = AgentQuestionnaire.joined(picked)
            }
        }

        return answers
    }

    private func send() {
        guard isComplete else { return }
        onAnswer(.answer(input: AgentQuestionnaire.answered(ask.input, answers: answers)))
    }

    private func toggle(_ question: AgentQuestion, _ label: String) {
        // Typing and ticking are two answers to one question, so choosing an option puts the words
        // away rather than sending both.
        isWritingOther.remove(question.id)
        other[question.id] = ""

        var set = chosen[question.id] ?? []

        if question.multiSelect {
            if set.contains(label) { set.remove(label) } else { set.insert(label) }
        } else {
            set = set.contains(label) ? [] : [label]
        }

        chosen[question.id] = set
    }

    /// A circle for one of many, a square for any of many. The shapes AppKit uses for a radio
    /// button and a checkbox, which is what these are.
    private func markName(isChosen: Bool, multiSelect: Bool) -> String {
        if multiSelect {
            return isChosen ? "checkmark.square.fill" : "square"
        }
        return isChosen ? "largecircle.fill.circle" : "circle"
    }

    // MARK: Capture states

    /// Capture affordance: `--question-states` ticks the first option of every question and holds
    /// a hover on the second, so the chosen and hovered plates can be photographed. The pointer
    /// cannot be scripted across the user's own screen and `@State` cannot be seeded from the
    /// database, so without this the two states that make the rows read as controls could only be
    /// judged by asking a human to hover. Debug builds only, the same argument as `--running`.
    #if DEBUG
    private static let forcesStates = CommandLine.arguments.contains("--question-states")
    #endif

    private func applyCaptureStates() {
        #if DEBUG
        guard Self.forcesStates, isOpen else { return }
        for question in questions {
            if let first = question.options.first {
                chosen[question.id] = [first.label]
            }
        }
        #endif
    }

    private func forcesHover(_ question: AgentQuestion, _ option: AgentQuestion.Option) -> Bool {
        #if DEBUG
        return Self.forcesStates && isOpen && question.options.firstIndex(of: option) == 1
        #else
        return false
        #endif
    }
}

// MARK: - Row chrome

/// The plate under an option row: hover, press, chosen, in the window's own vocabulary.
///
/// Selection is `Palette.selected`, the quiet grey every unfocused list in the window uses, with
/// the accent kept for the mark: an accent-washed row here sat inches from the accent-washed card
/// behind it and the two tints fought. A press paints the same plate the choice will leave, so
/// the button announces its result rather than a darker version of itself.
private struct QuestionOptionStyle: ButtonStyle {
    var isChosen: Bool
    var isOpen: Bool
    var forcesHover: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        Plate(
            configuration: configuration,
            isChosen: isChosen,
            isOpen: isOpen,
            forcesHover: forcesHover
        )
    }

    /// A view of its own rather than the style drawing directly, because hover is per row state
    /// and a `ButtonStyle` has nowhere to keep any.
    private struct Plate: View {
        let configuration: Configuration
        var isChosen: Bool
        var isOpen: Bool

        @State private var isHovered: Bool
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        init(configuration: Configuration, isChosen: Bool, isOpen: Bool, forcesHover: Bool) {
            self.configuration = configuration
            self.isChosen = isChosen
            self.isOpen = isOpen
            _isHovered = State(initialValue: forcesHover)
        }

        var body: some View {
            configuration.label
                .padding(.vertical, Metrics.spacing)
                .padding(.horizontal, Metrics.spacingWide)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: Metrics.corner, style: .continuous)
                        .fill(fill)
                )
                .contentShape(RoundedRectangle(cornerRadius: Metrics.corner, style: .continuous))
                .animation(reduceMotion ? nil : Motion.hover, value: isHovered)
                .onHover { isHovered = $0 }
        }

        private var fill: Color {
            if isChosen || (isOpen && configuration.isPressed) { return Palette.selected }
            if isOpen, isHovered { return Palette.hover }
            return .clear
        }
    }
}

/// The questions inside an ask, parsed once per request rather than once per read.
///
/// `AgentQuestionnaire.questions(in:)` walks the tool input and builds a question and its options
/// out of it, and the card asks for the answer from `body`, from its header, from the completeness
/// check, from the answers it would send and from the debug capture: six to eight reads in a pass.
/// The card also holds three pieces of `@State`, so typing a word into an Other row re-runs all of
/// them per keystroke.
///
/// Keyed on the request id and the call it is about, which is what the CLI uses to identify one
/// control request and what the answer is posted back against. The input behind that pair is what
/// the agent sent once; nothing rewrites it. Both halves, because a request id is only promised to
/// be unique within the session that issued it and a window holds several sessions at once, where a
/// `tool_use` id is minted per call.
@MainActor
private enum AgentQuestionCache {
    /// A transcript holds few of these, and a card that has scrolled away can afford to parse
    /// again if it comes back after a hundred others.
    private static let values: NSCache<NSString, AgentQuestionsBox> = {
        let cache = NSCache<NSString, AgentQuestionsBox>()
        cache.countLimit = 64
        return cache
    }()

    static func questions(in ask: PermissionAsk) -> [AgentQuestion] {
        // A separator no id can hold, so two pairs cannot be spelled the same way round.
        let key = "\(ask.requestID)\u{1}\(ask.toolUseID)" as NSString
        if let cached = values.object(forKey: key) { return cached.value }

        let value = AgentQuestionnaire.questions(in: ask.input)
        values.setObject(AgentQuestionsBox(value), forKey: key)
        return value
    }
}

/// `NSCache` cannot hold a value type. See `TranscriptEventCache`, which keeps its boxes beside it
/// for the same reason.
private final class AgentQuestionsBox {
    let value: [AgentQuestion]

    init(_ value: [AgentQuestion]) { self.value = value }
}
