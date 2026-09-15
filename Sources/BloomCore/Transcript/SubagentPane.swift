import Foundation

/// What the centre pane says about one subagent, in every state it can be in.
///
/// The pane existed before this and said almost nothing: a title, the word "subagent", and the one
/// sentence of `summary`. Three separate reasons, and all three are decisions rather than drawing,
/// so they are here where the suite can reach them.
///
/// 1. **It never refreshed while the subagent was working.** The pane re-read its file keyed on
///    the subagent's state, so a pane opened mid run showed the prefix that existed at the moment
///    it was opened and then nothing more until the subagent ended. `refreshSeconds` is the fix
///    and `refreshes(_:)` says when to spend it.
/// 2. **A background command was asked an agent's questions.** See `SubagentKind`.
/// 3. **A prompt is prose and a command line is not.** `bodyIsCode(_:)` is the one place that is
///    decided, because the codebase's rule is that monospace is for what a machine said or will
///    run, and a Task prompt is neither.
public enum SubagentPane: Sendable {
    // MARK: - Staying live

    /// How often a running subagent's output is re-read from disk.
    ///
    /// The same second `tool_progress` ticks on, which is what the row's elapsed readout moves
    /// with. Picking any other number would mean the row and the pane disagreed about how fresh
    /// they were, and the pane is the one you open BECAUSE the row is too small. It is affordable
    /// only because `SubagentOutput` reads the tail of the file rather than the whole of it: see
    /// `SubagentOutput.tailBytes`.
    public static let refreshSeconds: Double = 1.0

    /// Whether the pane should keep re-reading.
    ///
    /// Only while it is running. A finished subagent's file is finished too, and a poll that
    /// carried on would re-read and re-parse a file that cannot change for as long as the pane
    /// is open.
    public static func refreshes(_ subagent: Subagent?) -> Bool {
        subagent?.state == .running
    }

    /// What the output section says when there is nothing to draw.
    ///
    /// A running subagent that has not spoken yet is not a failure to read anything, and it used
    /// to be described as one: with no file named and no line of its own yet, the pane said "the
    /// agent did not say where this subagent's output was written", which reads as something
    /// having gone wrong to everybody except the person who wrote it. The reasons in
    /// `SubagentOutput.Failure` are the right words once the subagent has stopped and they are
    /// the wrong words while it is working.
    public static func nothingToShow(
        _ failure: SubagentOutput.Failure, kind: SubagentKind, isRunning: Bool
    ) -> String {
        guard isRunning else { return failure.sentence(kind) }
        switch kind {
        case .agent: return "It has not said anything yet."
        case .command: return "It has not printed anything yet."
        }
    }

    // MARK: - What it is

    /// The line under the title: what it is, how deep it was spawned when that is worth saying,
    /// and how long it has been going.
    ///
    /// It used to open with `subagent_type` and fall back to the literal "subagent", which is why
    /// a background command, whose `task_started` carries no `subagent_type` at all, described
    /// itself as a subagent in the one place there was room to be accurate.
    /// - Parameter now: what a running task's elapsed time is measured against. See
    ///   `Subagent.secondsElapsed(at:)`, which the sidebar row reads too, so the pane and the row
    ///   cannot disagree about how long the same subagent has been going.
    public static func subtitle(_ subagent: Subagent, now: Date = Date()) -> String {
        var parts: [String] = []
        switch subagent.kind {
        case .command:
            parts.append(subagent.kind.noun)
        case .agent:
            let type = subagent.type.trimmingCharacters(in: .whitespacesAndNewlines)
            parts.append(type.isEmpty ? subagent.kind.noun : type)
            // Only past one. Saying "depth 1" on every row would be noise on the case that is
            // always true, and the pane is the one place depth can be said at all: the sidebar
            // draws every depth at the same indent.
            if subagent.spawnDepth > 1 {
                parts.append("spawned by a subagent, depth \(subagent.spawnDepth)")
            }
        }
        let elapsed = SubagentRow.duration(subagent.secondsElapsed(at: now))
        if !elapsed.isEmpty { parts.append(elapsed) }
        // A middle dot, which is what every other meta line in the window is joined with. It was
        // a spaced full stop, and in the owner's screenshot "general-purpose . 5m 38s" read as a
        // sentence that had lost its words.
        return parts.joined(separator: " · ")
    }

    // MARK: - What it was given

    /// The heading over what it was given to do, and whether there is anything to put under it.
    public static func briefLabel(_ kind: SubagentKind) -> String {
        switch kind {
        case .agent: "Asked"
        case .command: "Ran"
        }
    }

    /// The heading over what it has done so far.
    public static func outputLabel(_ kind: SubagentKind) -> String {
        switch kind {
        case .agent: "Did"
        case .command: "Printed"
        }
    }

    /// Whether the brief is set in the reading face or in the code face.
    ///
    /// A Task prompt is prose somebody wrote and is set in the reading face, full stop. A command
    /// line is a thing a shell will run, so it is code and is set as code. This is the codebase's
    /// standing rule and this is the one place the subagent pane applies it.
    public static func briefIsCode(_ kind: SubagentKind) -> Bool {
        kind == .command
    }

    /// How long a brief may be before the pane opens with it shut.
    ///
    /// Shown in full when it is under this, because a two line prompt behind a control is a click
    /// to read two lines.
    public static let briefCollapseLimit = 500

    public static func briefCollapses(_ brief: String) -> Bool {
        brief.count > briefCollapseLimit
    }

    /// How much of a long prompt its shut bubble shows.
    ///
    /// **It used to show none of it**, behind an uppercase "Asked" and a "Show the prompt" link,
    /// because the first 500 characters had filled the pane and pushed what the subagent did below
    /// the fold. The owner asked for the pane to read like the chat, where a prompt is a bubble, and
    /// a bubble with nothing in it is not one. So it is a bubble of about three lines at the
    /// chat's measure: enough to recognise which brief this was, short enough that the work starts
    /// on the first screen. The chat itself never shuts a bubble, because a person's own message
    /// is a sentence long; a handed-off brief runs to a page and a half.
    public static let briefPreviewLimit = 280

    /// The shut bubble's text, or nil when the brief is short enough to be shown whole.
    ///
    /// Cut at the last whitespace before the limit rather than mid word, and on one line, because
    /// a brief's first paragraphs are usually a heading and a blank line and those would spend the
    /// preview on nothing.
    public static func briefPreview(_ brief: String) -> String? {
        guard briefCollapses(brief) else { return nil }
        let oneLine = brief.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard oneLine.count > briefPreviewLimit else { return oneLine }
        let head = oneLine.prefix(briefPreviewLimit)
        let cut = head.lastIndex(where: \.isWhitespace).map { head[..<$0] } ?? head
        return String(cut).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// The command line a background command was given.
    ///
    /// **Not in the `task_started` line.** A `local_bash` start carries `task_id`, `tool_use_id`,
    /// `description` and `task_type` and nothing else, so the only account of what actually ran is
    /// the parent's own Bash tool call, which the transcript already holds under the same
    /// `tool_use_id` the subagent carries. This lifts it back out of that row's payload.
    ///
    /// - Parameter payload: the stored bytes of the transcript row whose `refID` is the
    ///   subagent's `toolUseID`.
    public static func commandLine(inPayload payload: Data) -> String? {
        guard let line = String(data: payload, encoding: .utf8),
              case .toolUse(let use)? = AgentEvent.decode(line: line)
        else { return nil }
        // `command` for Bash, and `command` again for the background variants. Nothing else in
        // the CLI's vocabulary puts a shell line anywhere but here, so one key rather than a list.
        let command = (use.input["command"]?.stringValue ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return command.isEmpty ? nil : command
    }
}
