import Testing
import Foundation
@testable import BloomCore

@Suite("Grok client")
struct GrokClientTests {
    @Test("launch is ACP stdio, never the user's leader, and never always-approve by default")
    func launchShape() {
        let launch = GrokClient.launch(GrokClient.Configuration(cwd: "/tmp/w", environment: [:]))
        #expect(launch.executable == "grok")
        #expect(launch.arguments == ["agent", "--no-leader", "stdio"])
        #expect(launch.cwd == "/tmp/w")
        #expect(launch.environment["GROK_DISABLE_AUTOUPDATER"] == "1")
        #expect(!launch.arguments.contains("--always-approve"))
    }

    @Test("bypass permissions adds always-approve at process start")
    func alwaysApproveArgv() {
        let launch = GrokClient.launch(GrokClient.Configuration(
            cwd: "/tmp/w",
            environment: [:],
            alwaysApprove: true
        ))
        #expect(launch.arguments.contains("--always-approve"))
        #expect(launch.arguments.contains("--no-leader"))
        #expect(launch.arguments.last == "stdio")
    }

    @Test("a frame with method and id is a server request")
    func permissionFrame() {
        let line = #"{"jsonrpc":"2.0","id":5,"method":"session/request_permission","params":{"sessionId":"s","toolCall":{"toolCallId":"c1"},"options":[]}}"#
        let frame = GrokFrame.decode(line: line)
        guard case .request(let request) = frame else {
            Issue.record("expected request")
            return
        }
        #expect(request.method == "session/request_permission")
        #expect(GrokPermissionRequest.decode(request)?.toolCall.id == "c1")
    }

    @Test("session/update notifications decode text chunks")
    func updateNotification() {
        let line = #"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"Hi"}}}}"#
        let frame = GrokFrame.decode(line: line)
        guard case .notification(let note) = frame else {
            Issue.record("expected notification")
            return
        }
        let update = GrokSessionUpdate.decode(params: note.params)
        guard case .text("Hi") = update?.kind else {
            Issue.record("expected text")
            return
        }
        #expect(update?.sessionID == "s")
    }

    @Test("handshake then session/new persists the id the server returned")
    func handshakeAndNewSession() async throws {
        let box = ProcessBox()
        box.reply(to: "initialize", with: .object([
            "_meta": .object([
                "modelState": .object([
                    "currentModelId": .string("grok-4.6"),
                    "availableModels": .array([
                        .object([
                            "modelId": .string("grok-4.6"),
                            "name": .string("Grok 4.6"),
                            "_meta": .object([
                                "reasoningEffort": .string("high"),
                                "reasoningEfforts": .array([
                                    .object(["id": .string("high"), "default": .bool(true)]),
                                    .object(["id": .string("low")]),
                                ]),
                            ]),
                        ]),
                    ]),
                ]),
            ]),
        ]))
        box.reply(to: "session/new", with: .object([
            "sessionId": .string("sess-live"),
            "models": .object([
                "currentModelId": .string("grok-4.6"),
                "availableModels": .array([
                    .object(["modelId": .string("grok-4.6"), "name": .string("Grok 4.6")]),
                ]),
            ]),
        ]))
        let client = GrokClient(
            configuration: GrokClient.Configuration(cwd: "/tmp/w", environment: [:]),
            makeProcess: box.factory
        )
        try await client.start()
        #expect(await client.advertisedModels().map(\.id) == ["grok-4.6"])
        let session = try await client.newSession(cwd: "/tmp/w")
        #expect(session.id == "sess-live")
        #expect(box.process.sentMethods.contains("initialize"))
        #expect(box.process.sentMethods.contains("initialized"))
        #expect(box.process.sentMethods.contains("session/new"))
        await client.stop()
    }
}

@Suite("Grok model rank")
struct GrokModelRankTests {
    @Test("newer versions lead, and a prefix is enough to recognise Grok")
    func orderAndRecognition() {
        let models = [
            GrokModel(id: "grok-4.5", displayName: "Grok 4.5"),
            GrokModel(id: "grok-4.6", displayName: "Grok 4.6"),
        ]
        #expect(GrokModelRank.ordered(models).map(\.id) == ["grok-4.6", "grok-4.5"])
        #expect(GrokModelRank.recognises("grok-4.6"))
        #expect(GrokModelRank.recognises("Grok-4.5"))
        #expect(!GrokModelRank.recognises("gpt-5.6-sol"))
        #expect(!GrokModelRank.recognises("opus"))
    }
}
