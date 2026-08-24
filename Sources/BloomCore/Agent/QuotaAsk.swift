import Foundation

/// When to ask a provider how much of its allowance has gone.
///
/// **The panel used to say "not reported" because Bloom only ever listened.** Both CLIs volunteer
/// a figure on the way out of a turn, and Claude Code volunteers one only once an account is near
/// a warning threshold, so early in a five hour window there was a window, a reset time and no
/// number. Both of them will answer if asked, neither ask costs a turn, and that is what this
/// schedules.
///
/// **Ten minutes, and here is the defence.** The shortest window either provider publishes is five
/// hours, so ten minutes is at most 3.3 percent of the tightest allowance anybody is watching, and
/// the panel draws whole percentages. Under it, an ask is one HTTP call inside the CLI on Claude's
/// side and one on Codex's, made against the same account from however many machines the person
/// is sitting at; a minute long poll would be six times the traffic for a number that cannot have
/// moved enough to redraw. Over it, the menu bar's own severity dot goes stale, and the dot is the
/// part nobody opens anything to read.
///
/// **One asker, never one per session.** Everything here is account wide: two chats on the same
/// login are looking at the same five hour window, and ten workspaces open is ten views of one
/// number. So the ask belongs to the app, once, and it deliberately takes no session, no workspace
/// and no runner as input. There is no path from a transcript into it.
public enum QuotaPollSchedule {
    /// The background interval, in seconds.
    public static let interval: TimeInterval = 600

    /// The floor under an ask made because somebody is about to look.
    ///
    /// Opening the menu is a reason to refresh and it is also something a person does four times
    /// in a minute while they think about something else. Two minutes is short enough that a menu
    /// opened after a turn shows that turn's figures and long enough that the menu cannot be used
    /// as a button that hammers an endpoint.
    public static let onDemandFloor: TimeInterval = 120

    /// Whether an ask is due, given when the last one went out.
    ///
    /// Never having asked is always due. `after` is the gap being applied: `interval` for the
    /// background poll, `onDemandFloor` for one prompted by the menu opening.
    public static func isDue(lastAskedAt: Date?, at now: Date, after gap: TimeInterval) -> Bool {
        guard let lastAskedAt else { return true }
        return now.timeIntervalSince(lastAskedAt) >= gap
    }
}

/// One provider Bloom can ask about its own allowance.
///
/// **This is the seam a third provider is added at, and it is the twin of `AgentQuotaAdapter`.**
/// That protocol reads a payload a provider volunteered; this one goes and gets a payload. A
/// provider that publishes nothing has neither, contributes nothing, and is not an error.
///
/// The contract has one hard rule and it is the whole reason the feature is worth having: **asking
/// must not cost a turn.** Both implementations below were run against the real binaries before
/// they were written, and both answer out of a control channel that never reaches a model. Anything
/// added here has to be measured the same way, not assumed.
public protocol AgentQuotaSource: Sendable {
    static var provider: AgentKind { get }

    /// The provider's own answer, in whatever shape it answers in, or nothing when it could not be
    /// asked. The result is handed to `AgentQuotaAdapters` rather than decoded here, so one shape
    /// of payload has one reader whether it was volunteered or requested.
    func read() async -> Data?
}

/// Claude Code, over a `control_request` of subtype `get_usage`.
///
/// Measured against 2.1.241 on 23 August 2026. The request is one line:
///
/// ```json
/// {"type":"control_request","request_id":"bloom-usage-1","request":{"subtype":"get_usage"}}
/// ```
///
/// and the answer came back in 0.39 seconds, before the CLI had printed its own `system/init`:
///
/// ```json
/// {"type":"control_response","response":{"subtype":"success","request_id":"bloom-usage-1",
///  "response":{"session":{"total_cost_usd":0,"total_api_duration_ms":0,...},
///  "subscription_type":null,"rate_limits_available":false,"rate_limits":null,"behaviors":null}}}
/// ```
///
/// `total_cost_usd` and `total_api_duration_ms` are zero in that answer, and they are the proof
/// the rule above is kept: the CLI answered without starting a turn, without calling a model and
/// without spending anything. The CLI's own description of the subtype is "Requests the structured
/// /usage data ... Experimental, the response shape may change", which is why this is polled on a
/// schedule rather than fired per event and why the reader treats every field as optional.
///
/// **It spawns its own process rather than borrowing a session's.** The obvious route was the
/// stdin Bloom already holds open for a running chat, and it works, but it is the wrong one. It
/// answers only while a chat happens to be mid turn, so the panel would be blank exactly when
/// nobody is running anything, which is when a person checks whether they can afford to start. It
/// also puts a write on a pipe that belongs to somebody's conversation, for a menu. A dedicated
/// process costs 0.39 seconds every ten minutes, is the same code path whether or not anything
/// else is running, and touches no stdin that is not its own.
public struct ClaudeCodeQuotaSource: AgentQuotaSource {
    public static let provider = AgentKind.claudeCode

    /// The smallest invocation the CLI accepts on this transport. `--verbose` is not optional:
    /// the CLI refuses `-p --output-format stream-json` without it, the same as `AgentRunner`.
    /// No model, no permission mode and no settings, because nothing here runs a turn and every
    /// flag that is not sent is a flag that cannot pin something the user chose.
    public static let arguments = [
        "-p",
        "--output-format", "stream-json",
        "--input-format", "stream-json",
        "--verbose",
    ]

    /// The line to write. Pure, so the request can be asserted on without spawning anything.
    public static func request(id: String) -> String {
        let json = JSONValue.object([
            "type": .string("control_request"),
            "request_id": .string(id),
            "request": .object(["subtype": .string("get_usage")]),
        ])
        return encode(json)
    }

    /// One line of JSON, with slashes left alone. `JSONValue` has no encoder of its own and this
    /// is the only place in the file that needs one.
    static func encode(_ value: JSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        guard let data = try? encoder.encode(value) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    /// Whether one output line is the answer to `id`, and the payload if it is.
    ///
    /// The `response.response` unwrap is the CLI's own envelope and not a typo: the outer
    /// `response` is the control channel's result, the inner one is what the handler returned.
    public static func answer(in line: String, to id: String) -> Data? {
        guard let json = JSONValue.parse(Data(line.utf8)),
              json["type"]?.stringValue == "control_response",
              let response = json["response"],
              response["request_id"]?.stringValue == id,
              response["subtype"]?.stringValue == "success",
              let payload = response["response"]
        else { return nil }
        return (try? JSONEncoder().encode(payload)) ?? nil
    }

    private let executable: String
    private let cwd: String
    private let environment: [String: String]
    private let makeProcess: @Sendable (AgentLaunch) -> any AgentProcessing

    public init(
        executable: String = AgentRunner.executable,
        cwd: String = NSHomeDirectory(),
        environment: [String: String] = Shell.environment(),
        makeProcess: @escaping @Sendable (AgentLaunch) -> any AgentProcessing = AgentRunner.spawn
    ) {
        self.executable = executable
        self.cwd = cwd
        self.environment = environment
        self.makeProcess = makeProcess
    }

    public func read() async -> Data? {
        let id = "bloom-usage-\(UUID().uuidString)"
        let process = makeProcess(AgentLaunch(
            executable: executable,
            arguments: Self.arguments,
            cwd: cwd,
            environment: environment
        ))
        // Claimed before the write, because claiming the stream is what starts the child.
        let lines = process.lines
        process.writeLine(Self.request(id: id))

        var answer: Data?
        do {
            for try await line in lines {
                if let payload = Self.answer(in: line, to: id) {
                    answer = payload
                    break
                }
            }
        } catch {
            answer = nil
        }
        // Always, and on every exit from the loop. The child has nothing else to do and nobody is
        // reading its stdin, so leaving it would leak a process per poll.
        process.terminate()
        return answer
    }
}

/// Codex, over `account/rateLimits/read`.
///
/// Measured against codex-cli 0.147.0 on 23 August 2026, on a connection that had done nothing but
/// `initialize` and `initialized`, with `experimentalApi` off:
///
/// ```json
/// {"id":2,"result":{"rateLimits":{"limitId":"codex","limitName":null,
///  "primary":{"usedPercent":0,"windowDurationMins":10080,"resetsAt":1787986128},
///  "secondary":null,"credits":{"hasCredits":false,"unlimited":false,"balance":"0"},
///  "individualLimit":null,"spendControlReached":false,"planType":"prolite",
///  "rateLimitReachedType":null}, "rateLimitsByLimitId":{...}, "rateLimitResetCredits":{...}}}
/// ```
///
/// Three things that mattered. The method is in the **stable** surface, so it answers without
/// `experimentalApi` and its shape will not move under Bloom. It needs no thread: the connection
/// had started no conversation, so nothing about this can run a model. And `rateLimits` is the
/// same `RateLimitSnapshot` the notification carries, which is why the answer goes through the
/// adapter Bloom already had rather than through a second reader.
///
/// `rateLimitsByLimitId` and `rateLimitResetCredits` are read and deliberately dropped, for the
/// reason `CodexQuotaAdapter` drops `credits`: they are a wallet and a per model breakdown, and
/// this panel answers one question about the nearest wall.
public struct CodexQuotaSource: AgentQuotaSource {
    public static let provider = AgentKind.codex

    public static let method = "account/rateLimits/read"

    private let configuration: CodexClient.Configuration
    private let makeProcess: @Sendable (AgentLaunch) -> any AgentProcessing

    public init(
        cwd: String = NSHomeDirectory(),
        environment: [String: String] = Shell.environment(),
        makeProcess: @escaping @Sendable (AgentLaunch) -> any AgentProcessing = CodexClient.spawn
    ) {
        // No bridge. This connection never starts a thread, so there is nothing for a workspace's
        // MCP server to be offered to, and registering one would put a Bloom tool in front of a
        // process whose whole life is one question.
        configuration = CodexClient.Configuration(cwd: cwd, environment: environment)
        self.makeProcess = makeProcess
    }

    public func read() async -> Data? {
        let client = CodexClient(configuration: configuration, makeProcess: makeProcess)
        defer { Task { await client.stop() } }
        do {
            try await client.start()
            let result = try await client.send(Self.method, params: nil)
            return try JSONEncoder().encode(result)
        } catch {
            return nil
        }
    }
}

/// Every source Bloom has, and the one call the app makes.
///
/// Named and shaped after `AgentQuotaAdapters` on purpose: a provider is added by writing an
/// adapter, writing a source, and adding both to a list. Nothing in the store, the board or the
/// panel knows how many there are.
public enum AgentQuotaSources {
    public static func all() -> [any AgentQuotaSource] {
        [ClaudeCodeQuotaSource(), CodexQuotaSource()]
    }

    /// Asks every provider at once and reads whatever answered.
    ///
    /// Concurrently, because the two are unrelated processes and asking them in turn would make
    /// the slow one decide how fresh the fast one is. A provider that is not installed, not
    /// logged in or simply broken answers nothing and contributes nothing, which is the same
    /// outcome as never having been asked and is why nothing here throws.
    public static func readAll(
        _ sources: [any AgentQuotaSource] = AgentQuotaSources.all(),
        at now: Date = Date()
    ) async -> [AgentQuota] {
        await withTaskGroup(of: [AgentQuota].self) { group in
            for source in sources {
                group.addTask {
                    guard let payload = await source.read() else { return [] }
                    return AgentQuotaAdapters.quotas(fromRateLimitEvent: payload, at: now)
                }
            }
            return await group.reduce(into: []) { $0 += $1 }
        }
    }
}
