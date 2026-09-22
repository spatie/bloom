import AsyncHTTPClient
import BloomCore
import Foundation
import NIOCore
import Testing
@testable import BloomRunner

struct ModelGatewayTests {
    private static func grant(
        provider: OpaqueModelGrant.Provider = .openai,
        operation: OpaqueModelGrant.Operation = .openAIResponsesStream,
        model: String = "gpt-5-codex"
    ) -> OpaqueModelGrant {
        OpaqueModelGrant(
            token: String(repeating: "s", count: 64),
            expiresAt: Date().addingTimeInterval(600), revision: 1,
            provider: provider, model: model, operation: operation
        )
    }

    @Test("a local request is bound to its exact grant and strips provider control fields")
    func stripsReservedProviderFields() async throws {
        let fake = try await FakeControlServer.start()
        defer { Task { await fake.stop() } }
        fake.script("POST", "/model-gateway/streams", .init(
            status: 200, body: "data: {\"type\":\"response.completed\"}\n\n",
            headers: ["Content-Type": "text/event-stream"]
        ))
        let client = RunbloomClient(
            baseURL: fake.baseURL, workspaceID: fake.workspaceID, secret: fake.secret, http: .shared
        )
        let gateway = ModelGateway(client: client)
        let environment = try await gateway.install(
            turnID: "turn-1", grants: [.codex: Self.grant()], baseURL: "http://127.0.0.1:8123"
        )
        let token = try #require(environment[.codex]?["OPENAI_API_KEY"])
        let request = try JSONSerialization.data(withJSONObject: [
            "model": "gpt-5-codex", "stream": true, "store": false, "background": false,
            "input": "Hello",
        ])
        let stream = try await gateway.open(token: token, path: "/v1/responses", body: request)
        _ = try await stream.response.body.collect(upTo: 1_024)
        await gateway.complete(token: token, requestID: stream.requestID)

        let sent = try #require(fake.requests("POST", "/model-gateway/streams").first?.json)
        #expect(sent["version"] as? String == "opaque_model_grant_v1")
        #expect(sent["provider"] as? String == "openai")
        #expect(sent["operation"] as? String == "openai_responses_stream")
        #expect(sent["model"] as? String == "gpt-5-codex")
        let modelRequest = try #require(sent["model_request"] as? [String: Any])
        #expect(modelRequest["input"] as? String == "Hello")
        #expect(modelRequest["model"] as? String == "gpt-5-codex")
        #expect(modelRequest["stream"] == nil)
        #expect(modelRequest["store"] == nil)
        #expect(modelRequest["background"] == nil)
        #expect(fake.requests("POST", "/model-gateway/streams").first?.proof["version"] == "1")
        await gateway.shutdown()
    }

    @Test("Claude's beta names reach runbloom.app, so a request using them is not refused upstream")
    func forwardsAnthropicBetas() async throws {
        let fake = try await FakeControlServer.start()
        defer { Task { await fake.stop() } }
        fake.script("POST", "/model-gateway/streams", .init(
            status: 200, body: "data: {}\n\n", headers: ["Content-Type": "text/event-stream"]
        ))
        let client = RunbloomClient(
            baseURL: fake.baseURL, workspaceID: fake.workspaceID, secret: fake.secret, http: .shared
        )
        let gateway = ModelGateway(client: client)
        let grant = Self.grant(provider: .anthropic, operation: .anthropicMessagesStream, model: "claude-opus-5")
        let environment = try await gateway.install(
            turnID: "turn-1", grants: [.claudeCode: grant], baseURL: "http://127.0.0.1:8123"
        )
        let token = try #require(environment[.claudeCode]?["ANTHROPIC_API_KEY"])
        let request = try JSONSerialization.data(withJSONObject: [
            "messages": [], "context_management": [:] as [String: Any],
        ])
        let stream = try await gateway.open(
            token: token, path: "/v1/messages", body: request,
            betas: ["claude-code-20250219, context-management-2025-06-27", "context-management-2025-06-27"]
        )
        _ = try await stream.response.body.collect(upTo: 1_024)
        await gateway.complete(token: token, requestID: stream.requestID)

        let sent = try #require(fake.requests("POST", "/model-gateway/streams").first?.json)
        #expect(sent["anthropic_beta"] as? [String] == ["claude-code-20250219", "context-management-2025-06-27"])
        await gateway.shutdown()
    }

    @Test("the model Claude resolves from its grant is accepted, and nothing outside it")
    func acceptsResolvedModels() {
        #expect(ModelGateway.allows(requested: "claude-opus-5", granted: "claude-opus-5[1m]"))
        #expect(ModelGateway.allows(requested: "claude-opus-5", granted: "opus[1m]"))
        #expect(ModelGateway.allows(requested: "gpt-5-codex", granted: "gpt-5-codex"))
        #expect(!ModelGateway.allows(requested: "claude-sonnet-4-5", granted: "opus[1m]"))
        #expect(!ModelGateway.allows(requested: "claude-opus-4-1", granted: "claude-opus-5[1m]"))
        #expect(!ModelGateway.allows(requested: "claude-opus-5[1m]", granted: "claude-opus-5[1m]"))
    }

    @Test("a beta name that is not a plain token, or one sent for another provider, is refused")
    func refusesUnsafeBetas() throws {
        #expect(try ModelGateway.anthropicBetas([], provider: .openai).isEmpty)
        #expect(throws: ModelGateway.Refusal.self) {
            try ModelGateway.anthropicBetas(["x\r\ninjected: 1"], provider: .anthropic)
        }
        #expect(throws: ModelGateway.Refusal.self) {
            try ModelGateway.anthropicBetas(["files-api-2025-04-14"], provider: .openai)
        }
    }

    @Test("a model override is refused before any upstream request")
    func refusesModelOverride() async throws {
        let fake = try await FakeControlServer.start()
        defer { Task { await fake.stop() } }
        let client = RunbloomClient(
            baseURL: fake.baseURL, workspaceID: fake.workspaceID, secret: fake.secret, http: .shared
        )
        let gateway = ModelGateway(client: client)
        let environment = try await gateway.install(
            turnID: "turn-1", grants: [.codex: Self.grant()], baseURL: "http://127.0.0.1:8123"
        )
        let token = try #require(environment[.codex]?["OPENAI_API_KEY"])
        let request = try JSONSerialization.data(withJSONObject: [
            "model": "gpt-5.6-pro", "stream": true, "input": "Hello",
        ])
        await #expect(throws: ModelGateway.Refusal.self) {
            _ = try await gateway.open(token: token, path: "/v1/responses", body: request)
        }
        #expect(fake.requests("POST", "/model-gateway/streams").isEmpty)
        await gateway.shutdown()
    }

    @Test("ending a turn revokes its local credential and cancels active streams")
    func revokeCancelsActiveStreams() async throws {
        let fake = try await FakeControlServer.start()
        defer { Task { await fake.stop() } }
        fake.script("POST", "/model-gateway/streams", .init(
            status: 200, body: "data: {}\n\n", headers: ["Content-Type": "text/event-stream"]
        ))
        let fixedID = UUID(uuidString: "19c558bd-8783-4059-85e0-878d48ec19c8")!
        let client = RunbloomClient(
            baseURL: fake.baseURL, workspaceID: fake.workspaceID, secret: fake.secret, http: .shared
        )
        let gateway = ModelGateway(client: client, identifier: { fixedID })
        let environment = try await gateway.install(
            turnID: "turn-1", grants: [.codex: Self.grant()], baseURL: "http://127.0.0.1:8123"
        )
        let token = try #require(environment[.codex]?["OPENAI_API_KEY"])
        let request = try JSONSerialization.data(withJSONObject: ["input": "Hello"])
        _ = try await gateway.open(token: token, path: "/v1/responses", body: request)
        await gateway.revoke(turnID: "turn-1")

        #expect(fake.requests("DELETE", "/model-gateway/requests/\(fixedID.uuidString.lowercased())").count == 1)
        await #expect(throws: ModelGateway.Refusal.self) {
            _ = try await gateway.open(token: token, path: "/v1/responses", body: request)
        }
    }
}
