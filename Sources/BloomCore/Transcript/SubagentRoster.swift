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
    /// The elapsed seconds the CLI last reported, which is the count it keeps on the work itself.
    ///
    /// **Not what the row reads out, and that is the fix this pair records.** It moves only on
    /// `tool_progress`, and on a real fan-out of seven subagents not one tick ever landed: the
    /// row said nothing at all on the right, so a still mark was the whole of what a running
    /// subagent looked like. The CLI's number is still preferred where there is one, because it
    /// is the count of the work rather than of the row. See `startedAt` and `SubagentRow.detail`.
    public private(set) var elapsedSeconds: Int = 0
    /// When `task_started` arrived, by Bloom's own clock, so a row can count its own seconds when
    /// no tick does it for us.
    public let startedAt: Date
    /// The API refusing it, while it is being refused. Cleared by the first tick that does not
    /// carry one, because a retry that succeeded is not a fact about the subagent any more.
    public private(set) var retry: AgentRetry?
    /// When it stopped running, which is what `SubagentRetention` counts the hold from. Nil while
    /// it is still going. Wall clock rather than the elapsed seconds the CLI reports, because the
    /// question is how long the ROW has been on screen and the CLI's counter is about the work.
    public private(set) var finishedAt: Date?

    init(_ start: SubagentStart, at now: Date) {
        startedAt = now
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
        retry: AgentRetry? = nil,
        finishedAt: Date? = nil,
        startedAt: Date = Date()
    ) {
        self.startedAt = startedAt
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
        self.finishedAt = finishedAt
    }

    /// An agent, or a shell command the CLI put in the background. Read off `task_type`.
    public var kind: SubagentKind { SubagentKind(taskType: taskType) }

    /// Whether clicking this row can show anything.
    ///
    /// False when the CLI never named a file. It always did for an agent in the capture, and it
    /// routinely does NOT for a background command: `task_notification.output_file` comes through
    /// empty for `local_bash` in the same captures where it is an absolute path for `local_agent`.
    public var hasOutput: Bool { !(outputFile ?? "").isEmpty }

    /// How long it has been going, by whichever of the two clocks is further on.
    ///
    /// The CLI's `tool_progress` count where there is one, because that is the count of the work,
    /// and Bloom's own otherwise, because a fan-out that produces no ticks at all is a real thing
    /// that happened and a row reading nothing is what it looked like. A subagent that has
    /// finished counts to the moment it finished rather than to now: nothing arrives to raise it
    /// again, and a row that kept counting would be inventing seconds.
    public func secondsElapsed(at now: Date) -> Int {
        let ours = Int((finishedAt ?? now).timeIntervalSince(startedAt))
        return max(elapsedSeconds, max(0, ours))
    }

    fileprivate mutating func move(to state: SubagentState, at now: Date) {
        self.state = state
        // Only the first ending is timed. Two lines report one ending and the second must not
        // restart the hold, which would be a row that stayed twice as long as any other.
        if finishedAt == nil { finishedAt = now }
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

/// Every subagent this session has spawned that has not yet been accounted for, in the order they
/// were spawned.
///
/// **The clearing rule, which is the backstop.** A row appears on `task_started` and a FINISHED
/// row is removed at the latest when the next turn starts. Not for ever, because then the sidebar
/// accumulates a morning's worth of dead work under every workspace.
///
/// **A subagent that is still running survives the turn that spawned it, and that is the bug this
/// paragraph records.** The `Agent` tool answers "Async agent launched successfully. The agent is
/// working in the background", the turn's result line lands while the subagent is minutes from
/// finishing, and `claude` keeps running for the whole session, so the ending still arrives on the
/// same stream under the same `task_id`. Clearing a running subagent here threw away the only
/// thing that could receive that line, and the sidebar drew a workspace with a spinner and no
/// children while the transcript said two agents were still going. So finished rows are cleared
/// and running ones are kept, and only the process going away ends one Bloom was not told about.
///
/// Most rows go sooner than that: a tick is held briefly and then leaves, and only a failure, or a
/// row somebody has opened, stays for the whole turn. That is `SubagentRetention`'s to decide and
/// not this type's, which holds every subagent the turn spawned whether or not it still has a row.
/// The roster is also what the output pane reads, so a subagent whose row has gone is still there
/// to be shown.
///
/// **Nothing here is stored.** `Store`'s rule is that `upsert` creates and `update` modifies, and
/// the question in front of it is whether a subagent should have a row at all. It should not. The
/// longest a subagent's row is meant to live is one session; the CLI's own record of it is on disk
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

    /// The next turn has started, so the last turn's FINISHED children go, rows and all. The
    /// backstop under `SubagentRetention`, and the only thing that clears a failure.
    ///
    /// Anything still running stays. It is not the last turn's child in any sense that matters:
    /// it is work in flight, it is still going to report its own ending on this session's stream,
    /// and the row is the only place anybody can see it. See the type's doc comment.
    public mutating func turnStarted() {
        subagents.removeAll { $0.state.isFinished }
        let living = Set(subagents.map(\.id))
        byToolUse = byToolUse.filter { living.contains($0.value) }
        refusals = 0
    }

    /// The agent process died. Anything still running was killed with it, whatever the last line
    /// said.
    ///
    /// Sent when `claude` itself goes away rather than when a turn ends, because the process is
    /// what reports these endings and it lives for the whole session: a turn finishing is not news
    /// about a subagent. Without this a subagent whose notification can never arrive, because the
    /// process that would have sent it was signalled, breathes on the row for ever.
    public mutating func agentExited(now: Date = Date()) {
        for index in subagents.indices {
            apply(.agentExited, at: index, now: now)
        }
    }

    /// Read one line about a subagent.
    ///
    /// - Parameter now: when the line arrived, which is what a row's hold is counted from. A
    ///   parameter rather than a `Date()` inside, so a test can put a row past its hold without
    ///   sleeping through it.
    public mutating func apply(_ signal: SubagentSignal, now: Date = Date()) {
        switch signal {
        case .started(let start):
            guard let index = subagents.firstIndex(where: { $0.id == start.id }) else {
                subagents.append(Subagent(start, at: now))
                if !start.toolUseID.isEmpty { byToolUse[start.toolUseID] = start.id }
                return
            }
            apply(.spawned, at: index, now: now)

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
            apply(.reported(status: status), at: index, now: now)

        case .reported(let report):
            guard let index = subagents.firstIndex(where: { $0.id == report.id }) else { return }
            subagents[index].note(summary: report.summary)
            subagents[index].note(outputFile: report.outputFile)
            apply(.reported(status: report.status), at: index, now: now)
        }
    }

    private mutating func apply(_ event: SubagentLifecycleEvent, at index: Int, now: Date) {
        let transition = subagents[index].state.transition(on: event)
        if let destination = transition.destination {
            subagents[index].move(to: destination, at: now)
        } else if transition.isRefused {
            refusals += 1
        }
    }
}
