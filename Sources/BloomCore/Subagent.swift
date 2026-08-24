import Foundation

// MARK: - The four lines a subagent produces

/// One line of the `claude` stream that is about a subagent rather than about the turn.
///
/// Four shapes, and they are four because the CLI says four different things at four different
/// moments, not because Bloom wanted the variety. Measured off a real 66 line capture in which
/// three subagents spawned (`scratchpad/subagent-probe/capture3.ndjson`):
///
/// - `system/task_started` is the only line carrying identity, so it is the only one that can
///   create a row.
/// - `tool_progress` arrives roughly once a second and names the subagent by its PARENT's
///   `tool_use_id`, never by `task_id`, which is why the roster has to keep the map between them.
/// - `system/task_updated` carries a `patch` of whatever changed, so every field in it is
///   optional by construction.
/// - `system/task_notification` is the only line carrying `output_file`, and it arrives for a
///   failed subagent as readily as for one that worked.
///
/// Nothing here is stored. A subagent lives for seconds and the row it draws is cleared by the
/// next turn, so there is no table and nothing to migrate. See `SubagentRoster`.
public enum SubagentSignal: Sendable, Hashable {
    case started(SubagentStart)
    case progressed(SubagentProgress)
    case patched(SubagentPatch)
    case reported(SubagentReport)

    /// Read one already-parsed line, or return nil if it is not about a subagent.
    ///
    /// Nil rather than a throw for the same reason every decoder in `AgentEvent` returns nil: a
    /// line off a subprocess is never allowed to end a session, and a shape a later CLI invents
    /// has to fall through to `.unknown` with its bytes intact.
    public static func decode(_ json: JSONValue) -> SubagentSignal? {
        switch json["type"]?.stringValue {
        case "tool_progress":
            guard let parent = json["parent_tool_use_id"]?.stringValue else { return nil }
            return .progressed(SubagentProgress(
                parentToolUseID: parent,
                type: json["subagent_type"]?.stringValue ?? "",
                elapsedSeconds: json["elapsed_time_seconds"]?.intValue ?? 0,
                retry: SubagentRetry.decode(json["subagent_retry"])
            ))

        case "system":
            switch json["subtype"]?.stringValue {
            case "task_started":
                guard let id = json["task_id"]?.stringValue, !id.isEmpty else { return nil }
                return .started(SubagentStart(
                    id: SubagentID(id),
                    toolUseID: json["tool_use_id"]?.stringValue ?? "",
                    description: json["description"]?.stringValue ?? "",
                    type: json["subagent_type"]?.stringValue ?? "",
                    isBackgrounded: json["is_backgrounded"]?.boolValue ?? false,
                    spawnDepth: json["spawn_depth"]?.intValue ?? 1,
                    taskType: json["task_type"]?.stringValue ?? "",
                    prompt: json["prompt"]?.stringValue ?? ""
                ))

            case "task_updated":
                guard let id = json["task_id"]?.stringValue, !id.isEmpty else { return nil }
                let patch = json["patch"]
                return .patched(SubagentPatch(
                    id: SubagentID(id),
                    status: patch?["status"]?.stringValue,
                    error: patch?["error"]?.stringValue
                ))

            case "task_notification":
                guard let id = json["task_id"]?.stringValue, !id.isEmpty else { return nil }
                return .reported(SubagentReport(
                    id: SubagentID(id),
                    status: json["status"]?.stringValue ?? "",
                    summary: json["summary"]?.stringValue ?? "",
                    // Absent is a real answer and not a failure: it means there is nothing on
                    // disk to open, and the row says so by refusing the click.
                    outputFile: json["output_file"]?.stringValue
                ))

            default:
                return nil
            }

        default:
            return nil
        }
    }

    /// The subagent this line is about, when the line names one. `tool_progress` never does: it
    /// carries the parent's tool use id, which only the roster can resolve.
    public var subagentID: SubagentID? {
        switch self {
        case .started(let start): start.id
        case .patched(let patch): patch.id
        case .reported(let report): report.id
        case .progressed: nil
        }
    }
}

/// A subagent has been spawned. The only line carrying identity, so the only one that creates.
public struct SubagentStart: Sendable, Hashable {
    public let id: SubagentID
    /// The `tool_use_id` of the Task row in the parent's transcript. Two things hang off it: the
    /// nested transcript rows Bloom already indents behind a hairline, and `tool_progress`, which
    /// names the subagent by this and by nothing else.
    public let toolUseID: String
    public let description: String
    public let type: String
    public let isBackgrounded: Bool
    /// One for a subagent the turn spawned, two for a subagent a subagent spawned, and so on.
    /// Drawn flat past one. See `SubagentRow.indent`.
    public let spawnDepth: Int
    public let taskType: String
    /// The whole prompt the subagent was given. Not drawn in the row, which has 260 points, but
    /// it is the first thing the output pane shows and it is the only account of what was asked.
    public let prompt: String

    public init(
        id: SubagentID,
        toolUseID: String = "",
        description: String = "",
        type: String = "",
        isBackgrounded: Bool = false,
        spawnDepth: Int = 1,
        taskType: String = "",
        prompt: String = ""
    ) {
        self.id = id
        self.toolUseID = toolUseID
        self.description = description
        self.type = type
        self.isBackgrounded = isBackgrounded
        self.spawnDepth = spawnDepth
        self.taskType = taskType
        self.prompt = prompt
    }
}

/// A tick while a subagent is working, named by its parent's tool use id.
public struct SubagentProgress: Sendable, Hashable {
    public let parentToolUseID: String
    public let type: String
    public let elapsedSeconds: Int
    public let retry: SubagentRetry?

    public init(
        parentToolUseID: String,
        type: String = "",
        elapsedSeconds: Int = 0,
        retry: SubagentRetry? = nil
    ) {
        self.parentToolUseID = parentToolUseID
        self.type = type
        self.elapsedSeconds = elapsedSeconds
        self.retry = retry
    }
}

/// The API refusing a subagent's request, and the CLI going round again.
///
/// Parsed and carried to the row here because it is a fact about the subagent, which is this
/// file's subject. **What the row SAYS about it is not written here**: the retry and error
/// surfaces are one piece of work and its words belong together. See `SubagentRetryPhrase`.
public struct SubagentRetry: Sendable, Hashable {
    public let attempt: Int
    public let maxRetries: Int
    public let delayMilliseconds: Int
    /// The HTTP status, 529 for an overloaded API, which is the one this was measured against.
    public let status: Int
    public let category: String

    public init(
        attempt: Int, maxRetries: Int, delayMilliseconds: Int = 0, status: Int = 0,
        category: String = ""
    ) {
        self.attempt = attempt
        self.maxRetries = maxRetries
        self.delayMilliseconds = delayMilliseconds
        self.status = status
        self.category = category
    }

    static func decode(_ json: JSONValue?) -> SubagentRetry? {
        guard let json, let attempt = json["attempt"]?.intValue else { return nil }
        return SubagentRetry(
            attempt: attempt,
            maxRetries: json["max_retries"]?.intValue ?? 0,
            delayMilliseconds: json["retry_delay_ms"]?.intValue ?? 0,
            status: json["error_status"]?.intValue ?? 0,
            category: json["error_category"]?.stringValue ?? ""
        )
    }
}

/// Whatever changed about a subagent. A patch, so every field is optional by construction.
public struct SubagentPatch: Sendable, Hashable {
    public let id: SubagentID
    public let status: String?
    public let error: String?

    public init(id: SubagentID, status: String? = nil, error: String? = nil) {
        self.id = id
        self.status = status
        self.error = error
    }
}

/// The subagent is done, this is the one line it has to say for itself, and this is where its own
/// transcript is on disk.
public struct SubagentReport: Sendable, Hashable {
    public let id: SubagentID
    public let status: String
    public let summary: String
    public let outputFile: String?

    public init(id: SubagentID, status: String, summary: String = "", outputFile: String? = nil) {
        self.id = id
        self.status = status
        self.summary = summary
        self.outputFile = outputFile
    }
}
