import Testing
import Foundation
@testable import BloomCore

/// `claude-advisor.ndjson` is one real turn on CLI 2.1.322, Sonnet consulting Opus, cut down to
/// the lines that carry the consultation and scrubbed of every identifier.
@Suite("Advisor consultation", .tags(.agentProtocol))
struct AdvisorConsultationTests {
    private func fixtureEvents() throws -> [AgentEvent] {
        try bloomFixtureLines("claude-advisor.ndjson").compactMap { AgentEvent.decode(line: $0) }
    }

    private func resultLine(advice: String) -> String {
        """
        {"type":"assistant","uuid":"u1","session_id":"s1","parent_tool_use_id":null,\
        "message":{"id":"msg_1","role":"assistant","content":[{"type":"advisor_tool_result",\
        "tool_use_id":"srvtoolu_1","content":\(advice)}]}}
        """
    }

    private func resultLine(windows: [String: Int], advisor: String) -> String {
        let modelUsage = windows
            .map { #""\#($0.key)":{"contextWindow":\#($0.value)}"# }
            .joined(separator: ",")
        return """
        {"type":"result","subtype":"success","is_error":false,"modelUsage":{\(modelUsage)},\
        "usage":{"input_tokens":4,"iterations":[{"type":"message"},\
        {"type":"advisor_message","model":"\(advisor)"}]}}
        """
    }

    @Test("a captured consultation is a tool call and the result filed under it")
    func pairsTheCallWithItsResult() throws {
        let events = try fixtureEvents()
        let use = try #require(events.compactMap { event -> AgentToolUse? in
            if case .toolUse(let use) = event { return use }
            return nil
        }.first)
        let result = try #require(events.compactMap { event -> AgentToolResult? in
            if case .toolResult(let result) = event { return result }
            return nil
        }.first)

        #expect(use.name == AdvisorConsultation.toolName)
        #expect(!use.id.isEmpty)
        #expect(result.toolUseID == use.id)
        #expect(result.text == AdvisorConsultation.encryptedNotice)
        #expect(!result.isError)
    }

    @Test("both lines are stored as kinds the transcript already draws")
    func storesAsToolRows() throws {
        let kinds = try fixtureEvents().filter(\.isTranscriptRow).map(\.kind)

        #expect(kinds.contains(.toolUse))
        #expect(kinds.contains(.toolResult))
    }

    @Test("advice an advisor returns in the clear is shown as it was written")
    func readsPlainAdvice() throws {
        let line = resultLine(advice: #"{"type":"advisor_result","text":"Use SQLite."}"#)
        guard case .toolResult(let result)? = AgentEvent.decode(line: line) else {
            Issue.record("expected a tool result")
            return
        }

        #expect(result.text == "Use SQLite.")
        #expect(result.toolUseID == "srvtoolu_1")
        #expect(!result.isError)
    }

    @Test("a failed consultation is an error that names its code")
    func readsAFailedConsultation() throws {
        let line = resultLine(
            advice: #"{"type":"advisor_tool_result_error","error_code":"overloaded"}"#
        )
        guard case .toolResult(let result)? = AgentEvent.decode(line: line) else {
            Issue.record("expected a tool result")
            return
        }

        #expect(result.isError)
        #expect(result.text == "Advisor unavailable (overloaded)")
        #expect(ToolResultSummary.decode(Data(line.utf8)).isError)
        #expect(ToolResultSummary.decode(Data(line.utf8)).refusal == nil)
    }

    @Test("a server tool that is not the advisor stays unknown")
    func leavesOtherServerToolsAlone() {
        let line = """
        {"type":"assistant","uuid":"u1","session_id":"s1",\
        "message":{"id":"msg_1","role":"assistant","content":[{"type":"server_tool_use",\
        "id":"srvtoolu_2","name":"web_search","input":{}}]}}
        """
        guard case .unknown? = AgentEvent.decode(line: line) else {
            Issue.record("expected unknown")
            return
        }
    }

    @Test("the advisor's larger window is not the chat's")
    func ignoresTheAdvisorWindow() throws {
        let line = resultLine(
            windows: ["claude-haiku-5-5": 200_000, "claude-opus-5-5": 1_000_000],
            advisor: "claude-opus-5-5"
        )
        guard case .result(let result)? = AgentEvent.decode(line: line) else {
            Issue.record("expected a result")
            return
        }

        #expect(result.usage.contextTokens == 200_000)
    }

    @Test("a model advising itself still reports its window")
    func keepsAModelAdvisingItself() throws {
        let line = resultLine(windows: ["claude-opus-5-5": 1_000_000], advisor: "claude-opus-5-5")
        guard case .result(let result)? = AgentEvent.decode(line: line) else {
            Issue.record("expected a result")
            return
        }

        #expect(result.usage.contextTokens == 1_000_000)
    }

    @Test("the captured result reports the chat model's window")
    func readsTheCapturedWindow() throws {
        let result = try #require(try fixtureEvents().compactMap { event -> AgentResult? in
            if case .result(let result) = event { return result }
            return nil
        }.first)

        #expect(result.usage.contextTokens == 1_000_000)
        #expect(result.succeeded)
    }

    @Test("the row reads as the advisor rather than as an unknown tool")
    func presentsTheAdvisor() {
        let presentation = ToolPresenter.present(name: AdvisorConsultation.toolName, input: .object([:]))

        #expect(presentation.label == "Advisor")
        #expect(presentation.detail.isEmpty)
    }

    @Test("the line closing the message says who advised and how much it read")
    func readsTheAdvisorUsage() throws {
        let lines = try bloomFixtureLines("claude-advisor.ndjson")
        let report = try #require(lines.compactMap {
            AdvisorConsultation.usageReport(in: Data($0.utf8))
        }.first)
        let usage = try #require(report.usages.first)

        #expect(report.usages.count == 1)
        #expect(usage.model == "claude-opus-5-5")
        #expect(usage.readTokens == 41_514)
        #expect(usage.writtenTokens == 774)
        #expect(usage.summary(locale: Locale(identifier: "en_GB")) == "Opus 5.5 · 41.5k tokens read · 774 written")
    }

    /// What pairs the figures with their row: on a turn that works on after the advice, the
    /// result no longer lists the consultation and only the message's own line does.
    @Test("the usage is filed under the message that consulted")
    func filesUsageUnderItsMessage() throws {
        let lines = try bloomFixtureLines("claude-advisor.ndjson")
        let report = try #require(lines.compactMap {
            AdvisorConsultation.usageReport(in: Data($0.utf8))
        }.first)
        let callMessageIDs = lines.compactMap {
            AdvisorConsultation.callMessageID(payload: Data($0.utf8))
        }

        #expect(callMessageIDs == [report.messageID])
    }

    @Test("a turn's result is not read for advisor usage")
    func ignoresTheResultLine() throws {
        let result = try #require(try bloomFixtureLines("claude-advisor.ndjson").last)

        #expect(AdvisorConsultation.usageReport(in: Data(result.utf8)) == nil)
    }

    @Test("a message that consulted nobody reports no advisor usage")
    func readsNoUsageWithoutAConsultation() {
        let line = """
        {"type":"stream_event","api_message_id":"msg_1","event":{"type":"message_delta",\
        "usage":{"input_tokens":4,"iterations":[{"type":"message"}]}}}
        """

        #expect(AdvisorConsultation.usageReport(in: Data(line.utf8)) == nil)
    }

    @Test("an ordinary tool call is not a consultation")
    func leavesOrdinaryCallsAlone() {
        let line = """
        {"type":"assistant","uuid":"u1","session_id":"s1","message":{"id":"msg_1",\
        "content":[{"type":"tool_use","id":"toolu_1","name":"Bash","input":{"command":"ls"}}]}}
        """

        #expect(AdvisorConsultation.callMessageID(payload: Data(line.utf8)) == nil)
    }

    @Test("the stream names a consultation as it starts, so the live tail can say so")
    func streamsTheConsultationName() throws {
        let start = try #require(try bloomFixtureLines("claude-advisor.ndjson").first)
        guard case .streamDelta(.toolName(let name))? = AgentEvent.decode(line: start) else {
            Issue.record("expected a streamed tool name")
            return
        }

        #expect(name == AdvisorConsultation.toolName)
    }

    @Test("a subagent files only the advisor's server calls as tool calls")
    func subagentSkipsOtherServerTools() throws {
        let call = try #require(try bloomFixtureLines("claude-advisor.ndjson").dropFirst().first)
        let search = """
        {"type":"assistant","uuid":"u2","session_id":"s1",\
        "message":{"id":"msg_2","role":"assistant","content":[{"type":"server_tool_use",\
        "id":"srvtoolu_2","name":"web_search","input":{}}]}}
        """

        let transcript = SubagentTranscript.parse(call + "\n" + search, sessionID: SessionID("s"))

        #expect(transcript.messages.map(\.kind) == [.toolUse])
    }

    private struct Row {
        let kind: MessageKind
        let payload: Data
    }

    @Test("figures go to the message's latest consultations, and never past the last result")
    func assignsUsageNewestFirst() throws {
        let call = Data(try #require(try bloomFixtureLines("claude-advisor.ndjson").dropFirst().first).utf8)
        let messageID = try #require(AdvisorConsultation.callMessageID(payload: call))
        let usage = AdvisorUsage(model: "claude-opus-5-5", readTokens: 10, writtenTokens: 1)
        let rows = [
            Row(kind: .toolUse, payload: call),
            Row(kind: .result, payload: Data()),
            Row(kind: .toolUse, payload: call),
            Row(kind: .assistantText, payload: Data()),
            Row(kind: .toolUse, payload: call),
        ]

        let assigned = AdvisorUsageReport(messageID: messageID, usages: [usage])
            .assignments(in: rows, kind: \.kind, payload: \.payload)
        let other = AdvisorUsageReport(messageID: "msg_other", usages: [usage])
            .assignments(in: rows, kind: \.kind, payload: \.payload)

        #expect(assigned.map(\.index) == [4])
        #expect(assigned.map(\.usage) == [usage])
        #expect(other.isEmpty)
    }

    @Test("the live tail does not repeat the row's own word")
    func namesTheWaitDifferently() {
        let use = AgentToolUse(id: "srvtoolu_1", name: AdvisorConsultation.toolName, input: .object([:]))

        #expect(RunningTool(name: AdvisorConsultation.toolName).label == "Consulting the advisor")
        #expect(RunningTool(use: use).label == "Consulting the advisor")
    }
}
