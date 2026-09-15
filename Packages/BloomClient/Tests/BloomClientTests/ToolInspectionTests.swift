import Foundation
import Testing
@testable import BloomClient

struct ToolInspectionTests {
    @Test func callsUseTheSamePresentationAndPreserveArguments() throws {
        let input: JSONValue = .object(["command": .string("php artisan test --filter=Reply")])
        let message = try record(kind: "toolUse", reference: "call", blocks: [.object([
            "type": .string("tool_use"), "id": .string("call"), "name": .string("Bash"), "input": input
        ])])
        let inspection = try #require(RemoteToolInspection(message: message))
        #expect(inspection.presentation == ToolPresenter.present(name: "Bash", input: input))
        #expect(inspection.arguments == input.prettyPrinted)
    }
    @Test func resultMetadataDistinguishesDenialFromExecutionFailure() throws {
        let blocks: [JSONValue] = [.object(["type": .string("tool_result"), "tool_use_id": .string("call"),
                                           "is_error": .bool(true), "content": .string("Permission was declined")])]
        let denied = try record(kind: "toolResult", reference: "call", blocks: blocks,
                               metadata: [.object(["id": .string("call"), "non_execution_kind": .string("user-rejected")])])
        let inspection = try #require(RemoteToolInspection(message: denied))
        #expect(!inspection.isError && inspection.presentation.label == "Denied")
        let failed = try #require(RemoteToolInspection(message: record(kind: "toolResult", reference: "call", blocks: blocks)))
        #expect(failed.isError && failed.presentation.label == "Tool failed")
    }
    @Test func referenceSelectsTheCorrectBlockInAMultiToolPayload() throws {
        let blocks: [JSONValue] = ["first", "second"].map { .object([
            "type": .string("tool_use"), "id": .string($0), "name": .string("Read"),
            "input": .object(["file_path": .string("\($0).swift")])
        ]) }
        let message = try record(kind: "toolUse", reference: "second", blocks: blocks)
        #expect(RemoteToolInspection(message: message)?.presentation.detail == "second.swift")
    }
    private func record(kind: String, reference: String, blocks: [JSONValue], metadata: [JSONValue] = []) throws -> RemoteMessage {
        let payload = try JSONEncoder().encode(JSONValue.object(["message": .object(["content": .array(blocks)]), "tool_result_meta": .array(metadata)]))
        let value: JSONValue = .object(["id": .integer(1), "seq": .integer(1), "kind": .string(kind), "refID": .string(reference), "payload": .string(payload.base64EncodedString())])
        return try JSONDecoder().decode(RemoteMessage.self, from: JSONEncoder().encode(value))
    }
}
