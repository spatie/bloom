import Foundation
import Testing
@testable import BloomClient

struct RemoteComposerTests {
    private let codex = CodexModel(id: "gpt-test", displayName: "GPT Test", supportedEfforts: [
        CodexReasoningEffort(id: "low"), CodexReasoningEffort(id: "high")
    ], defaultEffort: "low")

    @Test func modelSwitchMovesBackendPermissionAndEffortTogether() {
        let choices = ComposerModelChoices(codexModels: [codex])
        let initial = ComposerControls(model: "opus", effort: "max", permissionMode: .plan,
                                       isFastMode: true, codexContextWindow: 1_000_000)
        let moved = choices.selecting("codex:gpt-test", in: initial)
        #expect(moved.model == "gpt-test")
        #expect(moved.agentKind == .codex)
        #expect(moved.permissionMode == .auto)
        #expect(moved.effort == "low")
        #expect(moved.isFastMode && moved.codexContextWindow == 1_000_000)
        var reviewing = moved
        reviewing.permissionMode = .autoReview
        let back = choices.selecting("opus", in: reviewing)
        #expect(back.agentKind == .claudeCode && back.permissionMode == .auto)
    }

    @Test func menuUsesServerEffortsAndPreservesUnknownPinnedModels() {
        let choices = ComposerModelChoices(codexModels: [codex], availableAgents: [.codex])
        #expect(choices.efforts(for: .codex, model: codex.id).map(\.id) == ["low", "high"])
        let sections = choices.sections(includingCurrent: "custom-model", on: .codex)
        #expect(sections.map(\.kind) == [.codex])
        #expect(sections.first?.options.map(\.id) == ["gpt-test", "custom-model"])
        let unknown = choices.selecting("custom-model", in: ComposerControls(agentKind: .codex))
        #expect(unknown.agentKind == .codex)
    }

    @Test func fastModeIsOnlyOfferedWhereTheServerImplementsIt() {
        #expect(ComposerControls(agentKind: .claudeCode).offersFastMode)
        #expect(!ComposerControls(agentKind: .codex, isFastMode: true).offersFastMode)
    }

    @Test func wireRoundTripKeepsEveryControlAndNormalisesUnsupportedPermission() throws {
        let controls = ComposerControls(model: codex.id, effort: "high", agentKind: .codex,
                                        permissionMode: .autoReview, isFastMode: true,
                                        outputStyle: "Concise", codexContextWindow: 500_000, hasWorktree: false)
        let state = RemoteComposerState(controls: controls, models: [codex], availableAgents: [.codex])
        let roundTrip = try JSONDecoder().decode(RemoteComposerState.self, from: JSONEncoder().encode(state))
        #expect(roundTrip == state)
        var raw = try JSONSerialization.jsonObject(with: JSONEncoder().encode(controls)) as? [String: Any] ?? [:]
        raw["permissionMode"] = "plan"
        let normalised = try JSONDecoder().decode(ComposerControls.self, from: JSONSerialization.data(withJSONObject: raw))
        #expect(normalised.permissionMode == .auto)
        #expect(normalised.permissionModeChoices.map(\.mode).contains(.plan) == false)
        #expect(CodexContextWindow.options(including: 750_000).contains(750_000))
    }

    @Test @MainActor func saveFailurePreservesAcknowledgedControlsAndRetryID() async throws {
        let initial = ComposerControls(model: codex.id, agentKind: .codex)
        let transport = ComposerTransport(state: RemoteComposerState(controls: initial, models: [codex], availableAgents: [.codex]))
        let store = RemoteComposerStore(service: RemoteWorkspaceService(client: transport), sessionID: SessionID("chat"))
        try await store.load()
        var requested = initial
        requested.isFastMode = true
        requested.codexContextWindow = 1_000_000
        await transport.failNextSave()
        await #expect(throws: ConnectionFailure.self) { try await store.apply(requested) }
        #expect(store.state?.controls == initial)
        #expect(store.error != nil && !store.isApplying && store.hasPendingSave)
        var replacement = requested
        replacement.codexContextWindow = 500_000
        await #expect(throws: ConnectionRefusal.self) { try await store.apply(replacement) }
        let reconnected = ComposerTransport(state: RemoteComposerState(controls: initial, models: [codex], availableAgents: [.codex]))
        try store.reconnect(using: RemoteWorkspaceService(client: reconnected))
        try await store.load()
        #expect(store.pendingControls == requested)
        #expect(await transport.saves.count == 1)
        let fork = try await store.apply(requested)
        #expect(fork == nil)
        #expect(store.state?.controls == requested && store.error == nil)
        let originalSaves = await transport.saves
        let retriedSaves = await reconnected.saves
        let saves = originalSaves + retriedSaves
        #expect(saves.count == 2 && saves[0].id == saves[1].id)
        let encoded = try #require(saves.last?.operation["setComposer"]?["controls"])
        let sent = try JSONDecoder().decode(ComposerControls.self, from: JSONEncoder().encode(encoded))
        #expect(sent == requested)
    }

    @Test @MainActor func retryCannotBeDiscardedWhileTheSaveIsInFlight() async throws {
        let transport = ComposerTransport(state: RemoteComposerState(controls: ComposerControls()))
        let store = RemoteComposerStore(service: .init(client: transport), sessionID: SessionID("chat"))
        try await store.load()
        await transport.holdNextSave()
        let save = Task { try await store.apply(ComposerControls(isFastMode: true)) }
        await transport.waitForHeldSave()
        #expect(throws: ConnectionRefusal.self) { try store.discardPendingSave() }
        #expect(store.isApplying && store.hasPendingSave)
        await transport.releaseSave()
        _ = try await save.value
        #expect(!store.hasPendingSave)
    }

    @Test @MainActor func explicitlyDiscardingRetryAllowsACorrectedSaveWithANewID() async throws {
        let initial = ComposerControls()
        let transport = ComposerTransport(state: RemoteComposerState(controls: initial, availableAgents: [.claudeCode]))
        let store = RemoteComposerStore(service: .init(client: transport), sessionID: SessionID("chat"))
        try await store.load()
        var requested = initial
        requested.isFastMode = true
        await transport.failNextSave()
        await #expect(throws: ConnectionFailure.self) { try await store.apply(requested) }
        #expect(store.hasPendingSave)
        try store.discardPendingSave()
        #expect(!store.hasPendingSave && store.pendingControls == nil)
        #expect(store.state?.controls == initial)
        requested.effort = "low"
        _ = try await store.apply(requested)
        let saves = await transport.saves
        #expect(saves.count == 2 && saves[0].id != saves[1].id)
    }

    @Test @MainActor func backendForkReturnsNewSessionWithoutChangingOriginalControls() async throws {
        let initial = ComposerControls()
        let transport = ComposerTransport(state: RemoteComposerState(controls: initial, models: [codex], availableAgents: [.claudeCode, .codex]))
        let store = RemoteComposerStore(service: RemoteWorkspaceService(client: transport), sessionID: SessionID("original"))
        try await store.load()
        await transport.forkNextSave()
        let selected = try #require(store.state).choices.selecting(codex.id, in: initial)
        let fork = try await store.apply(selected)
        #expect(fork?.id == SessionID("fork"))
        #expect(store.sessionID == SessionID("original") && store.state?.controls == initial)
    }
}

private actor ComposerTransport: RemoteRequesting {
    private let state: RemoteComposerState
    private var shouldFail = false
    private var shouldFork = false
    private var shouldHold = false
    private var heldSave: CheckedContinuation<JSONValue, Never>?
    private var waitingForSave: [CheckedContinuation<Void, Never>] = []
    private(set) var saves: [RemoteCommand] = []
    init(state: RemoteComposerState) { self.state = state }
    func failNextSave() { shouldFail = true }
    func forkNextSave() { shouldFork = true }
    func holdNextSave() { shouldHold = true }
    func waitForHeldSave() async {
        if heldSave != nil { return }
        await withCheckedContinuation { waitingForSave.append($0) }
    }
    func releaseSave() {
        heldSave?.resume(returning: .object(["accepted": .object([:])]))
        heldSave = nil
    }
    func request(_ command: RemoteCommand) async throws -> JSONValue {
        if command.operation["composer"] != nil {
            let state = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(state))
            return .object(["composer": .object(["_0": state])])
        }
        saves.append(command)
        if shouldHold {
            shouldHold = false
            return await withCheckedContinuation { continuation in
                heldSave = continuation
                waitingForSave.forEach { $0.resume() }
                waitingForSave = []
            }
        }
        if shouldFail { shouldFail = false; throw ConnectionFailure("Connection interrupted after sending") }
        if shouldFork {
            shouldFork = false
            return .object(["created": .object(["session": .object([
                "id": .string("fork"), "workspaceID": .string("workspace"), "title": .string("New chat"),
                "model": .string("gpt-test"), "agentKind": .string("codex"), "state": .string("idle")
            ])])])
        }
        return .object(["accepted": .object([:])])
    }
}
