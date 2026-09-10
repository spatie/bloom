import Foundation

public enum AgentKind: String, Sendable, Codable, CaseIterable, Identifiable {
    case claudeCode
    case codex
    case cursor
    case openCode

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .claudeCode: "Claude Code"
        case .codex: "Codex"
        case .cursor: "Cursor"
        case .openCode: "OpenCode"
        }
    }

    public var executableName: String {
        switch self {
        case .claudeCode: "claude"
        case .codex: "codex"
        case .cursor: "cursor-agent"
        case .openCode: "opencode"
        }
    }

    /// Interactive, so it has to be handed to a terminal rather than run inline.
    public var loginCommand: String {
        ([executableName] + loginArguments).joined(separator: " ")
    }

    /// Kept separate from the executable so Settings can use the binary it actually detected,
    /// including an override outside PATH.
    public var loginArguments: [String] {
        switch self {
        case .claudeCode: ["auth", "login"]
        case .codex, .cursor: ["login"]
        case .openCode: ["auth", "login"]
        }
    }

    /// Whether Bloom can actually drive a chat with it.
    ///
    /// Two, now. `AgentRunner` speaks Claude Code's stream-json and `CodexRunner` speaks Codex's
    /// JSON-RPC, and both answer to `SessionRunner`. Cursor and OpenCode are detected and
    /// configurable so the settings screen can be honest about what is installed, and neither has
    /// a runner, so neither is offered anywhere a chat is started.
    public var canRunWorkspaces: Bool {
        switch self {
        case .claudeCode, .codex: true
        case .cursor, .openCode: false
        }
    }

    /// Whether a user message may be written into a turn that is already running.
    ///
    /// **Measured per backend, because the answer is a fact about the CLI rather than a taste.**
    /// `DeliveryHold.turn` used to refuse every delivery on every backend, so a message typed
    /// during a turn waited for a turn that would have taken it.
    ///
    /// **Claude Code: yes.** stdin stays open for the whole session (see `docs/PROTOCOL.md`), and
    /// a user line written four seconds into a running turn was measured on 2.1.260 to be
    /// accepted rather than refused, with the message neither lost nor turned into an error. The
    /// CLI's own copy says what it does with one: a message whose origin is the person is framed
    /// as "The user sent a new message while you were working", and the paragraph under it says
    /// that is how Claude Code surfaces a mid-turn message, within the running turn and often
    /// alongside the next tool result rather than as a separate turn. A turn with no tool call
    /// left in it has no such boundary, and the probe measured that case: the CLI ran the message
    /// as the next turn instead, announcing it with a second `init`. Both landings are ones Bloom
    /// already handles, because `AgentRunner.ingest` applies `turnStarted` on an `init` for
    /// exactly the CLI's habit of starting turns of its own. See `StrayResult`.
    ///
    /// **Codex: yes.** `turn/steer` is the protocol's own call for this, it takes the running
    /// turn's id, and `docs/CODEX.md` records it measured against the real server: a steered
    /// sentence behind a refusal made the agent do the different thing that was asked for.
    /// `CodexRunner` has shipped it since, as the reason that travels behind a denial.
    ///
    /// **Cursor and OpenCode: no**, and not as a judgement about the CLIs. Neither has a runner,
    /// so there is no turn to write into and no wire to write on. This answers `false` for the
    /// same reason `canRunWorkspaces` does, and a backend that grows a runner has to measure this
    /// rather than inherit it.
    ///
    /// **What this is NOT.** It does not widen `DeliveryHold.question` or `DeliveryHold.setup`,
    /// neither of which is about the backend: a turn blocked on a permission answer is not
    /// reading anything else, which `SessionLifecycle` states independently by refusing
    /// `turnStarted` from `waiting`, and a worktree whose setup script is still running has no
    /// dependencies installed to work with.
    public var acceptsMidTurnMessage: Bool {
        switch self {
        case .claudeCode, .codex: true
        case .cursor, .openCode: false
        }
    }

    /// The ones a workspace can actually be started on, in the order they are offered.
    ///
    /// Derived rather than listed, so an agent that grows a runner joins this by answering
    /// `canRunWorkspaces` and nothing else has to be remembered.
    public static var runnable: [AgentKind] { allCases.filter(\.canRunWorkspaces) }

    /// The runnable ones named in a sentence, for prose that has to list them.
    ///
    /// Derived for the reason `runnable` is, and it exists because the literal that used to do
    /// this job outlived the fact it stated. The Agents settings screen said "Workspaces run on
    /// Claude Code" for the whole of the work that made Codex a backend, and went on saying it
    /// afterwards, because nothing about giving a CLI a runner touches a string in a view. A
    /// backend that grows one joins this sentence by answering `canRunWorkspaces`.
    public static var runnableSentence: String {
        let names = runnable.map(\.label)
        guard let last = names.last else { return "no agent Bloom can run" }
        guard names.count > 1 else { return last }
        return names.dropLast().joined(separator: ", ") + " and " + last
    }
}
