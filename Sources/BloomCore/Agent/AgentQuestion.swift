import Foundation

/// A question the agent asked, and the options it offered.
///
/// `AskUserQuestion` arrives as a permission ask like any other tool call, and that is the whole
/// reason this type exists. Drawn by the generic permission card it became "The agent asked to use
/// AskUserQuestion" over a single Allow button: the question was in the input, the options were in
/// the input, and neither was on screen. Allowing it then sent the input back unchanged, with no
/// `answers` key in it, so the CLI got a call with no answer in it and said so. Somebody looking at
/// that saw a permission prompt, granted it, and got told nothing came back.
///
/// So the ask is decoded into questions and drawn as questions, and answering one is an allow whose
/// `updatedInput` carries the reply. See `AgentQuestionnaire.answered(_:answers:)`.
public struct AgentQuestion: Sendable, Hashable, Identifiable {
    /// One of the offered answers.
    public struct Option: Sendable, Hashable, Identifiable {
        public var label: String
        public var description: String
        /// The mockup, snippet or diagram this option stands for, when the asker attached one.
        /// Only single-select questions carry these.
        public var preview: String?

        public var id: String { label }

        public init(label: String, description: String = "", preview: String? = nil) {
            self.label = label
            self.description = description
            self.preview = preview
        }

        static func decode(_ json: JSONValue) -> Option? {
            guard let label = json["label"]?.stringValue, !label.isEmpty else { return nil }
            let preview = json["preview"]?.stringValue
            return Option(
                label: label,
                description: json["description"]?.stringValue ?? "",
                preview: (preview?.isEmpty ?? true) ? nil : preview
            )
        }
    }

    /// The question itself, which is also the key an answer is filed under. The asker's words, and
    /// the only handle the protocol gives an answer, so it is the identity too.
    public var question: String
    /// The short chip the asker wanted beside it. Often empty.
    public var header: String
    public var multiSelect: Bool
    public var options: [Option]

    public var id: String { question }

    public init(question: String, header: String = "", multiSelect: Bool = false, options: [Option] = []) {
        self.question = question
        self.header = header
        self.multiSelect = multiSelect
        self.options = options
    }

    static func decode(_ json: JSONValue) -> AgentQuestion? {
        guard let question = json["question"]?.stringValue, !question.isEmpty else { return nil }

        return AgentQuestion(
            question: question,
            header: json["header"]?.stringValue ?? "",
            multiSelect: json["multiSelect"]?.boolValue ?? false,
            options: (json["options"]?.arrayValue ?? []).compactMap(Option.decode)
        )
    }
}

/// Reading an `AskUserQuestion` call, and writing the reply back into it.
public enum AgentQuestionnaire {
    /// The tool name, spelled once so the decoder and the view cannot disagree about it.
    public static let toolName = "AskUserQuestion"

    /// What "Other" is called on every question, because the tool always allows one.
    ///
    /// The asker is told not to include an Other option of its own, on the promise that the host
    /// provides one. Bloom is the host, so Bloom provides it: without it a question whose options
    /// all miss the point can only be denied, which reads to the agent as a refusal rather than as
    /// an answer.
    public static let otherLabel = "Other"

    /// Whether this ask is a question rather than a request to do something.
    public static func isQuestion(toolName: String) -> Bool {
        toolName == Self.toolName
    }

    /// The questions in an `AskUserQuestion` input.
    ///
    /// A question with no options is kept rather than dropped: it is still a question, and the free
    /// text row can answer it. A question with no text at all is dropped, because there is nothing
    /// to file an answer under.
    public static func questions(in input: JSONValue) -> [AgentQuestion] {
        (input["questions"]?.arrayValue ?? []).compactMap(AgentQuestion.decode)
    }

    /// The same input with the answers written into it, ready to be the `updatedInput` of an allow.
    ///
    /// Everything else is left exactly as it arrived. Only `answers` is added, and only for
    /// questions that were actually answered: a key holding an empty string is a question answered
    /// with nothing, which is worse than a question left out.
    public static func answered(_ input: JSONValue, answers: [String: String]) -> JSONValue {
        guard case .object(var object) = input else { return input }

        let filled = answers.filter { !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

        guard !filled.isEmpty else { return input }

        object["answers"] = .object(filled.mapValues { JSONValue.string($0) })

        return .object(object)
    }

    /// How several selections on one multi-select question are written as the single string the
    /// protocol files under that question.
    public static func joined(_ labels: [String]) -> String {
        labels.joined(separator: ", ")
    }

    /// Whether every question has something to send. The submit button is keyed on this: an answer
    /// with nothing in it would unblock the agent with no more information than a deny.
    public static func isComplete(_ questions: [AgentQuestion], answers: [String: String]) -> Bool {
        guard !questions.isEmpty else { return false }

        return questions.allSatisfy { question in
            let answer = answers[question.question] ?? ""
            return !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }
}
