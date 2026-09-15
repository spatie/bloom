import Foundation

/// A deliberately narrow consent surface. Special tools must get their own UI before approval.
public struct RemoteApproval: Sendable, Equatable {
    public let requestID: String
    public let toolName: String
    public let context: String
    public let input: JSONValue
    public let questions: [AgentQuestion]
    public let isSupported: Bool

    public init?(data: Data) {
        guard let json = JSONValue.parse(data), json["type"]?.stringValue == "control_request",
              let id = json["request_id"]?.stringValue, !id.isEmpty,
              let request = json["request"], request["subtype"]?.stringValue == "can_use_tool",
              let tool = request["tool_name"]?.stringValue, !tool.isEmpty,
              let input = request["input"], case .object = input else { return nil }
        requestID = id
        toolName = tool
        self.input = input
        questions = AgentQuestionnaire.isQuestion(toolName: tool) ? AgentQuestionnaire.questions(in: input) : []
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let encoded = (try? encoder.encode(input)) ?? Data()
        context = [request["description"]?.stringValue, request["decision_reason"]?.stringValue,
                   request["blocked_path"]?.stringValue, String(data: encoded, encoding: .utf8)]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n\n")
        if tool == AgentQuestionnaire.toolName {
            isSupported = !questions.isEmpty && questions.count == input["questions"]?.arrayValue?.count
                && Set(questions.map(\.id)).count == questions.count
                && zip(questions, input["questions"]?.arrayValue ?? []).allSatisfy { question, raw in
                    Self.validQuestion(raw)
                        && Set(question.options.map(\.label)).count == question.options.count
                        && question.options.count == (raw["options"]?.arrayValue?.count ?? 0)
                        && (question.allowsOther || !question.options.isEmpty)
                }
        } else {
            let tools: Set<String> = ["Bash", "Shell", "Read", "Write", "Edit", "MultiEdit", "ApplyPatch", "Glob", "Grep", "WebFetch", "WebSearch"]
            isSupported = tools.contains(tool) && input.objectValue?.isEmpty == false
                && request["requires_user_interaction"]?.boolValue != true
                && (request["requires_user_interaction"] == nil || request["requires_user_interaction"]?.boolValue != nil)
                && Self.hasReviewableContext(tool: tool, input: input)
        }
    }

    private static func hasReviewableContext(tool: String, input: JSONValue) -> Bool {
        if tool == "Bash" || tool == "Shell" { return input["command"]?.stringValue?.isEmpty == false }
        if ["Read", "Write", "Edit", "MultiEdit"].contains(tool) { return input["file_path"]?.stringValue?.isEmpty == false }
        if tool == "Glob" || tool == "Grep" { return input["pattern"]?.stringValue != nil }
        if tool == "WebFetch" { return input["url"]?.stringValue?.isEmpty == false }
        if tool == "WebSearch" { return input["query"]?.stringValue?.isEmpty == false }
        if tool == "ApplyPatch" {
            guard let changes = input["codexItem"]?["changes"]?.arrayValue, !changes.isEmpty else { return false }
            return changes.allSatisfy { $0["path"]?.stringValue?.isEmpty == false && $0["diff"]?.stringValue != nil }
        }
        return true
    }

    private static func validQuestion(_ raw: JSONValue) -> Bool {
        for key in ["multiSelect", "bloomAllowsOther", "isSecret"] where raw[key] != nil {
            guard raw[key]?.boolValue != nil else { return false }
        }
        if let id = raw["bloomAnswerID"], id.stringValue?.isEmpty != false { return false }
        if let options = raw["options"], options.arrayValue == nil { return false }
        return true
    }

    public func decision(sessionID: SessionID, allow: Bool) throws -> RemoteCommand {
        guard isSupported, questions.isEmpty else { throw ConnectionFailure("This request needs its own approval interface in Bloom on Mac.") }
        return answer(sessionID: sessionID, value: .object([allow ? "allowOnce" : "deny": .object([:])]))
    }

    public func answer(sessionID: SessionID, draft: AgentQuestionDraft) throws -> RemoteCommand {
        guard isSupported, !questions.isEmpty, draft.isComplete(questions) else { throw ConnectionFailure("Answer every question before submitting.") }
        let values = draft.answers(to: questions)
        for question in questions where !question.allowsOther {
            guard (draft.other[question.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ConnectionFailure("Choose one of the offered answers.")
            }
        }
        let updated = AgentQuestionnaire.answered(input, answers: values)
        return answer(sessionID: sessionID, value: .object(["question": .object(["input": updated])]))
    }

    private func answer(sessionID: SessionID, value: JSONValue) -> RemoteCommand {
        .call("answer", ["sessionID": .string(sessionID.rawValue), "requestID": .string(requestID), "answer": value])
    }
}
