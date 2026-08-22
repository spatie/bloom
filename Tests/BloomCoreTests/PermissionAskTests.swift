import Foundation
import Testing
@testable import BloomCore

/// Reading and answering the CLI's permission question.
///
/// Every payload in this file was captured from `claude 2.1.238` driven over
/// `--permission-prompt-tool stdio` in a scratch directory, not written from documentation. The
/// two undocumented fields are asserted here because this is the only record of them: nothing in
/// `--help` mentions the flag, and nothing at all mentions `suppress_always_allow_rule` or
/// `requires_user_interaction`. They were read out of the binary's own schema and are what decides
/// whether Bloom is allowed to draw a button that widens a scope.
@Suite("Permission asks")
struct PermissionAskTests {
    // MARK: Fixtures

    /// Captured verbatim. The agent was told to run `sudo -n true`; the CLI escalated, proposed
    /// the rule that would stop it asking, and blocked until it was answered.
    static let realAsk = """
    {"type":"control_request","request_id":"2f9899b1-849f-4d1b-b4b2-9c6e1304b300",\
    "request":{"subtype":"can_use_tool","tool_name":"Bash","display_name":"Bash",\
    "input":{"command":"sudo -n true","description":"Test sudo access without password"},\
    "description":"Test sudo access without password",\
    "permission_suggestions":[{"type":"addRules","rules":[{"toolName":"Bash",\
    "ruleContent":"sudo -n true"}],"behavior":"allow","destination":"localSettings"}],\
    "decision_reason":"This command requires approval","decision_reason_type":"other",\
    "tool_use_id":"toolu_01AtAvbhP1XGtDNmpbSCSBRf"}}
    """

    static func ask(_ line: String = realAsk) -> PermissionAsk {
        guard case .permissionAsk(let ask) = AgentEvent.decode(line: line) else {
            Issue.record("the line did not decode as a permission ask")
            return PermissionAsk(requestID: "", toolName: "")
        }
        return ask
    }

    static func object(_ text: String) -> JSONValue {
        JSONValue.parse(text) ?? .null
    }

    // MARK: Decoding

    @Test("the sixth event type is no longer dropped")
    func decodesAsAnEvent() {
        guard case .permissionAsk = AgentEvent.decode(line: Self.realAsk) else {
            Issue.record("a control request still decodes as something else")
            return
        }
    }

    @Test("a real ask is read whole")
    func readsTheAsk() {
        let ask = Self.ask()

        #expect(ask.requestID == "2f9899b1-849f-4d1b-b4b2-9c6e1304b300")
        #expect(ask.toolName == "Bash")
        #expect(ask.toolUseID == "toolu_01AtAvbhP1XGtDNmpbSCSBRf")
        #expect(ask.reason == "This command requires approval")
        #expect(ask.reasonType == "other")
        #expect(ask.subject == "sudo -n true")
        #expect(ask.input["command"]?.stringValue == "sudo -n true")
    }

    /// The whole of approach 4 rests on this string being the CLI's rather than Bloom's.
    @Test("the rule that would stop it asking is the CLI's own")
    func carriesTheRule() {
        let ask = Self.ask()

        #expect(ask.rules == [PermissionRule(toolName: "Bash", ruleContent: "sudo -n true")])
        // The exact spelling the CLI itself wrote into settings.local.json during the same run.
        #expect(ask.ruleText == "Bash(sudo -n true)")
        #expect(ask.canWiden)
    }

    @Test("the ask is filed under the call it is about")
    func refersToTheCall() {
        let event = AgentEvent.decode(line: Self.realAsk)

        #expect(event?.refID == "toolu_01AtAvbhP1XGtDNmpbSCSBRf")
        #expect(event?.kind == .permissionAsk)
        #expect(event?.isTranscriptRow == true)
    }

    @Test("an ask survives a round trip through the database")
    func rebuildsFromStoredBytes() {
        let ask = Self.ask()

        #expect(PermissionAsk.decode(payload: ask.raw) == ask)
    }

    // MARK: The two undocumented fields

    /// Read out of the 2.1.238 binary: "True when the dialog must not offer the persistent
    /// 'don't ask again' row for this ask: accepting it would write a whole-tool allow rule
    /// broader than the ask's own verb."
    @Test("a suppressed rule is not offered as a button even though one was suggested")
    func suppressAlwaysAllow() {
        let ask = Self.ask(Self.realAsk.replacingOccurrences(
            of: #""decision_reason_type":"other""#,
            with: #""decision_reason_type":"other","suppress_always_allow_rule":true"#
        ))

        #expect(ask.suppressesAlwaysAllow)
        // The rule is still known, so a row can still say what it would have been.
        #expect(!ask.rules.isEmpty)
        // It just cannot be granted from here.
        #expect(!ask.canWiden)
    }

    /// Also from the binary: "True when one-tap Approve/Deny must not be offered ... Either way
    /// the user has to open the session to answer."
    @Test("an ask needing its own surface offers no widening either")
    func requiresUserInteraction() {
        let ask = Self.ask(Self.realAsk.replacingOccurrences(
            of: #""decision_reason_type":"other""#,
            with: #""decision_reason_type":"other","requires_user_interaction":true"#
        ))

        #expect(ask.requiresUserInteraction)
        #expect(!ask.canWiden)
    }

    // MARK: Refusing to invent a scope

    /// The mockup's third row: a write outside the worktree, for which the CLI offered no rule at
    /// all. Bloom does not compose one to fill the gap.
    @Test("no suggestion means no rule, not a rule Bloom made up")
    func noSuggestion() {
        let ask = Self.ask(Self.realAsk.replacingOccurrences(
            of: #""permission_suggestions":[{"type":"addRules","rules":[{"toolName":"Bash","ruleContent":"sudo -n true"}],"behavior":"allow","destination":"localSettings"}],"#,
            with: ""
        ))

        #expect(ask.rules.isEmpty)
        #expect(ask.ruleText.isEmpty)
        #expect(!ask.canWiden)
        #expect(ask.allowSuggestion == nil)
    }

    /// Two allow suggestions for the ask's own tool, which is the pair that is genuinely
    /// ambiguous: guessing which of them the user meant is how a feature grants something nobody
    /// agreed to. Compare `companionRuleAsk`, where the second suggestion is for a different tool
    /// and the choice needs no guess.
    @Test("two allow suggestions for the same tool means none is chosen")
    func ambiguousSuggestions() {
        let ask = Self.ask(Self.realAsk.replacingOccurrences(
            of: #""behavior":"allow","destination":"localSettings"}]"#,
            with: #""behavior":"allow","destination":"localSettings"},{"type":"addRules","rules":[{"toolName":"Bash","ruleContent":"sudo:*"}],"behavior":"allow","destination":"localSettings"}]"#
        ))

        #expect(ask.suggestions.count == 2)
        #expect(ask.allowSuggestion == nil)
        #expect(!ask.canWiden)
    }

    // MARK: The companion rule

    /// Captured verbatim from `claude 2.1.239`. A Bash command whose subcommands touch paths
    /// outside the working directory arrives with **two** allow suggestions: the Bash rule for
    /// the command family, and a companion `Read` rule for the paths. The CLI's own UI offers
    /// them as separate options; Bloom offers the one the ask is about.
    static let companionRuleAsk = """
    {"type":"control_request","request_id":"b54b23b7-618d-431a-a967-bfd916f2609d",\
    "request":{"subtype":"can_use_tool","tool_name":"Bash","display_name":"Bash",\
    "input":{"command":"gh pr diff 61 > /tmp/pr61.diff && wc -l /tmp/pr61.diff && gh pr checks 61 2>&1 | head -30",\
    "description":"Get PR diff, line count, and check status"},\
    "description":"Get PR diff, line count, and check status",\
    "permission_suggestions":[{"type":"addRules","rules":[{"toolName":"Bash",\
    "ruleContent":"gh pr *"}],"behavior":"allow","destination":"localSettings"},\
    {"type":"addRules","rules":[{"toolName":"Read","ruleContent":"//private/tmp/**"}],\
    "behavior":"allow","destination":"session"}],\
    "decision_reason_type":"subcommandResults",\
    "tool_use_id":"toolu_01E3b8UL6KnXrx6828bX5NR1"}}
    """

    /// The bug this section exists for: both suggestions were dropped as ambiguous, the button
    /// vanished, and the user was asked the same question every turn with no way to say always.
    @Test("a companion Read rule does not cost the ask its button")
    func companionRuleKeepsTheButton() {
        let ask = Self.ask(Self.companionRuleAsk)

        #expect(ask.suggestions.count == 2)
        #expect(ask.rules == [PermissionRule(toolName: "Bash", ruleContent: "gh pr *")])
        #expect(ask.ruleText == "Bash(gh pr *)")
        #expect(ask.canWiden)
    }

    /// The companion widens a tool nobody was asked about, so granting the Bash rule must not
    /// smuggle the Read rule out with it.
    @Test("the companion rule is never sent back")
    func companionRuleIsNotEchoed() throws {
        let ask = Self.ask(Self.companionRuleAsk)
        let answer = try PermissionAnswer.encode(ask: ask, decision: .allow(scope: .session))
        let sent = Self.object(answer)["response"]?["response"]?["updatedPermissions"]

        #expect(sent?.arrayValue?.count == 1)
        #expect(sent?[0]?["rules"]?[0]?["toolName"]?.stringValue == "Bash")
        #expect(sent?[0]?["destination"]?.stringValue == "session")
        #expect(!answer.contains("//private/tmp/**"), "the Read companion went out with the grant")
    }

    @Test("a deny suggestion is never offered as an allow")
    func denySuggestionIsNotAnAllow() {
        let ask = Self.ask(Self.realAsk.replacingOccurrences(
            of: #""behavior":"allow""#,
            with: #""behavior":"deny""#
        ))

        #expect(ask.suggestions.count == 1)
        #expect(ask.allowSuggestion == nil)
    }

    // MARK: Other control requests

    @Test("a control request Bloom has no business answering stays unknown")
    func otherControlSubtype() {
        let line = #"{"type":"control_request","request_id":"x","request":{"subtype":"initialize"}}"#

        guard case .unknown = AgentEvent.decode(line: line) else {
            Issue.record("an unrelated control request was read as a permission ask")
            return
        }
    }

    @Test("the CLI answering Bloom is not a question")
    func controlResponseIsNotAnAsk() {
        let line = #"{"type":"control_response","response":{"subtype":"success","request_id":"x","response":{}}}"#

        guard case .unknown = AgentEvent.decode(line: line) else {
            Issue.record("a control response was read as a permission ask")
            return
        }
    }

    // MARK: Sanitising

    /// The CLI's schema says of `decision_reason`, in as many words: "May carry ANSI escapes;
    /// sanitize before rendering." It is the one string on the ask that came from a tool rather
    /// than from the CLI itself.
    ///
    /// Written the way it arrives on the wire, as the JSON escape rather than as a raw byte: a
    /// bare control character inside a JSON string is not valid JSON and would be rejected before
    /// it ever reached the stripper, which would have made this test pass for the wrong reason.
    @Test("terminal colour codes never reach a row")
    func stripsEscapes() {
        let ask = Self.ask(Self.realAsk.replacingOccurrences(
            of: #""decision_reason":"This command requires approval""#,
            with: #""decision_reason":"\u001b[31mThis command requires approval\u001b[0m""#
        ))

        #expect(ask.reason == "This command requires approval")
    }

    // MARK: Answering

    @Test("allow once sends the input back and grants nothing")
    func allowOnce() throws {
        let ask = Self.ask()
        let answer = try PermissionAnswer.encode(ask: ask, decision: .allow(scope: .once))
        let json = Self.object(answer)

        #expect(json["type"]?.stringValue == "control_response")
        #expect(json["response"]?["subtype"]?.stringValue == "success")
        // Without this the answer answers nothing at all.
        #expect(json["response"]?["request_id"]?.stringValue == ask.requestID)

        let body = json["response"]?["response"]
        #expect(body?["behavior"]?.stringValue == "allow")
        #expect(body?["updatedInput"] == ask.input)
        // The whole meaning of "once".
        #expect(body?["updatedPermissions"] == nil)
    }

    @Test("a wider allow sends the CLI its own suggestion back, aimed at the session")
    func allowForSession() throws {
        let ask = Self.ask()
        let answer = try PermissionAnswer.encode(ask: ask, decision: .allow(scope: .session))
        let sent = Self.object(answer)["response"]?["response"]?["updatedPermissions"]?[0]

        #expect(sent?["type"]?.stringValue == "addRules")
        #expect(sent?["behavior"]?.stringValue == "allow")
        // Rewritten from localSettings, which would have written a file inside the worktree.
        #expect(sent?["destination"]?.stringValue == "session")
        // And the rules themselves are untouched: the destination is the only thing Bloom changes.
        #expect(sent?["rules"] == ask.allowSuggestion?.raw["rules"])
    }

    /// Project scope is Bloom's own bookkeeping. On the wire it is identical to session scope,
    /// because the only thing the live CLI needs to know is "stop asking me this for now". Where
    /// the grant survives to is Bloom's business, and involves no file.
    @Test("project scope writes no settings file")
    func projectScopeTouchesNoFile() throws {
        let ask = Self.ask()
        let answer = try PermissionAnswer.encode(ask: ask, decision: .allow(scope: .project))
        let sent = Self.object(answer)["response"]?["response"]?["updatedPermissions"]?[0]

        #expect(sent?["destination"]?.stringValue == "session")
        for destination in ["localSettings", "projectSettings", "userSettings"] {
            #expect(!answer.contains(destination), "\(destination) would have written a file")
        }
    }

    @Test("a deny carries the sentence and does not end the turn by default")
    func deny() throws {
        let ask = Self.ask()
        let answer = try PermissionAnswer.encode(
            ask: ask,
            decision: .deny(message: "Not this one. Carry on with the rest.", endsTurn: false)
        )
        let body = Self.object(answer)["response"]?["response"]

        #expect(body?["behavior"]?.stringValue == "deny")
        #expect(body?["message"]?.stringValue == "Not this one. Carry on with the rest.")
        #expect(body?["interrupt"]?.boolValue == false)
        #expect(body?["updatedInput"] == nil)
    }

    @Test("deny and stop sets interrupt")
    func denyAndStop() throws {
        let ask = Self.ask()
        let answer = try PermissionAnswer.encode(ask: ask, decision: .deny(message: "No.", endsTurn: true))

        #expect(Self.object(answer)["response"]?["response"]?["interrupt"]?.boolValue == true)
    }

    /// An empty box must not send an empty sentence: the message is handed straight to the model
    /// as the tool result, and "" tells it nothing about what to do instead.
    @Test("an empty deny still says something useful to the model")
    func emptyDeny() throws {
        let ask = Self.ask()
        let answer = try PermissionAnswer.encode(ask: ask, decision: .deny(message: "   ", endsTurn: false))

        #expect(Self.object(answer)["response"]?["response"]?["message"]?.stringValue
            == PermissionDecision.defaultDenyMessage)
    }

    @Test("the answer is one line, because the wire is line delimited")
    func answersAreSingleLines() throws {
        let ask = Self.ask()
        let decisions: [PermissionDecision] = [
            .allow(scope: .once),
            .allow(scope: .session),
            .allow(scope: .project),
            .deny(message: "no\nreally\nno", endsTurn: false),
        ]

        for decision in decisions {
            let answer = try PermissionAnswer.encode(ask: ask, decision: decision)
            #expect(!answer.contains("\n"), "\(decision) encoded to more than one line")
        }
    }

    // MARK: Scope copy

    @Test("every scope says what it costs before it is pressed")
    func scopeCopy() {
        for scope in PermissionScope.allCases {
            #expect(!scope.consequence(rule: "Bash(bin/test:*)", project: "Bloom").isEmpty)
            #expect(!scope.buttonLabel.isEmpty)
        }

        #expect(PermissionScope.project.consequence(rule: "R", project: "Bloom").contains("Bloom"))
        #expect(PermissionScope.session.consequence(rule: "R", project: "Bloom").contains("R"))
    }
}
