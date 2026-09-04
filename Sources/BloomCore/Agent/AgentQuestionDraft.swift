import Foundation

/// The half-finished answer to an `AskUserQuestion` card: what has been ticked, what has been
/// typed, and which questions have their free text row open.
///
/// **This is a value held outside the card rather than `@State` inside it, and that is the whole
/// point of the type.** The transcript is an `NSTableView` (`TranscriptTable`), and every row is
/// drawn into a cell fetched under one shared identifier, so a row that leaves the visible rect
/// hands its cell to another row and `TranscriptTableCell.apply(entry:environment:generation:)`
/// replaces the hosting view's root view whenever the content key or the generation has moved.
/// Replacing a root view throws away the `@State` of what was in it. Three routine things do that
/// to an open question card while a session is streaming: the card scrolling out of the visible
/// rect and back, which happens constantly while rows arrive at the live end; the table being
/// rebuilt for a replaced session; and the row environment moving. Somebody ticking options and
/// typing into the Other row on a four question card watched his ticks and his words wiped, over
/// and over, while the agent carried on talking.
///
/// So the draft lives in a store keyed on the ask, and the card reads and writes it. It is a value
/// type with the rules on it rather than a bag of dictionaries, because the rules are the part
/// worth testing and nothing can test a decision taken inside a view. `TranscriptListView` already
/// keeps its disclosure state outside its rows for exactly this reason; this card was the outlier.
public struct AgentQuestionDraft: Sendable, Hashable {
    /// The chosen option labels, per question. A set even for a single-select question, so one code
    /// path draws both and the difference is only in what a tap does.
    public var chosen: [String: Set<String>] = [:]
    /// What was typed into the Other row, per question.
    public var other: [String: String] = [:]
    /// Which questions have their Other row showing. Separate from whether anything is typed in it,
    /// so an empty Other row stays open while somebody thinks.
    public var isWritingOther: Set<String> = []

    public init() {}

    /// Ticking an option.
    ///
    /// Typing and ticking are two answers to one question, so choosing an option puts the words
    /// away rather than sending both. A single-select question replaces what was ticked, and
    /// ticking the same option again clears it; a multi-select question accumulates.
    public mutating func toggle(_ label: String, on question: AgentQuestion) {
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

    /// Opening the free text row on a question.
    ///
    /// Answering in words replaces whatever was ticked: the two would otherwise be sent joined
    /// together as one string, which says two things at once.
    public mutating func writeOther(on question: AgentQuestion) {
        isWritingOther.insert(question.id)
        chosen[question.id] = []
    }

    /// What each question would be answered with, as the protocol files it: one string per
    /// question, keyed by the question's own text.
    ///
    /// Typed words win over ticks, because a question that has both was ticked before the row was
    /// opened and the words are the later answer.
    public func answers(to questions: [AgentQuestion]) -> [String: String] {
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

    /// Whether every question has something to send, which is what the submit button is keyed on.
    public func isComplete(_ questions: [AgentQuestion]) -> Bool {
        AgentQuestionnaire.isComplete(questions, answers: answers(to: questions))
    }
}
