import Foundation

// MARK: - What Bloom needs

/// One thing the welcome window looks for on this machine.
///
/// Four, and they are not equal. `git` is the only flat requirement: a workspace IS a worktree,
/// so `Git.worktreeAdd` is reached on the first task anybody describes and there is no path
/// through the app that avoids it. Claude Code and Codex are a pair, and what is required is
/// **either** of them, because `AgentKind.runnable` is derived from `canRunWorkspaces` and both
/// answer true: a machine with Codex and no Claude Code is a working machine, and telling that
/// person they are missing something would be a lie. The GitHub CLI is wanted and not needed,
/// which the README already says in as many words, so it is never allowed to read as a failure.
public enum SetupTool: String, Sendable, Hashable, CaseIterable, Identifiable, Codable {
    case git
    case claudeCode
    case codex
    case gitHub

    public var id: String { rawValue }

    /// The agent this tool is, when it is one. Nil for git and for the GitHub CLI.
    ///
    /// Derived rather than a second list, so an agent that grows a runner and joins
    /// `AgentKind.runnable` cannot be described here as something else.
    public var agentKind: AgentKind? {
        switch self {
        case .claudeCode: .claudeCode
        case .codex: .codex
        case .git, .gitHub: nil
        }
    }

    /// The name of the thing, as the person who has to install it would search for it.
    public var title: String {
        switch self {
        case .git: "Git"
        case .claudeCode: "Claude Code"
        case .codex: "Codex"
        case .gitHub: "GitHub CLI"
        }
    }

    /// The name as it reads inside a sentence, which is not always the name on the row. "Codex is
    /// not set up" is a sentence and "GitHub CLI is not set up" is a caption, so the one tool
    /// whose name wants an article gets one.
    public var sentenceName: String {
        switch self {
        case .gitHub: "the GitHub CLI"
        case .git, .claudeCode, .codex: title
        }
    }

    /// Why Bloom wants it, in one sentence, from the user's side of the screen.
    ///
    /// Every one of these says what it buys rather than what it is, because a person reading this
    /// window has already worked out that `gh` is the GitHub CLI and has not worked out whether
    /// they can ignore it.
    public var purpose: String {
        switch self {
        case .git:
            "Every workspace is a real git worktree, so Bloom builds each one with git."
        case .claudeCode:
            "The agent Bloom runs in a worktree, and the one most people come here for."
        case .codex:
            "OpenAI's agent. Bloom can drive a workspace with it instead of Claude Code."
        case .gitHub:
            "Pull requests, checks and merges. Everything else in Bloom works without it."
        }
    }

    /// The executable looked for on PATH.
    public var executableName: String {
        switch self {
        case .git: "git"
        case .claudeCode, .codex: agentKind?.executableName ?? rawValue
        case .gitHub: "gh"
        }
    }

    /// The order the window lists them in: the flat requirement, then the agents, then the one
    /// that is optional. Reading down the column is reading down the strength of the ask.
    public static let displayOrder: [SetupTool] = [.git, .claudeCode, .codex, .gitHub]
}

// MARK: - How a tool turned out

/// What a probe found, once. Deliberately four states and not a boolean: "installed but not
/// signed in" is the state a boolean would round to "missing", and the fix for it is a different
/// command from the one that installs it.
public enum SetupOutcome: Sendable, Hashable {
    /// Not looked at yet. The window opens in this state so the checks can be watched settling.
    case pending
    /// Found, usable, and signed in where signing in is a thing it does. The string is the one
    /// fact worth printing beside it: a version, or an account.
    case ready(detail: String?)
    /// The binary is there and the account is not. `detail` is nil when nothing is known.
    case needsSignIn(detail: String?)
    case missing

    public var isSettled: Bool {
        if case .pending = self { return false }
        return true
    }

    public var isReady: Bool {
        if case .ready = self { return true }
        return false
    }

    /// The one fact printed beside the name, or nil when there is nothing true to say.
    public var detail: String? {
        switch self {
        case .ready(let detail), .needsSignIn(let detail): detail
        case .pending, .missing: nil
        }
    }
}

/// How loudly a row is allowed to speak.
///
/// The whole reason this type exists: a tool that is missing is not automatically a problem. A
/// missing Codex on a machine with Claude Code signed in is a note, and rendering it in the same
/// red as a missing git would turn a welcome into an interrogation.
public enum SetupSeverity: Sendable, Hashable, Comparable {
    case ok
    case note
    case problem
}

/// One row of the window: what was looked for, and what came back.
public struct SetupCheck: Sendable, Hashable, Identifiable {
    public var tool: SetupTool
    public var outcome: SetupOutcome

    public var id: String { tool.rawValue }

    public init(tool: SetupTool, outcome: SetupOutcome = .pending) {
        self.tool = tool
        self.outcome = outcome
    }
}

// MARK: - The fix

/// The shortest honest route from a state to a working one.
///
/// `command` is shown verbatim with a copy button rather than paraphrased, because a command
/// retyped from prose is a command that fails on a hyphen. `isInteractive` is what says Bloom can
/// run it itself: `gh auth login` and `claude /login` both ask questions and wait for answers, and
/// `GitHubSignInSheet` already proves those belong in a pty inside the app rather than in a
/// sentence telling somebody to open Terminal.
public struct SetupFix: Sendable, Hashable {
    /// What pressing on will do, in the imperative, so the sentence and the button agree.
    public var summary: String
    /// Exactly what to run, or nil when there is nothing to run.
    public var command: String?
    /// Where to read the real instructions, for the person whose package manager is not the one
    /// the command assumes.
    public var url: URL?
    /// True when the command asks questions, and therefore when Bloom can host it in a terminal
    /// instead of handing the user a command and hoping.
    public var isInteractive: Bool

    public init(summary: String, command: String? = nil, url: URL? = nil, isInteractive: Bool = false) {
        self.summary = summary
        self.command = command
        self.url = url
        self.isInteractive = isInteractive
    }
}

public extension SetupCheck {
    /// What to do about this row, or nil when there is nothing to do.
    ///
    /// Every install command here is the one the tool's own documentation gives first, and every
    /// one of them carries the address as well, because Homebrew and npm are assumptions and the
    /// address is not.
    var fix: SetupFix? {
        switch (tool, outcome) {
        case (_, .pending), (_, .ready):
            return nil

        case (.git, _):
            // Not Homebrew first. Git arrives with the command line tools on every Mac, and that
            // is one prompt with no package manager to install beforehand.
            return SetupFix(
                summary: "Install Apple's command line tools, which include git",
                command: "xcode-select --install",
                url: URL(string: "https://git-scm.com/download/mac")
            )

        case (.claudeCode, .missing):
            return SetupFix(
                summary: "Install Claude Code",
                command: "npm install -g @anthropic-ai/claude-code",
                url: URL(string: "https://docs.claude.com/en/docs/claude-code/setup")
            )

        case (.claudeCode, .needsSignIn):
            return SetupFix(
                summary: "Sign in to Claude Code",
                command: AgentKind.claudeCode.loginCommand,
                url: nil,
                isInteractive: true
            )

        case (.codex, .missing):
            return SetupFix(
                summary: "Install Codex",
                command: "npm install -g @openai/codex",
                url: URL(string: "https://developers.openai.com/codex/cli")
            )

        case (.codex, .needsSignIn):
            return SetupFix(
                summary: "Sign in to Codex",
                command: AgentKind.codex.loginCommand,
                url: nil,
                isInteractive: true
            )

        case (.gitHub, .missing):
            return SetupFix(
                summary: "Install the GitHub CLI",
                command: "brew install gh",
                url: URL(string: "https://cli.github.com")
            )

        case (.gitHub, .needsSignIn):
            return SetupFix(
                summary: "Sign in to GitHub",
                command: "gh auth login",
                url: nil,
                isInteractive: true
            )
        }
    }
}

// MARK: - The verdict

public enum SetupVerdict: Sendable, Hashable {
    /// At least one check has not come back.
    case checking
    /// Everything, required and optional, is installed and signed in.
    case ready
    /// Nothing is in the way, and something optional is not set up.
    case readyWithNotes
    /// Bloom cannot start a workspace on this machine yet.
    case blocked
}

/// Every check together, and what they add up to.
///
/// The verdict is computed rather than stored, so a report can never disagree with the rows it is
/// made of. That mattered the moment the agent pair arrived: whether Codex missing is a problem
/// depends on Claude Code, which is a fact about the whole report and not about the Codex row.
public struct SetupReport: Sendable, Hashable {
    public var checks: [SetupCheck]

    public init(checks: [SetupCheck]) {
        self.checks = checks
    }

    /// Every tool, in reading order, all pending. What the window shows on the frame it opens.
    public static var pending: SetupReport {
        SetupReport(checks: SetupTool.displayOrder.map { SetupCheck(tool: $0) })
    }

    public func outcome(for tool: SetupTool) -> SetupOutcome {
        checks.first { $0.tool == tool }?.outcome ?? .pending
    }

    public var isSettled: Bool {
        checks.allSatisfy { $0.outcome.isSettled }
    }

    /// True when at least one agent Bloom can actually drive is installed and signed in.
    ///
    /// Either, not both. See `SetupTool`.
    public var hasRunnableAgent: Bool {
        SetupTool.displayOrder
            .filter { $0.agentKind?.canRunWorkspaces == true }
            .contains { outcome(for: $0).isReady }
    }

    /// Whether an agent row is still being looked at, which is what keeps a half-settled report
    /// from announcing that no agent was found.
    private var agentsAreStillChecking: Bool {
        SetupTool.displayOrder
            .filter { $0.agentKind?.canRunWorkspaces == true }
            .contains { !outcome(for: $0).isSettled }
    }

    public var verdict: SetupVerdict {
        guard isSettled else { return .checking }
        if !outcome(for: .git).isReady { return .blocked }
        if !hasRunnableAgent { return .blocked }
        let everythingIsReady = checks.allSatisfy { $0.outcome.isReady }
        return everythingIsReady ? .ready : .readyWithNotes
    }

    /// How loudly one row speaks. See `SetupSeverity`.
    public func severity(for tool: SetupTool) -> SetupSeverity {
        let outcome = outcome(for: tool)
        if outcome.isReady { return .ok }
        if !outcome.isSettled { return .note }

        switch tool {
        case .git:
            return .problem
        case .claudeCode, .codex:
            // A missing agent is only a problem when it is the LAST agent. While the other row is
            // still being looked at, this one holds its tongue rather than flashing red and going
            // quiet again half a second later.
            if hasRunnableAgent || agentsAreStillChecking { return .note }
            return .problem
        case .gitHub:
            return .note
        }
    }

    /// The rows standing between this machine and a working Bloom, in reading order.
    public var blocking: [SetupCheck] {
        checks.filter { severity(for: $0.tool) == .problem }
    }
}

// MARK: - What the window says

/// The headline and the sentence under it, for each verdict.
///
/// Here rather than in the view for the reason everything else here is: a sentence typed into a
/// `Text` is a sentence nothing can hold still, and the whole point of this window is that the
/// common case reads as a welcome. That is a claim about copy, so the copy is testable.
public extension SetupReport {
    var headline: String {
        switch verdict {
        case .checking: "Looking around"
        case .ready: "You are all set"
        case .readyWithNotes: "You are ready to go"
        case .blocked: "Nearly there"
        }
    }

    var sentence: String {
        switch verdict {
        case .checking:
            return "Bloom is checking what this Mac already has."
        case .ready:
            return "Everything Bloom uses is installed and signed in. Describe a task and it will build the worktree for you."
        case .readyWithNotes:
            return readyWithNotesSentence
        case .blocked:
            return blockedSentence
        }
    }

    /// The optional tools that are not set up, named, so the sentence can be specific. A sentence
    /// that says "one optional tool" and makes the reader hunt down the column for which one is a
    /// sentence that has not finished its job.
    private var readyWithNotesSentence: String {
        let quiet = checks
            .filter { !$0.outcome.isReady && severity(for: $0.tool) == .note }
            .map(\.tool.sentenceName)

        guard !quiet.isEmpty else {
            return "Bloom has what it needs. Describe a task and it will build the worktree for you."
        }
        return "Bloom has what it needs. \(list(quiet)) \(quiet.count == 1 ? "is" : "are") not set up, which only turns off the parts below."
    }

    private var blockedSentence: String {
        let missingGit = !outcome(for: .git).isReady
        if missingGit && !hasRunnableAgent {
            return "Bloom needs git and an agent before it can build a workspace. Both are below."
        }
        if missingGit {
            return "Bloom builds every workspace with git, and cannot find it. There is one command below."
        }
        return "Bloom needs one agent it can drive. Claude Code or Codex, either is enough."
    }

    /// "Codex", "Codex and the GitHub CLI", "A, B and C". Oxford comma deliberately absent, which
    /// is the house style everywhere else in this app's prose.
    private func list(_ items: [String]) -> String {
        switch items.count {
        case 0: return ""
        case 1: return items[0]
        case 2: return "\(items[0]) and \(items[1])"
        default: return "\(items.dropLast().joined(separator: ", ")) and \(items[items.count - 1])"
        }
    }

    /// What the primary button says. It never reads as a dead end: a blocked machine is offered
    /// another look rather than a closed door.
    var primaryButtonTitle: String {
        switch verdict {
        case .checking: "Checking"
        case .ready, .readyWithNotes: "Start using Bloom"
        case .blocked: "Check again"
        }
    }
}

// MARK: - Whether the window opens at all

/// Why the welcome window came up, or that it did not.
public enum OnboardingTrigger: Sendable, Hashable {
    /// Nobody has finished it on this copy of Bloom yet.
    case firstRun
    /// It has been finished before, and this machine cannot start a workspace today.
    case blocked
    case none
}

/// When the welcome window opens on its own.
///
/// The flag behind `hasCompletedBefore` lives in `UserDefaults` rather than in `Store`, and that
/// is a decision rather than a shrug. `make dev-db` copies the real database into the dev copy
/// wholesale, so a flag kept in SQLite would arrive in a brand new dev build already set by the
/// owner's install, and the window nobody could then get back is exactly the window somebody went
/// to look at. `UserDefaults` is per bundle id, which is per copy of the app, which is the scope
/// this fact actually has. It is also not workspace data, and `Store` is workspace data.
public enum OnboardingGate {
    public static let completedKey = "onboarding.completed"

    /// `verdict` is nil at the moment of a first launch, because a first launch opens the window
    /// before any probe has finished: the checks settling one by one is the thing worth seeing,
    /// and it cannot be seen if the window waits for them. On every later launch the verdict is
    /// known first and the window stays shut unless the machine is actually broken.
    public static func trigger(hasCompletedBefore: Bool, verdict: SetupVerdict?) -> OnboardingTrigger {
        guard hasCompletedBefore else { return .firstRun }
        return verdict == .blocked ? .blocked : .none
    }
}
