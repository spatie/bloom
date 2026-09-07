import Foundation

/// Adapts Codex's id-keyed question protocol to the shared question card. The original request
/// remains authoritative when building a reply, so an edited input cannot answer unrelated ids.
public enum CodexQuestionnaire {
    public static func input(for request: CodexApprovalRequest) -> JSONValue {
        let questions = (request.params["questions"]?.arrayValue ?? []).compactMap { value -> JSONValue? in
            guard case .object(var question) = value,
                  let id = question["id"]?.stringValue, !id.isEmpty else { return nil }
            question["bloomAnswerID"] = .string(id)
            let hasOptions = !(question["options"]?.arrayValue ?? []).isEmpty
            question["bloomAllowsOther"] = .bool(!hasOptions || question["isOther"]?.boolValue == true)
            return .object(question)
        }
        return .object(["questions": .array(questions)])
    }

    public static func result(input: JSONValue, request: CodexApprovalRequest) -> JSONValue {
        var answers: [String: JSONValue] = [:]
        for question in request.params["questions"]?.arrayValue ?? [] {
            guard let id = question["id"]?.stringValue,
                  let answer = input["answers"]?[id]?.stringValue,
                  !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            answers[id] = .object(["answers": .array([.string(answer)])])
        }
        return .object(["answers": .object(answers)])
    }
}
