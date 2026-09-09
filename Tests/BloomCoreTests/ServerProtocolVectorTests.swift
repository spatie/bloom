import Foundation
import Testing
@testable import BloomCore

/// These vectors come from the production Codable types, not a second hand-written wire codec.
struct ServerProtocolVectorTests {
    @Test func encodeCrossLanguageVectors() throws {
        let id = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
        let workspace = WorkspaceID("workspace-example")
        let sessionID = SessionID("session-example")
        let epoch = Date(timeIntervalSinceReferenceDate: 0)
        let session = Session(id: sessionID, workspaceID: workspace, model: "example-model", effort: "medium", createdAt: epoch, updatedAt: epoch)
        let message = Message(id: 7, sessionID: sessionID, seq: 1, kind: .assistantText,
                              payload: Data("{\"text\":\"Hello\\nworld\"}".utf8), createdAt: epoch)
        let operations: [(String, ServerOperation)] = [
            ("hello", .hello), ("catalogue", .catalogue),
            ("transcript", .transcript(sessionID: sessionID, afterSeq: 0)),
            ("snapshot", .reviewSnapshot(workspaceID: workspace, scope: .branch, knownRevision: nil, wait: true)),
            ("patch", .reviewPatch(workspaceID: workspace, path: "README.md", scope: .uncommitted, knownRevision: "revision-1")),
            ("file", .file(workspaceID: workspace, path: "README.md")),
            ("files", .workspace(workspaceID: workspace, action: .files)),
            ("upload", .workspace(workspaceID: workspace, action: .uploadFile(name: "note.txt", data: Data([0, 1, 255])))),
            ("clearColour", .workspace(workspaceID: workspace, action: .setColour(nil))),
            ("settings", .project(repoID: RepoID("repo-example"), action: .settings)),
            ("context", .creation(.workspaceContext(RepoID("repo-example")))),
            ("answer", .answer(sessionID: sessionID, requestID: "ask-example", answer: .question(input: .object(["choice": .string("yes")]))))
        ]
        let results: [(String, ServerResult)] = [
            ("hello", .hello(name: "example-server")), ("accepted", .accepted), ("failure", .failure("Example refusal")),
            ("snapshot", .reviewSnapshot(.init(revision: "revision-1", files: [.init(path: "README.md", change: .modified, additions: 2, deletions: 1)]))),
            ("unchangedSnapshot", .reviewSnapshot(.init(revision: "revision-1", files: nil))),
            ("unchangedPatch", .reviewPatch(.init(revision: "revision-1", patch: nil))),
            ("file", .file(.init(path: "README.md", text: "# Hello\n"))),
            ("download", .download(.init(path: "note.txt", data: Data([0, 1, 255])))),
            ("transcript", .transcript(.init(session: session, messages: [message], pendingQuestions: [Data("{}".utf8)], isBusy: false,
                                           streamingText: "", permissionDecisions: [:], queuedPrompts: [], queueError: nil)))
        ]
        var vectors: [[String: Any]] = []
        for (name, operation) in operations {
            let value = ServerRequest(operation, id: id)
            let data = try JSONEncoder().encode(value)
            let decoded = try JSONDecoder().decode(ServerRequest.self, from: data)
            #expect(decoded == value)
            vectors.append(["name": "request-" + name, "value": try JSONSerialization.jsonObject(with: data)])
        }
        for (name, result) in results {
            let data = try JSONEncoder().encode(ServerReply(id: id, result: result))
            vectors.append(["name": "reply-" + name, "value": try JSONSerialization.jsonObject(with: data)])
        }
        let encodedMessage = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(message)) as? [String: Any])
        #expect(encodedMessage["createdAt"] as? Double == 0)
        #expect(encodedMessage["sessionID"] as? String == "session-example")
        #expect(encodedMessage["payload"] as? String == message.payload.base64EncodedString())
        if let output = ProcessInfo.processInfo.environment["BLOOM_PROTOCOL_VECTORS"] {
            let data = try JSONSerialization.data(withJSONObject: vectors, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            try data.write(to: URL(fileURLWithPath: output), options: .atomic)
        }
    }
}
