import Foundation
import Testing
@testable import BloomClient

struct ClientTests {
    @Test(arguments: ["http://example.com", "https://user:secret@example.com", "https://example.com/path", "https://example.com?token=secret", "https://example.com#secret"])
    func refusesUnsafeOrigins(address: String) {
        #expect(throws: ConnectionFailure.self) { try HTTPSConnection.origin(address) }
    }

    @Test func normalisesOriginWithoutLosingPort() throws {
        let origin = try HTTPSConnection.origin("https://EXAMPLE.com:8443/")
        #expect(origin.absoluteString == "https://example.com:8443")
    }

    @Test func refusesMismatchedReply() throws {
        let command = RemoteCommand.call("hello")
        let data = try JSONEncoder().encode(JSONValue.object([
            "version": .integer(BloomWire.version), "id": .string(UUID().uuidString),
            "result": .object(["hello": .object(["name": .string("server")])]),
        ]))
        #expect(throws: ConnectionFailure.self) { try RemoteClient.decode(data, commandID: command.id) }
    }

    @Test func refusalHasKnownOutcome() throws {
        let id = UUID()
        let data = try JSONEncoder().encode(JSONValue.object([
            "version": .integer(BloomWire.version), "id": .string(id.uuidString),
            "result": .object(["failure": .object(["_0": .string("No access")])]),
        ]))
        #expect(throws: ConnectionRefusal.self) { try RemoteClient.decode(data, commandID: id) }
    }

    @Test func retryKeepsCommandIdentity() throws {
        let command = RemoteCommand.send(sessionID: SessionID("chat"), text: "Run tests")
        let retry = try JSONDecoder().decode(RemoteCommand.self, from: JSONEncoder().encode(command))
        #expect(retry == command)
        #expect(retry.operation["send"]?["sessionID"]?.stringValue == "chat")
    }

    @Test func sharedJSONPreservesLargeIntegers() throws {
        let value = JSONValue.integer(9_007_199_254_740_993)
        let roundTrip = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
        #expect(roundTrip == value)
    }

    @Test func transcriptMergesWithoutDuplicates() throws {
        let initial = try transcript(messages: [(1, "First"), (2, "Second")], streaming: "Thinking")
        let increment = try transcript(messages: [(2, "Second"), (3, "Third")], streaming: "")
        var buffer = TranscriptBuffer()
        buffer.apply(initial)
        buffer.apply(increment)
        #expect(buffer.messages.map(\.seq) == [1, 2, 3])
        #expect(buffer.messages.map(\.text) == ["First", "Second", "Third"])
        #expect(buffer.sequence == 3)
        #expect(buffer.streamingText.isEmpty)
    }

    private func transcript(messages: [(Int, String)], streaming: String) throws -> RemoteTranscript {
        let records: [JSONValue] = try messages.map { sequence, text in
            let payload = try JSONEncoder().encode(JSONValue.object(["text": .string(text)]))
            return .object(["id": .integer(sequence), "seq": .integer(sequence), "kind": .string("assistantText"), "payload": .string(payload.base64EncodedString())])
        }
        return try RemoteTranscript.decode(.object(["transcript": .object(["_0": .object([
            "session": .object(["id": .string("s"), "workspaceID": .string("w"), "title": .string("Chat"), "model": .string("model"), "agentKind": .string("codex"), "state": .string("idle")]),
            "messages": .array(records), "pendingQuestions": .array([]), "isBusy": .bool(false), "streamingText": .string(streaming)
        ])])]))
    }
}
