import Foundation
import Testing
@testable import BloomCore

/// The bug this file is about: `AskUserQuestion` arrives as a `can_use_tool` control request, so it
/// was drawn as a permission prompt. Allowing it sent the input back unedited, with no `answers` in
/// it, and the agent reported that no answer came back. Somebody had answered a permission prompt,
/// which is not the same act as answering a question.
@Suite("Agent questions")
struct AgentQuestionTests {
    private func input(_ json: String) -> JSONValue {
        JSONValue.parse(Data(json.utf8)) ?? .object([:])
    }

    private var oneQuestion: JSONValue {
        input(#"""
        {
          "questions": [
            {
              "question": "Which database should this use?",
              "header": "Storage",
              "multiSelect": false,
              "options": [
                {"label": "SQLite", "description": "One file, no server."},
                {"label": "Postgres", "description": "A server, and a schema."}
              ]
            }
          ]
        }
        """#)
    }

    // MARK: Reading the question

    @Test("the question, its chip and its options are all read")
    func decoding() throws {
        let questions = AgentQuestionnaire.questions(in: oneQuestion)

        let question = try #require(questions.first)
        #expect(questions.count == 1)
        #expect(question.question == "Which database should this use?")
        #expect(question.header == "Storage")
        #expect(question.multiSelect == false)
        #expect(question.options.map(\.label) == ["SQLite", "Postgres"])
        #expect(question.options.first?.description == "One file, no server.")
    }

    @Test("a preview is carried when the asker attached one, and is nil rather than empty when not")
    func previews() throws {
        let json = input(#"""
        {"questions": [{"question": "Which layout?", "options": [
          {"label": "Rail", "description": "", "preview": "| ver | entry |"},
          {"label": "Stacked", "description": "", "preview": ""}
        ]}]}
        """#)

        let options = try #require(AgentQuestionnaire.questions(in: json).first?.options)

        #expect(options[0].preview == "| ver | entry |")
        #expect(options[1].preview == nil)
    }

    /// The free text row can still answer it, so it is a question rather than nothing.
    @Test("a question with no options is kept")
    func optionlessQuestionSurvives() {
        let json = input(#"{"questions": [{"question": "What should I call it?"}]}"#)

        #expect(AgentQuestionnaire.questions(in: json).count == 1)
    }

    @Test("a question with no text is dropped, because an answer has nothing to be filed under")
    func namelessQuestionIsDropped() {
        let json = input(#"{"questions": [{"header": "Storage", "options": [{"label": "SQLite"}]}]}"#)

        #expect(AgentQuestionnaire.questions(in: json).isEmpty)
    }

    @Test("an input that is not a questionnaire at all reads as no questions rather than throwing")
    func nonsenseIsEmpty() {
        #expect(AgentQuestionnaire.questions(in: .object([:])).isEmpty)
        #expect(AgentQuestionnaire.questions(in: .string("hello")).isEmpty)
    }

    // MARK: Writing the answer

    @Test("the answer is added under the question's own text, and nothing else is touched")
    func answering() throws {
        let answered = AgentQuestionnaire.answered(
            oneQuestion, answers: ["Which database should this use?": "SQLite"]
        )

        #expect(answered["answers"]?["Which database should this use?"]?.stringValue == "SQLite")
        // The questions travel back exactly as they arrived.
        #expect(answered["questions"]?.arrayValue?.count == 1)
        #expect(
            answered["questions"]?[0]?["question"]?.stringValue == "Which database should this use?"
        )
    }

    @Test("several selections on one question go as one string, in the order they were offered")
    func joining() {
        #expect(AgentQuestionnaire.joined(["Bugs", "Performance"]) == "Bugs, Performance")
    }

    /// A key holding an empty string is a question answered with nothing, which is worse than a
    /// question left out: the agent would read it as an answer.
    @Test("an empty answer is left out rather than sent as an empty string")
    func blankAnswersAreDropped() {
        let answered = AgentQuestionnaire.answered(
            oneQuestion, answers: ["Which database should this use?": "   "]
        )

        #expect(answered["answers"] == nil)
    }

    @Test("with nothing answered at all the input goes back exactly as it came")
    func nothingAnsweredChangesNothing() {
        #expect(AgentQuestionnaire.answered(oneQuestion, answers: [:]) == oneQuestion)
    }

    @Test("every question has to be answered before the reply is worth sending")
    func completeness() {
        let two = input(#"""
        {"questions": [
          {"question": "Which database?", "options": [{"label": "SQLite"}]},
          {"question": "Which host?", "options": [{"label": "Forge"}]}
        ]}
        """#)
        let questions = AgentQuestionnaire.questions(in: two)

        #expect(!AgentQuestionnaire.isComplete(questions, answers: [:]))
        #expect(!AgentQuestionnaire.isComplete(questions, answers: ["Which database?": "SQLite"]))
        #expect(!AgentQuestionnaire.isComplete(questions, answers: ["Which database?": " "]))
        #expect(
            AgentQuestionnaire.isComplete(
                questions, answers: ["Which database?": "SQLite", "Which host?": "Forge"]
            )
        )
    }

    @Test("no questions is not complete, because there would be nothing to send")
    func noQuestionsIsNotComplete() {
        #expect(!AgentQuestionnaire.isComplete([], answers: [:]))
    }

    // MARK: What goes on the wire

    @Test("answering encodes as an allow carrying the edited input")
    func wireForm() throws {
        let ask = PermissionAsk(
            requestID: "req-1", toolName: "AskUserQuestion", input: oneQuestion
        )
        let answered = AgentQuestionnaire.answered(
            oneQuestion, answers: ["Which database should this use?": "SQLite"]
        )

        let line = try PermissionAnswer.encode(ask: ask, decision: .answer(input: answered))
        let json = try #require(JSONValue.parse(Data(line.utf8)))
        let response = try #require(json["response"]?["response"])

        #expect(json["response"]?["request_id"]?.stringValue == "req-1")
        #expect(response["behavior"]?.stringValue == "allow")
        #expect(
            response["updatedInput"]?["answers"]?["Which database should this use?"]?.stringValue
                == "SQLite"
        )
        // Nothing is remembered: the next question still has to be answered.
        #expect(response["updatedPermissions"] == nil)
        #expect(response["decision"]?.stringValue == "user_temporary")
    }

    @Test("an answered question is an allow, and files itself as answered rather than as allowed")
    func decisionShape() {
        let decision = PermissionDecision.answer(input: .object([:]))

        #expect(decision.isAllow)
        #expect(decision.storedName == "answered")
        #expect(decision.label == "answered")
    }

    /// A rule would allow the call with its input unedited, which is a call with no answer in it.
    /// The CLI does set `requires_user_interaction` on these; this is the second lock, because the
    /// cost of that flag ever being absent is silent.
    @Test("a question can never be answered by a stored rule, whatever the CLI flagged")
    func aQuestionCannotBeWidened() {
        let suggestion = PermissionSuggestion(
            type: "addRules",
            behavior: "allow",
            rules: [PermissionRule(toolName: "AskUserQuestion", ruleContent: "*")],
            raw: .object([:])
        )

        let question = PermissionAsk(
            requestID: "req-1",
            toolName: "AskUserQuestion",
            suggestions: [suggestion],
            suppressesAlwaysAllow: false,
            requiresUserInteraction: false
        )

        #expect(question.isQuestion)
        #expect(!question.canWiden)

        // The same ask for anything else still can be widened, so the rule above is about
        // questions rather than about suggestions.
        let other = PermissionAsk(
            requestID: "req-2",
            toolName: "Bash",
            suggestions: [
                PermissionSuggestion(
                    type: "addRules",
                    behavior: "allow",
                    rules: [PermissionRule(toolName: "Bash", ruleContent: "ls")],
                    raw: .object([:])
                )
            ]
        )

        #expect(!other.isQuestion)
        #expect(other.canWiden)
    }
}
