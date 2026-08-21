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

    private var questions: [AgentQuestion] { AgentQuestionnaire.questions(in: ask.input) }

    private var isOpen: Bool { decision == nil }

    var body: some View {
        VStack(alignment: .leading, spacing: TranscriptLayout.inset) {
            header

            ForEach(questions) { question in
                questionBlock(question)
            }

            if isOpen {
                actions
            } else {
                answeredLine
            }
        }
        .padding(TranscriptLayout.inset)
        .background(
            RoundedRectangle(cornerRadius: Metrics.corner, style: .continuous)
                .fill(Palette.accent.opacity(isOpen ? 0.06 : 0.03))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Metrics.corner, style: .continuous)
                .strokeBorder(
                    isOpen ? Palette.accent.opacity(0.4) : Palette.border,
                    lineWidth: Metrics.hairline
                )
        )
        .padding(.vertical, TranscriptLayout.tight)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(isOpen ? "The agent is asking a question" : "Question, answered")
    }

    // MARK: Parts

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: TranscriptLayout.glyphGap) {
            Image(systemName: "questionmark.bubble.fill")
                .font(Typo.caption)
                .imageScale(.small)
                .foregroundStyle(isOpen ? Palette.accent : Palette.textTertiary)
                .accessibilityHidden(true)

            Text(questions.count > 1 ? "The agent has \(questions.count) questions" : "The agent has a question")
                .font(Typo.labelEmphasis)
                .foregroundStyle(Palette.textPrimary)

            Spacer(minLength: 0)
        }
    }

    private func questionBlock(_ question: AgentQuestion) -> some View {
        VStack(alignment: .leading, spacing: TranscriptLayout.tight) {
            if !question.header.isEmpty {
                Text(question.header.uppercased())
                    .font(Typo.micro)
                    .tracking(0.6)
                    .foregroundStyle(Palette.textTertiary)
            }

            Text(question.question)
                .font(Typo.bodyEmphasis)
                .foregroundStyle(Palette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)

            if question.multiSelect {
                Text("Choose as many as apply.")
                    .font(Typo.micro)
                    .foregroundStyle(Palette.textTertiary)
            }

            VStack(alignment: .leading, spacing: Metrics.spacingSmall) {
                ForEach(question.options) { option in
                    optionRow(question, option)
                }

                otherRow(question)
            }
        }
    }

    private func optionRow(_ question: AgentQuestion, _ option: AgentQuestion.Option) -> some View {
        let isChosen = chosen[question.id]?.contains(option.label) ?? false

        return Button {
            toggle(question, option.label)
        } label: {
            VStack(alignment: .leading, spacing: Metrics.spacingSmall) {
                HStack(alignment: .firstTextBaseline, spacing: TranscriptLayout.glyphGap) {
                    Image(systemName: mark(isChosen: isChosen, multiSelect: question.multiSelect))
                        .font(Typo.label)
                        .imageScale(.medium)
                        .foregroundStyle(isChosen ? Palette.accent : Palette.textTertiary)
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(option.label)
                            .font(Typo.label)
                            .foregroundStyle(Palette.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)

                        if !option.description.isEmpty {
                            Text(option.description)
                                .font(Typo.caption)
                                .foregroundStyle(Palette.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    Spacer(minLength: 0)
                }

                // Shown only for the option it belongs to, and only once that option is the one
                // being considered. A column of mockups all at once is the thing a preview exists
                // to avoid.
                if let preview = option.preview, isChosen {
                    Text(preview)
                        .font(Typo.codeSmall)
                        .foregroundStyle(Palette.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(TranscriptLayout.glyphGap)
                        .background(
                            RoundedRectangle(cornerRadius: Metrics.cornerSmall, style: .continuous)
                                .fill(Palette.surfaceSunken)
                        )
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, Metrics.spacingSmall)
            .padding(.horizontal, TranscriptLayout.glyphGap)
            .background(
                RoundedRectangle(cornerRadius: Metrics.cornerSmall, style: .continuous)
                    .fill(isChosen ? Palette.accent.opacity(0.1) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isOpen)
        .accessibilityAddTraits(isChosen ? [.isSelected] : [])
    }

    /// The free text row every question gets. See the head of this file for why.
    @ViewBuilder
    private func otherRow(_ question: AgentQuestion) -> some View {
        if isWritingOther.contains(question.id) {
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
            .disabled(!isOpen)
        } else if isOpen {
            Button {
                isWritingOther.insert(question.id)
                // Answering in words replaces whatever was ticked: the two would otherwise be sent
                // joined together as one string, which says two things at once.
                chosen[question.id] = []
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: TranscriptLayout.glyphGap) {
                    Image(systemName: mark(isChosen: false, multiSelect: question.multiSelect))
                        .font(Typo.label)
                        .imageScale(.medium)
                        .foregroundStyle(Palette.textTertiary)
                        .accessibilityHidden(true)

                    Text(AgentQuestionnaire.otherLabel)
                        .font(Typo.label)
                        .foregroundStyle(Palette.textSecondary)

                    Spacer(minLength: 0)
                }
                .padding(.vertical, Metrics.spacingSmall)
                .padding(.horizontal, TranscriptLayout.glyphGap)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private var actions: some View {
        HStack(spacing: TranscriptLayout.tight) {
            Button("Send answer") { send() }
                .buttonStyle(.borderedProminent)
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

    private var answeredLine: some View {
        Text(decision == "answered" ? "Answered." : "The agent was asked to decide for itself.")
            .font(Typo.caption)
            .foregroundStyle(Palette.textTertiary)
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
    private func mark(isChosen: Bool, multiSelect: Bool) -> String {
        if multiSelect {
            return isChosen ? "checkmark.square.fill" : "square"
        }
        return isChosen ? "largecircle.fill.circle" : "circle"
    }
}
