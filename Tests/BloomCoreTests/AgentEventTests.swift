import Testing
import Foundation
@testable import BloomCore

private func fixtureLines(_ name: String) throws -> [String] {
    try bloomFixtureLines(name)
}

private struct Tally {
    var initialized = 0
    var assistantText = 0
    var thinking = 0
    var toolUse = 0
    var toolResult = 0
    var streamDelta = 0
    var status = 0
    var thinkingTokens = 0
    var hook = 0
    var permissionAsk = 0
    var permissionDecided = 0
    var result = 0
    var rateLimit = 0
    var retrying = 0
    var error = 0
    var subagent = 0
    var unknown = 0

    var total: Int {
        initialized + assistantText + thinking + toolUse + toolResult + streamDelta + status
            + thinkingTokens + hook + permissionAsk + permissionDecided + result + rateLimit
            + retrying + error + subagent + unknown
    }

    mutating func count(_ event: AgentEvent) {
        switch event {
        case .initialized: initialized += 1
        case .assistantText: assistantText += 1
        case .thinking: thinking += 1
        case .toolUse: toolUse += 1
        case .toolResult: toolResult += 1
        case .streamDelta: streamDelta += 1
        case .status: status += 1
        case .thinkingTokens: thinkingTokens += 1
        case .hook: hook += 1
        case .permissionAsk: permissionAsk += 1
        case .permissionDecided: permissionDecided += 1
        case .result: result += 1
        case .rateLimit: rateLimit += 1
        case .retrying: retrying += 1
        case .error: error += 1
        case .subagent: subagent += 1
        case .unknown: unknown += 1
        }
    }
}

private func decodedFixture(sourceLocation: SourceLocation = #_sourceLocation) throws -> [AgentEvent] {
    let lines = try fixtureLines("session-basic.jsonl")
    // Reported against the calling test, so a truncated fixture does not look like a decoder bug
    // in whichever test happened to run first.
    try #require(lines.count == 55, "the captured session changed size", sourceLocation: sourceLocation)
    return lines.compactMap { AgentEvent.decode(line: $0) }
}

@Suite("AgentEvent", .tags(.agentProtocol))
struct AgentEventTests {
    @Test("decodes every line of the captured session")
    func decodesEveryLine() throws {
        let lines = try fixtureLines("session-basic.jsonl")
        let events = lines.compactMap { AgentEvent.decode(line: $0) }
        #expect(events.count == lines.count)

        var tally = Tally()
        for event in events { tally.count(event) }

        #expect(tally.total == 55)
        #expect(tally.initialized == 1)
        #expect(tally.assistantText == 2)
        #expect(tally.thinking == 1)
        #expect(tally.toolUse == 2)
        #expect(tally.toolResult == 2)
        #expect(tally.streamDelta == 24)
        #expect(tally.status == 3)
        #expect(tally.thinkingTokens == 3)
        #expect(tally.hook == 2)
        #expect(tally.result == 1)
        #expect(tally.rateLimit == 1)
        // The captured session ran on a day the API was well. See `AgentRetryTests` for the
        // evening it was not.
        #expect(tally.retrying == 0)
        #expect(tally.error == 0)
        // 3 message_start, 3 message_delta, 3 message_stop, 1 signature_delta and the 3
        // content_block_start events for text and thinking blocks have nothing to render live.
        #expect(tally.unknown == 13)
    }

    @Test("keeps the raw line on every stored event")
    func keepsRawLines() throws {
        for event in try decodedFixture() where event.isTranscriptRow {
            #expect(event.raw.isEmpty == false)
            #expect(JSONValue.parse(event.raw) != nil)
        }
    }

    @Test("splits the stream deltas by what they carry")
    func splitsStreamDeltas() throws {
        var text = 0, thinking = 0, toolName = 0, toolInput = 0, finished = 0
        for event in try decodedFixture() {
            guard case .streamDelta(let delta) = event else { continue }
            switch delta {
            case .text: text += 1
            case .thinking: thinking += 1
            case .toolName: toolName += 1
            case .toolInput: toolInput += 1
            case .blockFinished: finished += 1
            }
        }
        #expect(text == 6)
        #expect(thinking == 3)
        #expect(toolName == 2)
        #expect(toolInput == 8)
        #expect(finished == 5)
    }

    @Test("reads the session binding off the init event")
    func readsInit() throws {
        let events = try decodedFixture()
        guard case .initialized(let info)? = events.first(where: {
            if case .initialized = $0 { return true }
            return false
        }) else {
            Issue.record("no init event")
            return
        }

        #expect(info.sessionID == "f93932c9-cf0b-40d8-881c-ac75db3f8740")
        #expect(info.model == "claude-sonnet-5")
        #expect(info.permissionMode == "bypassPermissions")
        #expect(info.cwd == "/Users/freek/dev/code/Baton/scratch/probe")
        #expect(info.tools.count == 31)
        #expect(info.tools.contains("Read"))
        #expect(info.tools.contains("Write"))
        #expect(info.tools.contains("Bash"))
        #expect(info.slashCommands.count == 83)
        #expect(info.agents.count == 7)
        #expect(info.version == "2.1.234")
    }

    @Test("pulls name, id and input off the real tool calls")
    func readsToolUse() throws {
        let uses: [AgentToolUse] = try decodedFixture().compactMap {
            if case .toolUse(let use) = $0 { return use }
            return nil
        }
        #expect(uses.count == 2)

        #expect(uses[0].name == "Read")
        #expect(uses[0].id == "toolu_01PpKZErcdXrhaSWzLBno4Ra")
        #expect(uses[0].input["file_path"]?.stringValue == "/Users/freek/dev/code/Baton/scratch/probe/notes.txt")
        #expect(uses[0].filePath?.hasSuffix("notes.txt") == true)
        #expect(uses[0].parentToolUseID == nil)

        #expect(uses[1].name == "Write")
        #expect(uses[1].id == "toolu_01TWLhjSjYuicXQJSDpTGa2V")
        #expect(uses[1].input["content"]?.stringValue == "BATON")
        #expect(uses[1].input["nope"] == nil)
        #expect(uses[1].input.prettyPrinted.contains("\"content\""))
    }

    @Test("pairs every tool result with the call that made it")
    func pairsToolResults() throws {
        let events = try decodedFixture()
        let useIDs = events.compactMap { event -> String? in
            if case .toolUse(let use) = event { return use.id }
            return nil
        }
        let results: [AgentToolResult] = events.compactMap {
            if case .toolResult(let result) = $0 { return result }
            return nil
        }

        #expect(results.count == 2)
        #expect(results.map(\.toolUseID) == useIDs)
        #expect(results[0].text == "1\thello\n2\t")
        #expect(results[0].isError == false)
        #expect(results[0].hasImages == false)
        #expect(results[1].text.hasPrefix("File created successfully at:"))
        // A call is immediately followed by its result, so the ref ids come out in pairs.
        #expect(events.compactMap(\.refID) == [useIDs[0], useIDs[0], useIDs[1], useIDs[1]])
    }

    @Test("reads a tool result whose content is a bare string")
    func readsStringToolResult() throws {
        let line = """
        {"type":"user","uuid":"u1","session_id":"s1","parent_tool_use_id":null,\
        "message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_x",\
        "content":"plain text","is_error":true}]}}
        """
        guard case .toolResult(let result)? = AgentEvent.decode(line: line) else {
            Issue.record("expected a tool result")
            return
        }
        #expect(result.toolUseID == "toolu_x")
        #expect(result.text == "plain text")
        #expect(result.isError)
        #expect(result.hasImages == false)
    }

    @Test("reads a tool result whose content is an array of blocks")
    func readsBlockToolResult() throws {
        let line = """
        {"type":"user","uuid":"u2","session_id":"s1","parent_tool_use_id":"toolu_parent",\
        "message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_y",\
        "content":[{"type":"text","text":"first"},\
        {"type":"image","source":{"type":"base64","media_type":"image/png","data":"AAAA"}},\
        {"type":"text","text":"second"}]}]}}
        """
        guard case .toolResult(let result)? = AgentEvent.decode(line: line) else {
            Issue.record("expected a tool result")
            return
        }
        #expect(result.text == "first\nsecond")
        #expect(result.hasImages)
        #expect(result.isError == false)
        #expect(result.parentToolUseID == "toolu_parent")
    }

    @Test("treats an empty tool result as empty text rather than nothing")
    func readsEmptyToolResult() {
        let line = """
        {"type":"user","message":{"role":"user","content":[{"type":"tool_result",\
        "tool_use_id":"toolu_z"}]}}
        """
        guard case .toolResult(let result)? = AgentEvent.decode(line: line) else {
            Issue.record("expected a tool result")
            return
        }
        #expect(result.text.isEmpty)
        #expect(result.toolUseID == "toolu_z")
    }

    @Test("files an unrecognised type as unknown instead of dropping it")
    func handlesUnknownType() {
        let line = #"{"type":"quantum_flux","uuid":"u3","session_id":"s1","payload":{"a":1}}"#
        guard case .unknown(let raw)? = AgentEvent.decode(line: line) else {
            Issue.record("expected unknown")
            return
        }
        #expect(String(decoding: raw, as: UTF8.self) == line)
    }

    @Test("files an unrecognised system subtype as unknown")
    func handlesUnknownSubtype() {
        let line = #"{"type":"system","subtype":"telepathy","uuid":"u4","session_id":"s1"}"#
        let event = AgentEvent.decode(line: line)
        guard case .unknown? = event else {
            Issue.record("expected unknown")
            return
        }
        #expect(event?.kind == .system)
    }

    @Test("files an unrecognised assistant block as unknown")
    func handlesUnknownContentBlock() {
        let line = """
        {"type":"assistant","uuid":"u5","session_id":"s1",\
        "message":{"id":"msg_1","role":"assistant","content":[{"type":"hologram","frames":9}]}}
        """
        guard case .unknown? = AgentEvent.decode(line: line) else {
            Issue.record("expected unknown")
            return
        }
    }

    @Test("skips blank lines and bytes that are not JSON")
    func skipsMalformed() {
        #expect(AgentEvent.decode(line: "") == nil)
        #expect(AgentEvent.decode(line: "   ") == nil)
        #expect(AgentEvent.decode(line: "\t\n ") == nil)
        #expect(AgentEvent.decode(line: "{not json") == nil)
        #expect(AgentEvent.decode(line: #"{"type":"result","#) == nil)
        #expect(AgentEvent.decode(line: "<html>500</html>") == nil)
        #expect(AgentEvent.decode(line: "\u{FFFD}\u{0}garbage") == nil)
    }

    @Test("accepts JSON that parses but is not an object")
    func acceptsNonObjectJSON() {
        guard case .unknown? = AgentEvent.decode(line: "[1,2,3]") else {
            Issue.record("expected unknown")
            return
        }
    }

    @Test("survives a line with no type at all")
    func survivesMissingType() {
        guard case .unknown? = AgentEvent.decode(line: #"{"uuid":"u6"}"#) else {
            Issue.record("expected unknown")
            return
        }
    }

    @Test("decodes a two megabyte tool result")
    func decodesGiantLine() throws {
        let body = String(repeating: "abcdefghij", count: 200_000)
        #expect(body.utf8.count == 2_000_000)

        let encoder = JSONEncoder()
        let quoted = String(decoding: try encoder.encode(body), as: UTF8.self)
        let line = """
        {"type":"user","uuid":"big","session_id":"s1","message":{"role":"user",\
        "content":[{"type":"tool_result","tool_use_id":"toolu_big","content":\(quoted)}]}}
        """

        guard case .toolResult(let result)? = AgentEvent.decode(line: line) else {
            Issue.record("expected a tool result")
            return
        }
        #expect(result.text.utf8.count == 2_000_000)
        #expect(result.text == body)
        #expect(result.raw.count >= 2_000_000)
    }

    @Test("reads usage, cost and the context window off the result event")
    func readsResult() throws {
        guard case .result(let result)? = try decodedFixture().last(where: {
            if case .result = $0 { return true }
            return false
        }) else {
            Issue.record("no result event")
            return
        }

        #expect(result.subtype == "success")
        #expect(result.isError == false)
        #expect(result.succeeded)
        #expect(result.summary == "Created out.txt with \"BATON\".")
        #expect(result.durationMS == 7880)
        #expect(result.durationAPIMS == 7851)
        #expect(result.numTurns == 3)
        #expect(result.stopReason == "end_turn")
        #expect(result.terminalReason == "completed")
        #expect(result.permissionDenials == 0)

        #expect(result.usage.inputTokens == 6)
        #expect(result.usage.outputTokens == 360)
        #expect(result.usage.cacheReadTokens == 100_420)
        #expect(result.usage.cacheCreationTokens == 13_928)
        #expect(result.usage.thinkingTokens == 150)
        #expect(abs(result.usage.costUSD - 0.119112) < 0.000001)
        #expect(result.usage.contextTokens == 1_000_000)
        #expect(result.usage.contextUsedTokens == 6 + 100_420 + 13_928)
        #expect(abs(result.usage.contextFraction - 0.114354) < 0.000001)
    }

    @Test("reads the thinner usage on an assistant event")
    func readsAssistantUsage() throws {
        let texts: [AgentTextBlock] = try decodedFixture().compactMap {
            if case .assistantText(let block) = $0 { return block }
            return nil
        }
        #expect(texts.count == 2)
        #expect(texts[0].model == "claude-sonnet-5")
        #expect(texts[0].messageID.hasPrefix("msg_"))
        #expect(texts[0].usage.inputTokens == 2)
        #expect(texts[0].usage.cacheReadTokens == 37_859)
        #expect(texts[0].usage.cacheCreationTokens == 278)
        // Cost and the context window only ever arrive on the result event.
        #expect(texts[0].usage.costUSD == 0)
        #expect(texts[0].usage.contextTokens == 0)
    }

    @Test("reads a thinking block with its signature")
    func readsThinking() throws {
        guard case .thinking(let block)? = try decodedFixture().first(where: {
            if case .thinking = $0 { return true }
            return false
        }) else {
            Issue.record("no thinking event")
            return
        }
        // The capture redacts the thinking body but keeps the signature, which is the half that
        // has to survive a round trip.
        #expect(block.text.isEmpty)
        #expect(block.signature.count == 940)
        #expect(block.messageID.hasPrefix("msg_"))
    }

    @Test("reads the live status and thinking counters")
    func readsCounters() throws {
        let events = try decodedFixture()
        let statuses = events.compactMap { event -> String? in
            if case .status(let value) = event { return value }
            return nil
        }
        let thinking = events.compactMap { event -> Int? in
            if case .thinkingTokens(let value) = event { return value }
            return nil
        }
        #expect(statuses == ["requesting", "requesting", "requesting"])
        #expect(thinking == [50, 150, 177])
    }

    @Test("reads the hook events without touching their payload")
    func readsHooks() throws {
        let hooks: [AgentHook] = try decodedFixture().compactMap {
            if case .hook(let hook) = $0 { return hook }
            return nil
        }
        #expect(hooks.count == 2)
        #expect(hooks.map(\.name) == ["SessionStart:startup", "SessionStart:startup"])
        #expect(hooks[0].started)
        #expect(hooks[1].started == false)
    }

    @Test("maps events onto storage buckets")
    func mapsToMessageKinds() throws {
        let kinds = try decodedFixture().filter(\.isTranscriptRow).map(\.kind)
        #expect(kinds.filter { $0 == .assistantText }.count == 2)
        #expect(kinds.filter { $0 == .thinking }.count == 1)
        #expect(kinds.filter { $0 == .toolUse }.count == 2)
        #expect(kinds.filter { $0 == .toolResult }.count == 2)
        #expect(kinds.filter { $0 == .result }.count == 1)
        #expect(kinds.filter { $0 == .notice }.count == 1)
        #expect(kinds.filter { $0 == .system }.count == 16)
        #expect(AgentEvent.error(AgentError(message: "boom")).kind == .error)
    }

    @Test("carries the session id through every bound event")
    func carriesSessionID() throws {
        let expected = "f93932c9-cf0b-40d8-881c-ac75db3f8740"
        for event in try decodedFixture() {
            guard let sessionID = event.sessionID else { continue }
            #expect(sessionID == expected)
        }
    }

    @Test("marks subagent rows with the tool use that spawned them")
    func marksSubagentRows() {
        let line = """
        {"type":"assistant","uuid":"u7","session_id":"s1","parent_tool_use_id":"toolu_agent",\
        "message":{"id":"msg_2","role":"assistant","model":"m","content":[{"type":"text","text":"hi"}]}}
        """
        let event = AgentEvent.decode(line: line)
        #expect(event?.parentToolUseID == "toolu_agent")
    }
}

@Suite("JSONValue", .tags(.agentProtocol))
struct JSONValueTests {
    @Test("reads through objects and arrays")
    func readsNestedValues() throws {
        let json = try #require(JSONValue.parse("""
        {"file_path":"/tmp/x","count":3,"ratio":0.5,"ok":true,"gone":null,
         "edits":[{"old":"a"},{"old":"b"}]}
        """))

        #expect(json["file_path"]?.stringValue == "/tmp/x")
        #expect(json["count"]?.intValue == 3)
        #expect(json["ratio"]?.doubleValue == 0.5)
        #expect(json["ok"]?.boolValue == true)
        #expect(json["gone"] == nil)
        #expect(json["missing"] == nil)
        #expect(json["edits"]?.arrayValue?.count == 2)
        #expect(json["edits"]?[1]?["old"]?.stringValue == "b")
        #expect(json["edits"]?[9] == nil)
        #expect(json["count"]?.stringValue == nil)
        #expect(json["file_path"]?.intValue == nil)
    }

    @Test("pretty prints back to valid JSON")
    func prettyPrints() throws {
        let json = try #require(JSONValue.parse(#"{"b":2,"a":[1,"two",null,false]}"#))
        let pretty = json.prettyPrinted
        #expect(pretty.contains("\n"))
        #expect(JSONValue.parse(pretty) == json)
    }

    @Test("keeps forward slashes unescaped so paths stay readable")
    func keepsSlashes() throws {
        let json = try #require(JSONValue.parse(#"{"file_path":"/Users/freek/x.swift"}"#))
        #expect(json.prettyPrinted.contains("/Users/freek/x.swift"))
    }

    @Test("returns nil on bytes that are not JSON")
    func rejectsGarbage() {
        #expect(JSONValue.parse("nope") == nil)
        #expect(JSONValue.parse(Data([0xFF, 0xFE, 0x00])) == nil)
    }
}
