import Foundation
import Testing
@testable import BloomClient

@Suite struct TranscriptProjectionTests {
    @Test func visibilityMatchesDesktopNoiseAndPreservesErrorsAndUnknownKinds() {
        let empty = Data("{}".utf8)
        #expect(!TranscriptVisibility.isVisible(kind: "notice", payload: empty))
        #expect(!TranscriptVisibility.isVisible(kind: "system", payload: Data(#"{"subtype":"hook_response"}"#.utf8)))
        #expect(!TranscriptVisibility.isVisible(kind: "system", payload: empty))
        #expect(TranscriptVisibility.isVisible(kind: "system", payload: Data(#"{"subtype":"init"}"#.utf8)))
        for kind in ["error", "result", "assistantText", "unknownFutureEvent"] {
            #expect(TranscriptVisibility.isVisible(kind: kind, payload: empty))
        }
    }

    @Test func backgroundWakeRemainsVisibleInRemoteProjection() throws {
        let payload = #"{"type":"system","subtype":"task_notification","summary":"Background command finished"}"#
        let row = try message(1, kind: "system", payload: payload)
        #expect(TranscriptVisibility.isBackgroundWake(kind: "system", payload: Data(payload.utf8)))
        #expect(RemoteTranscriptProjection.rows(messages: [row]).map(\.id) == [1])
        #expect(!TranscriptVisibility.isVisible(kind: "system", payload: Data(#"{"subtype":"task_updated"}"#.utf8)))
    }

    @Test func resultSettlesCallWithoutReplacingItsIdentityOrChangingEventBuffer() throws {
        let call = try message(2, kind: "toolUse", ref: "call", payload: callPayload)
        let events = [try message(1, kind: "notice"), call, try message(3, kind: "assistantText")]
        let before = RemoteTranscriptProjection.rows(messages: events)
        let result = try message(4, kind: "toolResult", ref: "call", payload: resultPayload)
        let all = events + [result]
        let after = RemoteTranscriptProjection.rows(messages: all)
        #expect(before.map(\.id) == [2, 3])
        #expect(after.map(\.id) == before.map(\.id))
        #expect(after[0].message == call && after[0].toolResult == result)
        #expect(after[0] != before[0] && after[1] == before[1])
        #expect(all.count == 4 && all.last?.seq == 4)
        let inspection = try #require(RemoteToolInspection(row: after[0]))
        #expect(inspection.arguments?.contains("test") == true)
        #expect(inspection.output == "Tests passed")
        #expect(inspection.status == "Completed" && !inspection.isError)
    }

    @Test func missingReferencesStayVisibleAndRepeatedReferencesUseLatestCall() throws {
        let events = [try message(1, kind: "toolResult", ref: "missing"),
                      try message(2, kind: "toolUse", ref: "call"),
                      try message(3, kind: "toolUse", ref: "call"),
                      try message(4, kind: "toolResult", ref: "call"),
                      try message(5, kind: "toolUse"), try message(6, kind: "toolResult")]
        let rows = RemoteTranscriptProjection.rows(messages: events)
        #expect(rows.map(\.id) == [1, 2, 3, 5, 6])
        #expect(rows[1].toolResult == nil && rows[2].toolResult?.id == 4)
    }

    @Test func failedResultsRetainCallArgumentsErrorAndRawOutput() throws {
        let call = try message(1, kind: "toolUse", ref: "call", payload: callPayload)
        let result = try message(2, kind: "toolResult", ref: "call", payload: #"{"message":{"content":[{"type":"tool_result","tool_use_id":"call","is_error":true,"content":"Process failed"}]}}"#)
        let rows = RemoteTranscriptProjection.rows(messages: [call, result, try message(3, kind: "error")])
        #expect(rows.count == 2 && rows.last?.message.kind == "error")
        let inspection = try #require(RemoteToolInspection(row: rows[0]))
        #expect(inspection.isError && inspection.status == "Failed")
        #expect(inspection.output == "Process failed" && inspection.arguments != nil)
    }

    @Test func correctedResultChangesSameProjectedRow() throws {
        let call = try message(1, kind: "toolUse", ref: "call", payload: callPayload)
        let first = RemoteTranscriptProjection.rows(messages: [call, try message(2, kind: "toolResult", ref: "call", payload: resultPayload)])
        let corrected = RemoteTranscriptProjection.rows(messages: [call, try message(2, kind: "toolResult", ref: "call", payload: resultPayload.replacingOccurrences(of: "Tests passed", with: "Corrected result"))])
        #expect(first[0].id == corrected[0].id && first[0] != corrected[0])
        #expect(RemoteToolInspection(row: corrected[0])?.output == "Corrected result")
    }

    private var callPayload: String { #"{"message":{"content":[{"type":"tool_use","id":"call","name":"Bash","input":{"command":"test"}}]}}"# }
    private var resultPayload: String { #"{"message":{"content":[{"type":"tool_result","tool_use_id":"call","content":"Tests passed"}]}}"# }

    private func message(_ id: Int, kind: String, ref: String? = nil, payload: String = "{}") throws -> RemoteMessage {
        var fields: [String: JSONValue] = ["id": .integer(id), "seq": .integer(id), "kind": .string(kind),
                                           "payload": .string(Data(payload.utf8).base64EncodedString())]
        if let ref { fields["refID"] = .string(ref) }
        return try JSONDecoder().decode(RemoteMessage.self, from: JSONEncoder().encode(JSONValue.object(fields)))
    }
}
