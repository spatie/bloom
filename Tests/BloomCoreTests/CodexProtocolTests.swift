import Testing
import Foundation
@testable import BloomCore

// MARK: - Recorded payloads

/// Every payload in this file was recorded off a real `codex app-server` (codex-cli 0.147.0)
/// driven over stdio, not written by hand. Three sessions were captured:
///
///   * `codex-turn.ndjson`, a whole turn from handshake to `turn/completed`.
///   * `codex-approval.ndjson`, a turn that asked to write a file, was refused, and carried on.
///   * `codex-interrupt.ndjson`, a turn stopped with `turn/interrupt`.
///
/// Invented payloads would have missed the two things that actually broke a first attempt at this
/// client: the frames carry no `jsonrpc` member at all, and the server numbers its own requests
/// from zero, in a namespace of its own.
private func codexFixture(_ name: String) throws -> [String] {
    try bloomFixtureLines(name)
}

private func codexFixtureJSON(_ name: String) throws -> JSONValue {
    let text = try bloomFixtureLines(name).joined(separator: "\n")
    return try #require(JSONValue.parse(text))
}

private func frames(_ name: String) throws -> [CodexFrame] {
    try codexFixture(name).compactMap { CodexFrame.decode(line: $0) }
}

private func notifications(_ name: String) throws -> [CodexServerNotification] {
    try frames(name).compactMap {
        if case .notification(let notification) = $0 { return notification }
        return nil
    }
}

private func events(_ name: String) throws -> [CodexEvent] {
    try notifications(name).map(CodexEvent.decode)
}

// MARK: - Frames

@Suite struct CodexFrameTests {
    @Test func classifiesEveryFrameInARecordedTurn() throws {
        let decoded = try frames("codex-turn.ndjson")

        var responses = 0, notificationCount = 0, requests = 0, malformed = 0
        for frame in decoded {
            switch frame {
            case .response: responses += 1
            case .failure: malformed += 1
            case .request: requests += 1
            case .notification: notificationCount += 1
            case .malformed: malformed += 1
            }
        }

        #expect(decoded.count == 21)
        // initialize, thread/start, turn/start.
        #expect(responses == 3)
        #expect(notificationCount == 18)
        #expect(requests == 0)
        #expect(malformed == 0)
    }

    /// The generated schema has no `jsonrpc` member on any of the four message types, and the real
    /// server sends none. A decoder that insisted on one would drop every line here.
    @Test func recordedFramesCarryNoJSONRPCMember() throws {
        for line in try codexFixture("codex-turn.ndjson") {
            let json = try #require(JSONValue.parse(line))
            #expect(json["jsonrpc"] == nil)
        }
    }

    /// A server request is `id` plus `method`. Its id is the server's own numbering and starts at
    /// zero, which is a perfectly good id for one of ours too, so nothing may classify by id.
    @Test func readsAServerRequestOutOfTheApprovalRecording() throws {
        let requests = try frames("codex-approval.ndjson").compactMap { frame -> CodexServerRequest? in
            if case .request(let request) = frame { return request }
            return nil
        }

        #expect(requests.count == 1)
        let request = try #require(requests.first)
        #expect(request.method == "item/fileChange/requestApproval")
        #expect(request.id == .number(0))
        #expect(request.params["itemId"]?.stringValue?.hasPrefix("exec-") == true)
    }

    @Test func readsAFailureResponse() throws {
        let line = """
        {"error":{"code":-32600,"message":"Invalid request: missing field `turnId`"},"id":4}
        """
        guard case .failure(let id, let error, _) = try #require(CodexFrame.decode(line: line)) else {
            Issue.record("expected a failure frame")
            return
        }
        #expect(id == .number(4))
        #expect(error.code == -32600)
        #expect(error.message.contains("turnId"))
    }

    /// A result of JSON null is a success, not a missing member. `turn/interrupt` answers `{}`,
    /// and a method that answered null would otherwise be read as malformed.
    @Test func aNullResultIsStillAResponse() throws {
        guard case .response(_, let result, _) = try #require(CodexFrame.decode(line: #"{"id":1,"result":null}"#)) else {
            Issue.record("expected a response frame")
            return
        }
        #expect(result.isNull)
    }

    @Test func nonJSONSurvivesAsMalformedRatherThanEndingTheSession() {
        #expect(CodexFrame.decode(line: "") == nil)
        #expect(CodexFrame.decode(line: "   ") == nil)
        if case .malformed = CodexFrame.decode(line: "warning: something") {} else {
            Issue.record("expected malformed")
        }
        if case .malformed = CodexFrame.decode(line: "[1,2,3]") {} else {
            Issue.record("expected malformed for a non-object document")
        }
    }

    @Test func buildsOutgoingFramesThatAreOneLine() {
        let request = CodexOutgoing.request(
            id: .number(7),
            method: "turn/start",
            params: .object(["threadId": .string("t")])
        )
        #expect(!request.contains("\n"))
        #expect(request.contains("\"id\":7"))
        #expect(request.contains("\"method\":\"turn/start\""))

        let answer = CodexOutgoing.response(id: .number(0), result: .object(["decision": .string("decline")]))
        #expect(answer == #"{"jsonrpc":"2.0","id":0,"result":{"decision":"decline"}}"#)

        let notification = CodexOutgoing.notification(method: "initialized", params: nil)
        #expect(notification == #"{"jsonrpc":"2.0","method":"initialized"}"#)
    }

    /// `sandbox: null` is not the same request as no `sandbox`, and the server rejects the first.
    @Test func omittedParametersAreLeftOutRatherThanSentAsNull() {
        let params = JSONValue.object(omittingNil: [
            "cwd": .string("/tmp"),
            "model": nil,
            "sandbox": nil,
        ])
        #expect(params.objectValue?.count == 1)
        #expect(params.compactJSON == #"{"cwd":"/tmp"}"#)
    }

    @Test func stringAndNumberIDsBothRoundTrip() {
        #expect(CodexRequestID.number(12).jsonLiteral == "12")
        #expect(CodexRequestID.text("abc").jsonLiteral == "\"abc\"")
    }
}

// MARK: - Events

@Suite struct CodexEventTests {
    @Test func readsAWholeTurnOffTheRecording() throws {
        let decoded = try events("codex-turn.ndjson")

        var deltas: [String] = []
        var completedItems: [CodexItem] = []
        var finishedTurn: CodexTurn?
        var usage: CodexTokenUsage?
        var statuses: [CodexThreadStatus.State] = []
        var unknownMethods: [String] = []

        for event in decoded {
            switch event {
            case .agentMessageDelta(let delta): deltas.append(delta.text)
            case .itemCompleted(let item): completedItems.append(item.item)
            case .turnCompleted(let turn): finishedTurn = turn
            case .tokenUsage(let value): usage = value
            case .threadStatus(let status): statuses.append(status.state)
            case .unknown(let method, _): unknownMethods.append(method)
            default: break
            }
        }

        // The reply arrived in two deltas and the finished item carries the same text, which is
        // the whole reason deltas are drawn and never stored.
        #expect(deltas.joined() == "bloom")
        #expect(completedItems.count == 2)
        guard case .agentMessage(let message) = completedItems.last else {
            Issue.record("expected the last completed item to be an agent message")
            return
        }
        #expect(message.text == "bloom")
        #expect(message.phase == .finalAnswer)

        let turn = try #require(finishedTurn)
        #expect(turn.status == .completed)
        #expect(turn.succeeded)
        #expect(turn.durationMS ?? 0 > 0)

        let tokens = try #require(usage)
        #expect(tokens.totalTokens == 16165)
        #expect(tokens.outputTokens == 6)
        #expect(tokens.cachedInputTokens == 11008)

        #expect(statuses == [.active, .idle])
        // The methods Bloom does not lift out are still seen, with their names, rather than lost.
        #expect(unknownMethods.contains("mcpServer/startupStatus/updated"))
    }

    @Test func readsTheLatestRequestRatherThanTheCumulativeThreadUsage() throws {
        let usage = try #require(events("codex-approval.ndjson").compactMap {
            if case .tokenUsage(let value) = $0 { return value }
            return nil
        }.first)

        #expect(usage.inputTokens == 16_615)
        #expect(usage.totalTokens == 16_620)
        #expect(usage.contextWindow == 258_400)
    }

    @Test func readsTheUserMessageItem() throws {
        let started = try events("codex-turn.ndjson").compactMap { event -> CodexItem? in
            if case .itemStarted(let item) = event { return item.item }
            return nil
        }
        guard case .userMessage(let message) = started.first else {
            Issue.record("expected a user message first")
            return
        }
        #expect(message.text == "Reply with exactly one word: bloom")
        #expect(message.imagePaths.isEmpty)
    }

    /// A refused patch. The item carries the diff and the approval request carries only the item
    /// id, so the prompt has to find its diff by joining the two.
    @Test func readsAFileChangeAndTheApprovalThatWasAskedAboutIt() throws {
        let decoded = try frames("codex-approval.ndjson")

        var fileChange: CodexFileChange?
        var approval: CodexApprovalRequest?
        var declinedStatus: CodexRunStatus?

        for frame in decoded {
            switch frame {
            case .request(let request):
                approval = CodexApprovalRequest.decode(request)
            case .notification(let notification):
                if case .itemStarted(let event) = CodexEvent.decode(notification),
                   case .fileChange(let change) = event.item {
                    fileChange = change
                }
                if case .itemCompleted(let event) = CodexEvent.decode(notification),
                   case .fileChange(let change) = event.item {
                    declinedStatus = change.status
                }
            default: break
            }
        }

        let change = try #require(fileChange)
        #expect(change.changes.count == 1)
        let update = try #require(change.changes.first)
        #expect(update.path.hasSuffix("note.txt"))
        #expect(update.diff.contains("hi"))
        #expect(update.kind == .add)

        let request = try #require(approval)
        #expect(request.kind == .fileChange)
        #expect(request.itemID == change.id)
        #expect(!request.threadID.isEmpty)
        #expect(!request.turnID.isEmpty)

        // Refusing left the item declined rather than failed, which is the distinction a row has
        // to draw: nothing went wrong, somebody said no.
        #expect(declinedStatus == .declined)
    }

    /// The one flag that separates "working" from "waiting for you".
    @Test func readsTheWaitingOnApprovalFlag() throws {
        let waiting = try events("codex-approval.ndjson").contains { event in
            if case .threadStatus(let status) = event { return status.isWaitingOnApproval }
            return false
        }
        #expect(waiting)
    }

    @Test func readsAnAgentMessagePhase() throws {
        let phases = try events("codex-approval.ndjson").compactMap { event -> CodexMessagePhase? in
            guard case .itemCompleted(let item) = event, case .agentMessage(let message) = item.item else {
                return nil
            }
            return message.phase
        }
        // The preamble before the patch, then the answer after it was refused.
        #expect(phases == [.commentary, .finalAnswer])
    }

    @Test func readsAnInterruptedTurn() throws {
        let statuses = try events("codex-interrupt.ndjson").compactMap { event -> CodexTurn.Status? in
            if case .turnCompleted(let turn) = event { return turn.status }
            return nil
        }
        #expect(statuses == [.interrupted])
        #expect(statuses.first?.rawValue != CodexTurn.Status.completed.rawValue)
    }

    @Test func deltasAreNotTranscriptRows() {
        let delta = CodexTextDelta(itemID: "i", threadID: "t", turnID: "u", text: "x")
        #expect(!CodexEvent.agentMessageDelta(delta).isTranscriptRow)
        #expect(!CodexEvent.reasoningDelta(delta).isTranscriptRow)
        #expect(CodexEvent.itemCompleted(CodexItemEvent(
            item: .agentMessage(CodexAgentMessage(id: "i", text: "x")),
            threadID: "t",
            turnID: "u"
        )).isTranscriptRow)
    }

    /// An item type nobody has written a reading for keeps its JSON, so a future release adds a
    /// case rather than losing a row.
    @Test func anUnknownItemTypeKeepsItsPayload() throws {
        let json = try #require(JSONValue.parse(#"{"type":"quantumFoo","id":"x","weight":3}"#))
        let item = try #require(CodexItem.decode(json))
        #expect(item.typeName == "quantumFoo")
        #expect(item.id == "x")
        guard case .other(_, _, let payload) = item else {
            Issue.record("expected .other")
            return
        }
        #expect(payload["weight"]?.intValue == 3)
    }

    @Test func mapsTokensOntoBloomsOwnUsageWithoutDoubleCountingTheCache() {
        let usage = CodexTokenUsage(
            inputTokens: 16159,
            cachedInputTokens: 11008,
            outputTokens: 6,
            reasoningOutputTokens: 4,
            totalTokens: 16165,
            contextWindow: 272_000
        )
        let mapped = usage.agentUsage
        #expect(mapped.inputTokens == 16159)
        #expect(mapped.contextUsedTokens == 16159)
        #expect(mapped.thinkingTokens == 4)
        #expect(mapped.contextTokens == 272_000)
        // Tokens only. There is no price anywhere on this protocol.
        #expect(mapped.costUSD == 0)
    }

    @Test func spellsEachApprovalDecisionTheWayItsOwnResponseSchemaDoes() {
        let decline = CodexApprovalDecision.decline
        #expect(decline.result(for: .commandExecution).compactJSON == #"{"decision":"decline"}"#)
        #expect(decline.result(for: .fileChange).compactJSON == #"{"decision":"decline"}"#)
        #expect(decline.result(for: .mcpElicitation).compactJSON == #"{"action":"decline"}"#)
        // The elicitation vocabulary has no session-wide accept, so it degrades to a plain one.
        #expect(CodexApprovalDecision.acceptForSession.result(for: .mcpElicitation)
            .compactJSON == #"{"action":"accept"}"#)
    }
}

// MARK: - Models

@Suite struct CodexModelTests {
    @Test func readsTheRecordedModelList() throws {
        let models = CodexModel.decodeList(try codexFixtureJSON("codex-model-list.json"))
        #expect(models.map(\.id) == [
            "gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna", "gpt-5.5", "gpt-5.2",
        ])
        #expect(models.filter(\.isDefault).map(\.id) == ["gpt-5.6-sol"])
        #expect(models.filter(\.hidden).isEmpty)
    }

    /// The reason the effort picker cannot be a flat list. Three of these five take a different
    /// set from the five Bloom hardcodes today.
    @Test func everyModelBringsItsOwnEfforts() throws {
        let models = CodexModel.decodeList(try codexFixtureJSON("codex-model-list.json"))
        let byID = Dictionary(uniqueKeysWithValues: models.map { ($0.id, $0) })

        #expect(byID["gpt-5.6-sol"]?.effortIDs == ["low", "medium", "high", "xhigh", "max", "ultra"])
        #expect(byID["gpt-5.6-luna"]?.effortIDs == ["low", "medium", "high", "xhigh", "max"])
        #expect(byID["gpt-5.5"]?.effortIDs == ["low", "medium", "high", "xhigh"])
        #expect(byID["gpt-5.2"]?.effortIDs == ["low", "medium", "high", "xhigh"])

        // Defaults differ too, so "high" is not a safe fallback for every model.
        #expect(byID["gpt-5.6-sol"]?.defaultEffort == "low")
        #expect(byID["gpt-5.5"]?.defaultEffort == "medium")
    }

    @Test func fallsBackToTheModelsOwnDefaultWhenAnEffortDoesNotApply() throws {
        let models = CodexModel.decodeList(try codexFixtureJSON("codex-model-list.json"))
        let luna = try #require(models.first { $0.id == "gpt-5.6-luna" })
        let five = try #require(models.first { $0.id == "gpt-5.5" })

        #expect(luna.resolvedEffort(preferring: "max") == "max")
        // `ultra` is real on sol and terra and does not exist on luna.
        #expect(luna.resolvedEffort(preferring: "ultra") == "medium")
        #expect(five.resolvedEffort(preferring: "max") == "medium")
    }

    @Test func carriesTheDescriptionTheServerWroteForEachEffort() throws {
        let models = CodexModel.decodeList(try codexFixtureJSON("codex-model-list.json"))
        let sol = try #require(models.first { $0.id == "gpt-5.6-sol" })
        #expect(sol.supportedEfforts.filter { $0.description.isEmpty }.isEmpty)
        #expect(sol.supportedEfforts.first { $0.id == "xhigh" }?.label == "Extra high")
        #expect(sol.supportedEfforts.first { $0.id == "low" }?.label == "Low")
    }

    @Test func readsWhichModelsTakeAnImage() throws {
        let models = CodexModel.decodeList(try codexFixtureJSON("codex-model-list.json"))
        #expect(models.filter(\.acceptsImages).count == models.count)
    }

    // MARK: - A generation that arrived after this code was written

    /// `codex-model-list-astra.json` is the same call answered by codex-cli 0.153.0 on this
    /// machine on 2026-09-05, the day after GPT-6 Astra reached most accounts. The capture above
    /// it is codex-cli 0.147.0 from 2026-08-21, and both are kept, because the pair is the
    /// evidence for the decision `CodexModelCatalog` was written on: a whole generation arrived,
    /// took over as the account default and brought its own reasoning levels, and nothing in
    /// Bloom had to be edited to offer it. A hardcoded list would have missed all of it.
    @Test func readsAGenerationOfModelsNothingHereHadHeardOf() throws {
        let models = CodexModel.decodeList(try codexFixtureJSON("codex-model-list-astra.json"))
        let astra = try #require(models.first { $0.id == "gpt-6-astra" })

        // The name the picker draws is the server's, so a model Bloom has never heard of is still
        // offered under the vendor's own spelling rather than a tidied id.
        #expect(astra.displayName == "GPT-6-Astra")
        #expect(astra.isDefault)
        #expect(astra.acceptsImages)
        // Six levels, which is the set `gpt-5.5` does not have: the flat picker would have hidden
        // `ultra` and `max` from the account's own default model.
        #expect(astra.effortIDs == ["low", "medium", "high", "xhigh", "max", "ultra"])
        // Its own default rather than Bloom's `high`, which is why the model carries one.
        #expect(astra.defaultEffort == "medium")
        #expect(astra.resolvedEffort(preferring: "ultra") == "ultra")
    }

    /// What somebody opening the model menu actually sees: the new generation at the top, and
    /// everything it supersedes underneath in the order the server sent.
    @Test func offersTheNewGenerationAboveEverythingItSupersedes() throws {
        let models = CodexModel.decodeList(try codexFixtureJSON("codex-model-list-astra.json"))
        #expect(CodexModelRank.ordered(models).map(\.id) == [
            "gpt-6-astra",
            "gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna",
            "gpt-5.5", "gpt-5.4-mini", "gpt-5.3-codex-spark",
        ])
    }
}

@Suite struct CodexModelCatalogTests {
    private func catalog(counter: Counter, models: [CodexModel]) -> CodexModelCatalog {
        CodexModelCatalog(fetch: {
            counter.bump()
            try await Task.sleep(for: .milliseconds(20))
            return models
        })
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func bump() { lock.lock(); value += 1; lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    }

    private let sample = [
        CodexModel(id: "b", displayName: "B", supportedEfforts: [CodexReasoningEffort(id: "low")]),
        CodexModel(id: "a", displayName: "A", isDefault: true, supportedEfforts: [
            CodexReasoningEffort(id: "low"), CodexReasoningEffort(id: "high"),
        ]),
        CodexModel(id: "hidden", displayName: "Hidden", hidden: true),
    ]

    @Test func fetchesOnceAndServesTheRestFromTheCache() async throws {
        let counter = Counter()
        let catalog = catalog(counter: counter, models: sample)

        _ = try await catalog.models()
        _ = try await catalog.models()
        _ = try await catalog.models()

        #expect(counter.count == 1)
        #expect(await catalog.fetchCount == 1)
    }

    /// Two callers arriving together join one fetch rather than each starting a subprocess, which
    /// is the same sharing `AgentCatalog` does and for the same reason.
    @Test func callersArrivingTogetherShareOneFetch() async throws {
        let counter = Counter()
        let catalog = catalog(counter: counter, models: sample)

        async let first = catalog.models()
        async let second = catalog.models()
        async let third = catalog.models()
        _ = try await (first, second, third)

        #expect(counter.count == 1)
    }

    @Test func invalidatingMakesTheNextCallFetchAgain() async throws {
        let counter = Counter()
        let catalog = catalog(counter: counter, models: sample)

        _ = try await catalog.models()
        await catalog.invalidate()
        _ = try await catalog.models()

        #expect(counter.count == 2)
    }

    /// The account's default used to be lifted to the top. It is not any more: the list is ordered
    /// by capability now (see `CodexModelRank`), and these three ids name no version, so nothing
    /// distinguishes them and the server's own order is what survives. `a` is the default here and
    /// stays where the server put it, which is the whole of the change.
    @Test func keepsTheServersOrderWhenNothingRanksTheModels() async throws {
        let catalog = catalog(counter: Counter(), models: sample)
        let models = try await catalog.models()
        #expect(models.map(\.id) == ["b", "a", "hidden"])
        let visible = try await catalog.pickerModels()
        #expect(visible.map(\.id) == ["b", "a"])
    }

    @Test func handsBackTheEffortsForOneModel() async throws {
        let catalog = catalog(counter: Counter(), models: sample)
        let known = try await catalog.efforts(for: "a")
        #expect(known.map(\.id) == ["low", "high"])
        // A model nobody knows leaves the session's own effort alone rather than clearing it.
        let unknown = try await catalog.efforts(for: "nope")
        #expect(unknown.isEmpty)
    }
}
