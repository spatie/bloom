import Foundation
import Testing
@testable import BloomCore

/// Telling a denied call apart from a failed one.
///
/// Every payload below is the shape the CLI actually emits, taken off a recorded session: a denial
/// carries a `tool_result_meta` entry with a `non_execution_kind`, and a real failure carries the
/// same `is_error` flag and no entry at all. A wrong answer either way is worse than the bug this
/// separates, so the failing shapes are tested as hard as the denied ones.
@Suite("Tool refusals")
struct ToolRefusalTests {
    // MARK: The protocol's own spellings

    @Test("a rejected call was declined rather than broken")
    func rejected() {
        #expect(ToolRefusal(protocolKind: "user-rejected") == .denied)
        #expect(ToolRefusal(protocolKind: "automode-blocked") == .denied)
    }

    /// The case the remedy was written for, and the one it used to miss.
    ///
    /// A deny rule in a settings file, and a permission mode that refuses a whole class of call,
    /// are both stamped `permission-rule` rather than `user-rejected`. That is what the CLI's own
    /// stamping function does with every decision that was not auto mode's: `user-rejected` when
    /// the verdict came back `ask`, the three `automode-*` spellings when auto mode answered, and
    /// `permission-rule` for everything else. It used to fall through to "This call did not run"
    /// with no way out offered, which is precisely backwards.
    @Test("a call stopped by a permission rule was denied, and says how to get through")
    func permissionRule() {
        #expect(ToolRefusal(protocolKind: "permission-rule") == .denied)
        #expect(ToolRefusal.denied.remedy != nil)
    }

    /// `permission-denied` was matched here for a year and is not a value the CLI can produce.
    /// The whole set is seven strings, read out of the 2.1.238 binary. If a later CLI adds one it
    /// still lands somewhere sensible, which the unknown-kind test covers; what must not happen
    /// again is a spelling nobody checked being treated as though it were live.
    @Test("the invented spelling is not one the CLI can emit")
    func inventedSpelling() {
        #expect(!ToolRefusal.protocolKinds.contains("permission-denied"))
        // It is not special-cased any more, so it reads as any other unrecognised kind.
        #expect(ToolRefusal(protocolKind: "permission-denied") == .notRun)
    }

    @Test("a call caught by the end of a turn was stopped")
    func stopped() {
        #expect(ToolRefusal(protocolKind: "interrupted") == .stopped)
        #expect(ToolRefusal(protocolKind: "cancelled") == .stopped)
    }

    /// Auto mode failing to answer is not somebody declining. There is nothing to widen and no
    /// mode to pick, so these carry no remedy and must never read as a denial.
    @Test("auto mode failing to reach a verdict is not a denial")
    func automodeUnavailable() {
        #expect(ToolRefusal(protocolKind: "automode-unavailable") == .notRun)
        #expect(ToolRefusal(protocolKind: "automode-parsing-error") == .notRun)
    }

    /// Every value the field can hold is accounted for, and none of them reads as a crash.
    @Test("the whole protocol set is classified")
    func wholeSet() {
        #expect(ToolRefusal.protocolKinds.count == 7)
        for kind in ToolRefusal.protocolKinds {
            #expect(ToolRefusal(protocolKind: kind) != nil, "\(kind) was read as a failure")
        }
        let denied = ToolRefusal.protocolKinds.filter { ToolRefusal(protocolKind: $0) == .denied }
        #expect(denied == ["user-rejected", "permission-rule", "automode-blocked"])
    }

    @Test("a kind this version does not know still means the call never ran")
    func unknownKind() {
        #expect(ToolRefusal(protocolKind: "some-future-spelling") == .notRun)
    }

    @Test("no kind is not a refusal")
    func noKind() {
        #expect(ToolRefusal(protocolKind: nil) == nil)
        #expect(ToolRefusal(protocolKind: "") == nil)
    }

    @Test("only a denial offers a way through")
    func remedy() {
        #expect(ToolRefusal.denied.remedy != nil)
        #expect(ToolRefusal.stopped.remedy == nil)
        #expect(ToolRefusal.notRun.remedy == nil)
    }

    // MARK: Summarising a stored payload

    @Test("a denied shell call is a refusal, and keeps what it said")
    func deniedPayload() {
        let summary = ToolResultSummary.decode(payload(
            id: "toolu_01",
            content: "This command requires approval",
            isError: true,
            meta: [("toolu_01", "user-rejected")]
        ))

        #expect(summary.isError)
        #expect(summary.refusal == .denied)
        #expect(summary.reason == "This command requires approval")
    }

    @Test("a tool that ran and failed is still a failure")
    func failedPayload() {
        let summary = ToolResultSummary.decode(payload(
            id: "toolu_02",
            content: "Exit code 2\n\n  FAILED  Tests\\CompanyWebsiteUrlTest",
            isError: true,
            meta: []
        ))

        #expect(summary.isError)
        #expect(summary.refusal == nil)
        #expect(summary.reason.isEmpty)
    }

    @Test("a failure whose text reads like a denial is still a failure")
    func failureThatTalksAboutPermission() {
        let summary = ToolResultSummary.decode(payload(
            id: "toolu_03",
            content: "cp: /etc/hosts: Permission denied\nThis command requires approval from root",
            isError: true,
            meta: []
        ))

        #expect(summary.refusal == nil)
    }

    @Test("a call that worked is neither")
    func successPayload() {
        let summary = ToolResultSummary.decode(payload(
            id: "toolu_04",
            content: "total 0",
            isError: false,
            meta: []
        ))

        #expect(!summary.isError)
        #expect(summary.refusal == nil)
    }

    @Test("meta belonging to another call is not read onto this one")
    func metaForAnotherCall() {
        let summary = ToolResultSummary.decode(payload(
            id: "toolu_05",
            content: "Exit code 1",
            isError: true,
            meta: [("toolu_99", "user-rejected")]
        ))

        #expect(summary.refusal == nil)
    }

    @Test("a refusal reason is cut to one line")
    func reasonIsOneLine() {
        let summary = ToolResultSummary.decode(payload(
            id: "toolu_06",
            content: "This Bash command contains multiple operations.\nThe following part requires approval: bin/test",
            isError: true,
            meta: [("toolu_06", "user-rejected")]
        ))

        #expect(summary.reason == "This Bash command contains multiple operations.")
    }

    @Test("nonsense decodes to nothing rather than to an error")
    func garbage() {
        #expect(ToolResultSummary.decode(Data("not json".utf8)) == ToolResultSummary())
    }

    // MARK: Through the event decoder

    @Test("the decoded event carries the refusal")
    func decodedEvent() {
        let line = String(decoding: payload(
            id: "toolu_07",
            content: "Claude requested permissions to use Bash, but you haven't granted it yet.",
            isError: true,
            meta: [("toolu_07", "user-rejected")]
        ), as: UTF8.self)

        guard case .toolResult(let result)? = AgentEvent.decode(line: line) else {
            Issue.record("expected a tool result")
            return
        }

        #expect(result.isError)
        #expect(result.refusal == .denied)
    }

    @Test("the decoded event leaves a real failure alone")
    func decodedFailure() {
        let line = String(decoding: payload(
            id: "toolu_08",
            content: "Exit code 127: command not found",
            isError: true,
            meta: []
        ), as: UTF8.self)

        guard case .toolResult(let result)? = AgentEvent.decode(line: line) else {
            Issue.record("expected a tool result")
            return
        }

        #expect(result.isError)
        #expect(result.refusal == nil)
    }

    // MARK: Fixtures

    /// The `user` event a tool result arrives in, written the way the CLI writes it.
    private func payload(
        id: String,
        content: String,
        isError: Bool,
        meta: [(id: String, kind: String)]
    ) -> Data {
        var object: [String: Any] = [
            "type": "user",
            "message": [
                "role": "user",
                "content": [[
                    "type": "tool_result",
                    "content": content,
                    "is_error": isError,
                    "tool_use_id": id,
                ]],
            ],
            "session_id": "session",
            "uuid": "uuid",
        ]
        if !meta.isEmpty {
            object["tool_result_meta"] = meta.map { ["id": $0.id, "non_execution_kind": $0.kind] }
        }
        return try! JSONSerialization.data(withJSONObject: object)
    }
}
