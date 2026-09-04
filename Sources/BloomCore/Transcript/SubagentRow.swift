import Foundation

/// What one subagent's row in the sidebar says, in every state it can be in.
///
/// A row in a 260 point pane has three slots and no more: a mark, a name that will be truncated,
/// and a short trailing readout. Deciding what goes in them is the whole of the feature and it is
/// therefore here rather than in the view, where nothing could test it. The view's job is to draw
/// a mark, a name and a readout.
public struct SubagentRow: Sendable, Hashable, Identifiable {
    /// The mark at the leading edge. Deliberately not the same vocabulary as `WorkspaceStatus`:
    /// a subagent has four states and a workspace has more, and the day somebody adds a fifth to
    /// one of them is the day a shared enum starts drawing the wrong thing in the other pane.
    public enum Mark: Sendable, Hashable {
        /// Still going. An ellipsis that breathes, told apart from the three endings by its shape
        /// like every other mark in the column. See `SubagentMarkGlyph`.
        case working
        case done
        case failed
        /// It never finished and nothing is coming. Not a cross: nothing broke.
        case stopped

        /// The outcome in a word, for a reader getting it from neither the shape nor the tint.
        ///
        /// The four marks are genuinely distinct shapes, which is the hard half done, but the
        /// glyph carried no label and the row's text says only the subagent's name. So VoiceOver
        /// read out a name and never once said the thing failed.
        public var word: String {
            switch self {
            case .working: "Working"
            case .done: "Finished"
            case .failed: "Failed"
            case .stopped: "Stopped"
            }
        }
    }

    /// The short readout at the trailing edge.
    public enum Detail: Sendable, Hashable {
        /// How long it has been going, while it is going.
        case elapsed(seconds: Int)
        /// The API is refusing it. The facts and the words are both `AgentRetry`'s: the sidebar
        /// and the transcript are two views of one outage and must not name it differently.
        case retrying(AgentRetry)
        /// What it answered, or why it did not.
        case summary(String)
        case none

        public var text: String {
            switch self {
            case .elapsed(let seconds): SubagentRow.duration(seconds)
            case .retrying(let retry): retry.readout
            case .summary(let summary): summary
            case .none: ""
            }
        }
    }

    public let id: SubagentID
    public let title: String
    public let mark: Mark
    public let detail: Detail
    /// Whether clicking the row can show anything.
    public let opensOutput: Bool
    /// What a screen reader reads instead of a tick and four characters.
    public let spokenValue: String

    /// How wide the readout may be before it is cut.
    ///
    /// Measured against the pane rather than chosen: a 260 point sidebar, less the project gutter,
    /// less the subagent indent, less the mark and its gap, leaves the name and the readout to
    /// share about 190 points. Anything past this is truncated by the view anyway, and cutting it
    /// here keeps the row's own `Hashable` cheap when the summary is a paragraph, which a failure
    /// summary always is.
    static let detailLimit = 28

    /// Build a row for every subagent in a roster, in the order they are drawn.
    ///
    /// Every one of them, which is what a gallery and a test want. The pane does not draw every
    /// one: which of them still has a row depends on the clock and on what is open, and that is
    /// `SubagentRetention.rows`.
    ///
    /// **Depth greater than one is drawn flat**, at the same indent as depth one, rather than
    /// nested a level further. A fourth outline level in a 260 point pane leaves a name six
    /// characters wide, and the pane is already two levels with a third being added here. The
    /// spawn order still puts a subagent's children directly after it in the run, so the reading
    /// order is preserved even though the indent is not. Nothing in the capture went past depth
    /// one, so this is a decision about the shape rather than about data anybody has seen: if
    /// deep fan-out turns out to be common, the answer is a count on the parent row rather than
    /// another indent.
    /// - Parameter now: what the running rows count their seconds against. See `detail(of:now:)`.
    public static func rows(_ roster: SubagentRoster, now: Date = Date()) -> [SubagentRow] {
        roster.subagents.map { SubagentRow($0, now: now) }
    }

    public init(_ subagent: Subagent, now: Date = Date()) {
        id = subagent.id
        title = Self.title(of: subagent)
        mark = switch subagent.state {
        case .running: .working
        case .completed: .done
        case .failed: .failed
        case .stopped: .stopped
        }
        detail = Self.detail(of: subagent, now: now)
        // **An agent's row always opens**, whether or not the CLI has named a file yet, because
        // the file is named on the line that ENDS a subagent and a running one is the case
        // somebody most wants to look inside. The gate used to be `hasOutput`, which meant a
        // subagent could not be clicked until it had finished, and it made
        // `SubagentPane.refreshSeconds` unreachable: nothing could open the pane a live re-read
        // was written for. There is something to show from the first frame either way, because
        // `task_started` carries the whole prompt, and the pane falls back to the nested rows
        // Bloom itself stored when there is no file. See `SubagentTranscript.live(streamLines:sessionID:)`.
        //
        // A background command keeps the old gate. Its brief is lifted out of the parent's Bash
        // call and its output is plain stdout that only `output_file` holds, so with no file
        // there genuinely is nothing to draw.
        opensOutput = subagent.kind == .agent || subagent.hasOutput
        spokenValue = Self.spoken(subagent, detail: detail)
    }

    /// The name. `description` is a phrase the parent wrote for exactly this purpose, so it is
    /// used whole; `subagent_type` stands in when there is none, because a row with no name at
    /// all cannot be told from the row above it.
    public static func title(of subagent: Subagent) -> String {
        let description = subagent.description.trimmingCharacters(in: .whitespacesAndNewlines)
        if !description.isEmpty { return description }
        let type = subagent.type.trimmingCharacters(in: .whitespacesAndNewlines)
        return type.isEmpty ? "Subagent" : type
    }

    /// **The seconds are Bloom's own count, raised by the CLI's when the CLI is counting.**
    /// `elapsedSeconds` moves only on `tool_progress`, and a fan-out of seven subagents arrived
    /// with no tick at all, so the readout was empty and `duration(0)` is the empty string: a
    /// running row said nothing and did not move. Bloom knows when `task_started` landed, which
    /// is a worse measure of the work and a perfect measure of the row, so it is the floor.
    static func detail(of subagent: Subagent, now: Date = Date()) -> Detail {
        switch subagent.state {
        case .running:
            if let retry = subagent.retry { return .retrying(retry) }
            return .elapsed(seconds: subagent.secondsElapsed(at: now))
        case .completed, .failed, .stopped:
            let summary = shorten(subagent.summary)
            return summary.isEmpty ? .none : .summary(summary)
        }
    }

    /// The first sentence of what the CLI said, cut to what the pane can hold.
    ///
    /// Truncation and nothing else. It deliberately does not rewrite a failure into better words:
    /// the wording of an error belongs with the rest of the error surfaces, and a sidebar that
    /// paraphrased a message the transcript quotes verbatim would be two accounts of one event.
    /// A 529 reads "Agent terminated early due to an API..." here and in full in the pane.
    static func shorten(_ text: String) -> String {
        let line = text
            .split(whereSeparator: \.isNewline)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        guard line.count > detailLimit else { return line }
        // Cut at a space where there is one near the end, so the readout stops on a word rather
        // than mid-word with an ellipsis stuck to half of it.
        let cut = line.index(line.startIndex, offsetBy: detailLimit)
        let head = line[line.startIndex..<cut]
        if let space = head.lastIndex(of: " "), head.distance(from: space, to: head.endIndex) < 10 {
            return head[head.startIndex..<space].trimmingCharacters(in: .whitespaces) + "..."
        }
        return head.trimmingCharacters(in: .whitespaces) + "..."
    }

    /// Seconds, the way a row has room to say them.
    public static func duration(_ seconds: Int) -> String {
        guard seconds > 0 else { return "" }
        guard seconds >= 60 else { return "\(seconds)s" }
        let minutes = seconds / 60
        guard minutes < 60 else { return "\(minutes / 60)h \(minutes % 60)m" }
        return "\(minutes)m \(seconds % 60)s"
    }

    /// The row read out loud. The mark is the fact a sighted reader gets for free and a screen
    /// reader gets not at all, so it is said in words, and the readout is said after it.
    static func spoken(_ subagent: Subagent, detail: Detail) -> String {
        let state = switch subagent.state {
        case .running: subagent.retry == nil ? "working" : "working, being retried"
        case .completed: "finished"
        case .failed: "failed"
        case .stopped: "stopped"
        }
        let text = detail.text
        return text.isEmpty ? state : "\(state), \(text)"
    }
}
