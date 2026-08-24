import Foundation

/// One subagent, as much of it as the four lines about it have said so far.
public struct Subagent: Sendable, Hashable, Identifiable {
    public let id: SubagentID
    /// The parent's Task tool_use_id. It is how `tool_progress` finds this row, and it is the
    /// same value the nested transcript rows already carry, so it is also the fallback route to
    /// this subagent's output when there is no file to read.
    public let toolUseID: String
    public let description: String
    public let type: String
    public let spawnDepth: Int
    public let isBackgrounded: Bool
    public let prompt: String
    /// `task_started.task_type` verbatim, which is the one field that says whether this row is an
    /// agent at all. Kept as the word the CLI sent rather than only as the `kind` below, because
    /// the day a third value appears the raw word is the thing that tells us so.
    public let taskType: String
    public private(set) var state: SubagentState = .running
    /// The one line the CLI gave for the ending, empty until it ends.
    public private(set) var summary: String = ""
    /// Where the CLI wrote this subagent's own transcript. Present for a failed subagent as
    /// readily as for one that worked, which was the open question and is now measured: the path
    /// is a symlink into `~/.claude/projects/.../subagents/agent-<task_id>.jsonl` and it holds the
    /// prompt, the answer and the API error.
    public private(set) var outputFile: String?
    public private(set) var elapsedSeconds: Int = 0
    /// The API refusing it, while it is being refused. Cleared by the first tick that does not
    /// carry one, because a retry that succeeded is not a fact about the subagent any more.
    public private(set) var retry: AgentRetry?

    init(_ start: SubagentStart) {
        id = start.id
        toolUseID = start.toolUseID
        description = start.description
        type = start.type
        spawnDepth = start.spawnDepth
        isBackgrounded = start.isBackgrounded
        prompt = start.prompt
        taskType = start.taskType
    }

    /// A subagent built whole, for a gallery or a test that is not replaying a stream.
    public init(
        id: SubagentID,
        toolUseID: String = "",
        description: String = "",
        type: String = "",
        spawnDepth: Int = 1,
        isBackgrounded: Bool = false,
        prompt: String = "",
        taskType: String = "",
        state: SubagentState = .running,
        summary: String = "",
        outputFile: String? = nil,
        elapsedSeconds: Int = 0,
        retry: AgentRetry? = nil
    ) {
        self.id = id
        self.toolUseID = toolUseID
        self.description = description
        self.type = type
        self.spawnDepth = spawnDepth
        self.isBackgrounded = isBackgrounded
        self.prompt = prompt
        self.taskType = taskType
        self.state = state
        self.summary = summary
        self.outputFile = outputFile
        self.elapsedSeconds = elapsedSeconds
        self.retry = retry
    }

    /// An agent, or a shell command the CLI put in the background. Read off `task_type`.
    public var kind: SubagentKind { SubagentKind(taskType: taskType) }

    /// Whether clicking this row can show anything.
    ///
    /// False when the CLI never named a file. It always did for an agent in the capture, and it
    /// routinely does NOT for a background command: `task_notification.output_file` comes through
    /// empty for `local_bash` in the same captures where it is an absolute path for `local_agent`.
    public var hasOutput: Bool { !(outputFile ?? "").isEmpty }

    fileprivate mutating func move(to state: SubagentState) {
        self.state = state
        // A finished subagent stops counting. The last tick before the ending is the honest
        // elapsed time and the row keeps it, but nothing arrives to raise it again and a row
        // that kept ticking would be inventing seconds.
        retry = nil
    }

    fileprivate mutating func note(summary: String) {
        guard !summary.isEmpty else { return }
        self.summary = summary
    }

    fileprivate mutating func note(outputFile: String?) {
        guard let outputFile, !outputFile.isEmpty else { return }
        self.outputFile = outputFile
    }

    fileprivate mutating func tick(_ progress: SubagentProgress) {
        // Never backwards. Ticks for one subagent all carry the same elapsed value for the first
        // second of its life, and a later line reporting a smaller number would make the row
        // count down.
        elapsedSeconds = max(elapsedSeconds, progress.elapsedSeconds)
        retry = progress.retry
    }
}

/// Every subagent this turn has spawned, in the order they were spawned, for the length of the
/// turn and no longer.
///
/// **The clearing rule, which is the whole shape of the thing.** A row appears on `task_started`,
/// stays through its ending carrying a tick or a cross and what it answered, and is removed when
/// the NEXT turn starts. Not when it finishes, which is the option that photographs well and is
/// unusable: three rows that vanish one by one while you are reading them take everything below
/// them up the pane with each. Not for ever, either, because then the sidebar accumulates a
/// morning's worth of dead work under every workspace.
///
/// **Nothing here is stored.** `Store`'s rule is that `upsert` creates and `update` modifies, and
/// the question in front of it is whether a subagent should have a row at all. It should not. The
/// longest a subagent's row is meant to live is one turn; the CLI's own record of it is on disk
/// already and Bloom does not own that file; and a table would mean a migration, a delete pass and
/// a decision about what a subagent row means once its session is closed. A relaunch clears the
/// pane, which is what the rule says happens at the start of the next turn anyway, only sooner.
///
/// One roster per session, held by that session's `TranscriptModel`, so a workspace with four
/// chats has four and the sidebar draws the active one's. A shared roster would have shown one
/// chat's subagents under another chat's turn.
public struct SubagentRoster: Sendable, Hashable {
    /// In spawn order, which is also the order the CLI reports them in.
    public private(set) var subagents: [Subagent] = []
    /// Lines the state machine refused, counted rather than dropped silently. Read by the tests;
    /// a number climbing here in the field means the CLI's vocabulary has moved.
    public private(set) var refusals = 0

    /// Maps a `tool_progress` line's `parent_tool_use_id` onto the subagent it is about.
    /// `tool_progress` never carries `task_id`, so without this the elapsed seconds and the retry
    /// block have nowhere to land.
    private var byToolUse: [String: SubagentID] = [:]

    public init() {}

    public init(_ subagents: [Subagent]) {
        self.subagents = subagents
        for subagent in subagents where !subagent.toolUseID.isEmpty {
            byToolUse[subagent.toolUseID] = subagent.id
        }
    }

    public var isEmpty: Bool { subagents.isEmpty }

    public subscript(id: SubagentID) -> Subagent? {
        subagents.first { $0.id == id }
    }

    /// Whether any subagent is still working, which is what a workspace row would ask if it wanted
    /// to summarise the children it is drawing.
    public var isWorking: Bool { subagents.contains { $0.state == .running } }

    /// The next turn has started, so the last turn's children go.
    public mutating func turnStarted() {
        subagents = []
        byToolUse = [:]
        refusals = 0
    }

    /// The turn ended. Anything still running was killed with it, whatever the last line said.
    ///
    /// Sent on the result line rather than inferred, because the process that would have reported
    /// these endings is the one that just went away: without this a subagent whose notification
    /// was lost breathes on the row until the owner sends the next message.
    public mutating func turnEnded() {
        for index in subagents.indices {
            apply(.turnEnded, at: index)
        }
    }

    /// Read one line about a subagent.
    public mutating func apply(_ signal: SubagentSignal) {
        switch signal {
        case .started(let start):
            guard let index = subagents.firstIndex(where: { $0.id == start.id }) else {
                subagents.append(Subagent(start))
                if !start.toolUseID.isEmpty { byToolUse[start.toolUseID] = start.id }
                return
            }
            apply(.spawned, at: index)

        case .progressed(let progress):
            guard let id = byToolUse[progress.parentToolUseID],
                  let index = subagents.firstIndex(where: { $0.id == id }),
                  subagents[index].state == .running
            else { return }
            subagents[index].tick(progress)

        case .patched(let patch):
            guard let index = subagents.firstIndex(where: { $0.id == patch.id }) else { return }
            // The error is the only account of the ending that `task_updated` gives, and it
            // arrives before the notification's summary in every capture, so it is recorded
            // first and overwritten by the summary if one comes.
            subagents[index].note(summary: patch.error ?? "")
            guard let status = patch.status else { return }
            apply(.reported(status: status), at: index)

        case .reported(let report):
            guard let index = subagents.firstIndex(where: { $0.id == report.id }) else { return }
            subagents[index].note(summary: report.summary)
            subagents[index].note(outputFile: report.outputFile)
            apply(.reported(status: report.status), at: index)
        }
    }

    private mutating func apply(_ event: SubagentLifecycleEvent, at index: Int) {
        let transition = subagents[index].state.transition(on: event)
        if let destination = transition.destination {
            subagents[index].move(to: destination)
        } else if transition.isRefused {
            refusals += 1
        }
    }
}
