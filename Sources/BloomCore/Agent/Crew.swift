import Foundation

/// The rules an orchestrator's crew is held to: what a crew member may be called, how many may
/// run, and what Bloom says to the orchestrator when one of them stops.
///
/// **The app says subagent and this code says crew, on purpose.** `Subagent` was taken before this
/// existed, by Claude Code's own Task tool: `SubagentRow`, `SubagentRoster`, `SidebarSelection`'s
/// `.subagent` and half a dozen more, all of them about the children of a single turn, which live
/// for seconds and are drawn from the stream rather than stored. What this file is about is a
/// second chat in the same worktree that outlives a turn, can be talked to, and talks back. Two
/// different things, and reusing the word would have made every one of those types ambiguous.
///
/// **A subagent is not a child.** A child is a workspace an agent asked for: its own worktree, its
/// own branch, its own pull request, and `docs/BRIDGE.md` is about keeping it penned in. A
/// subagent shares the caller's worktree and its branch, so everything a crew does lands in one
/// diff. The test that decides which one a caller wants is how many pull requests they expect at
/// the end: one, and it is a subagent; several, and it is `workspace_start`.
///
/// **The name is the orchestrator's to invent.** No fixed roles, no menu of agent types. It knows
/// what it split the work into and Bloom does not, so `cascade-read` and `media-suite` are as
/// valid as anything we could have listed. All Bloom asks is that a name is short enough to draw
/// in a sidebar row and unique inside one workspace, because the other tools take it as the
/// address of the agent to talk to.
///
/// In the core, and pure, because every rule here is a decision that has to be assertable without
/// a workspace, a socket or a running CLI.
public enum Crew {
    /// How many subagents may be running in one workspace at once.
    ///
    /// Ten, on the same reasoning as the eight running children a parent may have and the six
    /// starts in fifteen minutes the owner's own client gets: not a safety limit, a number that
    /// makes somebody notice at ten rather than at thirty. It was three, which is what a person
    /// splitting work by hand reaches for, and it turned out to be the wrong shape for the thing
    /// people actually ask for: "use a crew of five" met a refusal and an orchestrator that
    /// queued the last two behind slots, which is a worse answer than ten bills. Ten agents on
    /// one branch is still ten writers in one working tree, and the tools say so.
    public static let ceiling = 10

    /// The longest a name may be. A sidebar row is about twenty characters wide at the width the
    /// column opens at, and a name that is ellipsised in every drawing of it is not an address
    /// anybody can read back to the agent that chose it.
    public static let nameLimit = 32

    /// Why a start was refused, in the words the caller is given.
    ///
    /// Each case carries what the sentence needs rather than a formatted string, so the wording
    /// lives in one place and a test can assert the reason rather than the prose.
    public enum StartRefusal: Error, Equatable {
        case noName
        case nameTaken(String)
        case tooMany(running: Int)
        case notAnOrchestrator
    }

    /// A name Bloom will accept, or nil when there is nothing left of it.
    ///
    /// Whitespace is collapsed rather than rejected, because a model writing a name is writing
    /// prose and "cascade read" is a name it meant. Control characters go: they are invisible in
    /// the sidebar and would make two names that draw identically compare unequal, which is the
    /// worst kind of duplicate.
    public static func normalisedName(_ raw: String) -> String? {
        // Turned into spaces rather than dropped, and that is the whole bug this line carries:
        // deleting them joined the words either side, so a name written with a tab in it came out
        // as "readthecascade". A control character between two words is a word separator, and one
        // anywhere else disappears when the whitespace is collapsed.
        let stripped = raw.unicodeScalars
            .map { CharacterSet.controlCharacters.contains($0) ? " " : String($0) }
            .joined()

        let collapsed = stripped
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !collapsed.isEmpty else { return nil }

        return String(collapsed.prefix(nameLimit))
    }

    /// Whether this start may go ahead, and under what name.
    ///
    /// `existing` is every subagent name already in this workspace, running or not, because a
    /// stopped agent keeps its conversation and its row until the workspace is archived, and a
    /// second agent taking its name would make the transcript above it read as one agent.
    ///
    /// `running` counts only the live ones, which is what the ceiling is about.
    public static func start(
        name raw: String,
        existing: Set<String>,
        running: Int,
        callerIsSubagent: Bool
    ) -> Result<String, StartRefusal> {
        // First, because a subagent may not start one whatever it asked for. The limit on nesting
        // is one for the reason the bridge gives for children: a depth counter is a number that
        // drifts, and a flat crew has no cycle to deadlock in.
        if callerIsSubagent { return .failure(.notAnOrchestrator) }

        guard let name = normalisedName(raw) else { return .failure(.noName) }

        if existing.contains(name) { return .failure(.nameTaken(name)) }

        if running >= ceiling { return .failure(.tooMany(running: running)) }

        return .success(name)
    }

    /// What a refusal says out loud. Written to be read by a model that has to decide what to do
    /// next, so each one ends with the move that is still open to it.
    public static func sentence(for refusal: StartRefusal) -> String {
        switch refusal {
        case .noName:
            "A subagent needs a name. Give it one that says what the agent is for, such as "
                + "\"tests\" or \"read-the-cascade\"."
        case .nameTaken(let name):
            "This workspace already has a subagent called \"\(name)\". Talk to that one with "
                + "agent_say, or start a new one under another name."
        case .tooMany(let running):
            "\(running) subagents are already running in this workspace, which is the limit. "
                + "Stop one with agent_stop, or wait for one to finish."
        case .notAnOrchestrator:
            "A subagent cannot start a subagent. Say what you need to the agent that started you "
                + "and let it decide."
        }
    }

    /// What `agent_say` and `workspace_send` tell the caller about when the words will be read.
    ///
    /// **The old sentence promised a wait that no longer happens.** It said "If it is mid turn it
    /// will read it when that turn ends", which was true while a running turn held every queue.
    /// Two of the four backends take a message into the turn they are running, so the caller was
    /// being told to expect a delay it will not see, and a model told to wait is a model that
    /// polls or gives up. Here rather than in `WorkspaceModel` so the suite can hold it, for the
    /// reason `DeliveryHold.sentence(on:)` is in the core.
    ///
    /// The clause about something being queued in front of it is the honest hedge, and it is
    /// deliberately not spelled out into the three things that could be: a setup script, an
    /// unanswered permission question, or simply an older message. `workspace_list` names each of
    /// those in `hold_note`, and this is a confirmation that the words were taken rather than a
    /// status report on the chat.
    public static func deliverySentence(to agent: AgentKind) -> String {
        agent.acceptsMidTurnMessage
            ? "It reads this inside the turn it is running, or straight away if it is idle, "
                + "unless something is queued in front of it."
            : "If it is mid turn it will read this when that turn ends."
    }

    /// The line Bloom puts in the orchestrator's chat when one of its subagents stops.
    ///
    /// **This is the whole point of the design, so it is worth saying why it exists.** Without it
    /// an orchestrator has to poll, and a model that has to poll either spins or forgets. So the
    /// end of a subagent's turn is an event Bloom delivers, carrying what the agent last said
    /// rather than a handle to go and fetch it: the orchestrator picks the work back up with the
    /// answer already in front of it.
    public static func stoppedSentence(name: String, lastMessage: String?) -> String {
        guard let last = lastMessage?.trimmingCharacters(in: .whitespacesAndNewlines),
              !last.isEmpty else {
            return "Your subagent \"\(name)\" has stopped. It said nothing before it did.\n\n"
                + tidyHint
        }

        return "Your subagent \"\(name)\" has stopped. The last thing it said to you:\n\n\(last)"
            + "\n\n" + tidyHint
    }

    /// The same line for an agent that did not finish on purpose.
    ///
    /// Told rather than left silent, because an orchestrator waiting on a crew member that died
    /// is the failure that looks exactly like one that is still thinking.
    public static func failedSentence(name: String, reason: String) -> String {
        let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        let tail = trimmed.isEmpty ? "No reason was reported." : trimmed

        return "Your subagent \"\(name)\" stopped without finishing. \(tail)"
    }

    /// What an orchestrator is told when the owner stops one of its subagents by hand.
    ///
    /// **Said differently from an agent finishing on its own, and the difference is the point.**
    /// An agent that stopped by itself has done what it was asked and the orchestrator may want
    /// another; an agent the owner took away is a decision by the person the orchestrator is
    /// working for, and starting a replacement would be undoing it. So the sentence says who did
    /// it and says not to.
    public static func stoppedByOwnerSentence(name: String) -> String {
        "Your subagent \"\(name)\" was stopped by the owner, who was watching it. It is gone: "
            + "its row and its name have been let go. Do not start another one in its place "
            + "unless they ask for it. Carry on with your own work."
    }

    /// The one line the transcript draws for it.
    public static func stoppedByOwnerSummary(name: String) -> String {
        "\(name) stopped by you"
    }

    /// The one line the transcript draws for a stop, as opposed to the paragraph the model is
    /// handed. See `CrewMessage`, which holds both: a person reading their own window wants to
    /// know that an agent finished, and does not want the instruction that was addressed to the
    /// orchestrator.
    public static func stoppedSummary(name: String) -> String {
        "\(name) stopped"
    }

    /// The same for a failure, which keeps its reason because that is the whole of the news.
    public static func failedSummary(name: String, reason: String) -> String {
        let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "\(name) stopped without finishing" : "\(name) failed. \(trimmed)"
    }

    /// What the wake tells an orchestrator to do with an agent it is finished with.
    ///
    /// **A hint rather than a rule, and this is the whole cleanup design.** Bloom sweeps nothing:
    /// a timer that takes an agent away can always take away the one you were about to talk to,
    /// and every argument about how long it should wait is unwinnable. So the tool says what to
    /// do, in the three places a model reads: here, in `agent_list`'s answer, and in
    /// `agent_start`'s description. A model that forgets costs a row in the sidebar and nothing
    /// else, because a finished agent holds no slot.
    public static let tidyHint =
        "If you have no more work for it, call agent_stop on it now: that ends it and takes its "
        + "row out of the sidebar. If you will send it more work, leave it alone, because it "
        + "keeps everything it has read."

    /// How a message from a subagent is put in front of the orchestrator.
    ///
    /// In the untrusted envelope, exactly as text read off a web page is, and for the same reason:
    /// a subagent is a model that has been reading files, and what it says back is data rather
    /// than an instruction from the person the orchestrator is working for. See
    /// `BridgeUntrustedText`, whose head states the threat properly.
    public static func message(from name: String, saying text: String) -> String {
        BridgeUntrustedText.wrapSaying(text, from: "your subagent \"\(name)\"")
    }
}
