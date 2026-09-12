import Foundation
import Synchronization
import Testing
@testable import BloomCore

@Suite("Interaction modes", .scratchDirectory)
struct InteractionModeTests {
    @Test("Codex planning leaves permission selection independent")
    func permissionIndependence() {
        var controls = ComposerControls(agentKind: .codex, permissionMode: .bypassPermissions, interactionMode: .plan)
        #expect(controls.permissionMode == .bypassPermissions)
        #expect(controls.interactionMode == .plan)
        controls.agentKind = .claudeCode
        #expect(controls.interactionMode == .build)
        #expect(controls.permissionMode == .bypassPermissions)
    }

    @Test("Plan and Build reach the provider with explicit default reset", arguments: InteractionMode.allCases)
    func wire(mode: InteractionMode) async throws {
        let box = ProcessBox()
        let client = CodexClient(configuration: .init(cwd: "/tmp/plan-wire"), makeProcess: box.factory)
        box.reply(to: "turn/start", with: .object(["turn": .object([
            "id": .string("turn-plan"), "status": .string("inProgress"),
        ])]))
        try await client.start()
        let initialise = try #require(box.process.sentFrame { $0["method"]?.stringValue == "initialize" })
        #expect(initialise["params"]?["capabilities"]?["experimentalApi"]?.boolValue == true)
        _ = try await client.startTurn(
            threadID: "thread", input: [.text("Plan the change")], model: "gpt-5.6-sol", effort: "high",
            approvalPolicy: .never, sandboxPolicy: .object(["type": .string("dangerFullAccess")]),
            interactionMode: mode
        )
        let frame = try #require(box.process.sentFrame { $0["method"]?.stringValue == "turn/start" })
        let params = try #require(frame["params"])
        #expect(params["approvalPolicy"]?.stringValue == "never")
        #expect(params["sandboxPolicy"]?["type"]?.stringValue == "dangerFullAccess")
        #expect(params["collaborationMode"]?["mode"]?.stringValue == (mode == .plan ? "plan" : "default"))
        #expect(params["collaborationMode"]?["settings"]?["model"]?.stringValue == "gpt-5.6-sol")
        #expect(params["collaborationMode"]?["settings"]?["reasoning_effort"]?.stringValue == "high")
        #expect(params["collaborationMode"]?["settings"]?.objectValue?["developer_instructions"] == .null)
        await client.stop()
    }

    @Test("A queued plan keeps its mode after preferences change and the store reopens")
    func queueSnapshot() async throws {
        let path = TestScratch.unique("interaction-mode") + ".sqlite"
        let store = try Store(path: path)
        let session = try await store.upsert(Session(workspaceID: nil, agentKind: .codex, interactionMode: .plan))
        _ = try await store.enqueueDelivery(Delivery(targetSessionID: session.id, body: "Plan", interactionMode: .plan))
        try await store.updateSessionPreferences(id: session.id, interactionMode: .build)
        let reopened = try Store(path: path)
        #expect(try await reopened.session(id: session.id)?.interactionMode == .build)
        #expect(try await reopened.pendingDeliveries(sessionID: session.id).first?.interactionMode == .plan)
    }

    @Test("A known old-CLI field rejection retries Build once without changing permissions")
    func oldBuildFallback() async throws {
        let peer = Mutex<ScriptedCodexProcess?>(nil)
        let acceptsPlanning = Mutex(false)
        let box = ProcessBox(onWrite: { line in
            guard let frame = JSONValue.parse(line), frame["method"]?.stringValue == "turn/start",
                  let id = frame["id"], let process = peer.withLock({ $0 }) else { return }
            let response: JSONValue
            if frame["params"]?["collaborationMode"] != nil && !acceptsPlanning.withLock({ $0 }) {
                response = .object(["id": id, "error": .object([
                    "code": .integer(-32602), "message": .string("unknown field collaborationMode"),
                ])])
            } else {
                response = .object(["id": id, "result": .object(["turn": .object([
                    "id": .string("accepted"), "status": .string("inProgress"),
                ])])])
            }
            process.emit(response.compactJSON)
        })
        box.ignore("turn/start")
        let client = CodexClient(configuration: .init(cwd: "/tmp/older-codex"), makeProcess: box.factory)
        try await client.start()
        peer.withLock { $0 = box.process }
        let turn = try await client.startTurn(
            threadID: "thread", input: [.text("Build")], model: "model", approvalPolicy: .never, interactionMode: .build
        )
        #expect(turn.id == "accepted")
        let frames = box.process.stdin.compactMap(JSONValue.parse).filter { $0["method"]?.stringValue == "turn/start" }
        #expect(frames.count == 2)
        #expect(frames[0]["params"]?["collaborationMode"] != nil)
        #expect(frames[1]["params"]?["collaborationMode"] == nil)
        #expect(frames.allSatisfy { $0["params"]?["approvalPolicy"]?.stringValue == "never" })
        await #expect(throws: InteractionModeFailure.self) {
            _ = try await client.startTurn(threadID: "thread", input: [.text("Plan")], model: "model", interactionMode: .plan)
        }
        #expect(box.process.sentMethods.filter { $0 == "turn/start" }.count == 2)
        acceptsPlanning.withLock { $0 = true }
        await client.resetPlanningSupport()
        _ = try await client.startTurn(threadID: "thread", input: [.text("Plan")], model: "model", interactionMode: .plan)
        #expect(box.process.sentMethods.filter { $0 == "turn/start" }.count == 3)
        await client.stop()
    }

    @Test("Plan rejection and ambiguous provider errors never retry as Build")
    func noUnsafeFallback() async throws {
        for code in [-32602, -32603] {
            let box = ProcessBox()
            box.fail("turn/start", code: code, message: "collaborationMode unavailable")
            let client = CodexClient(configuration: .init(cwd: "/tmp/old-plan"), makeProcess: box.factory)
            try await client.start()
            do {
                _ = try await client.startTurn(threadID: "thread", input: [.text("Plan")], model: "model", interactionMode: .plan)
                Issue.record("The unsupported request unexpectedly succeeded")
            } catch {
                #expect(InteractionModeFailure.isDefinitiveTurnRejection(error) == (code == -32602))
            }
            #expect(box.process.sentMethods.filter { $0 == "turn/start" }.count == 1)
            await client.stop()
        }
    }

    @Test("A malformed planning setting does not disable a supported capability or retry")
    func invalidSettingIsNotMissingCapability() async throws {
        let box = ProcessBox()
        box.fail("turn/start", code: -32602, message: "collaborationMode.settings.reasoning_effort is invalid")
        let client = CodexClient(configuration: .init(cwd: "/tmp/invalid-setting"), makeProcess: box.factory)
        try await client.start()
        await #expect(throws: CodexRPCError.self) {
            _ = try await client.startTurn(threadID: "thread", input: [.text("Build")], model: "model", interactionMode: .build)
        }
        #expect(box.process.sentMethods.filter { $0 == "turn/start" }.count == 1)
        #expect(await client.planningIsSupported != false)
        await client.stop()
    }
}
