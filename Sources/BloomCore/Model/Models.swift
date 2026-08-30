import Foundation

public func newID() -> String { UUID().uuidString.lowercased() }

// MARK: - Repo

public struct Repo: Identifiable, Sendable, Hashable, Codable {
    public var id: RepoID
    public var name: String
    public var path: String
    public var defaultBranch: String
    public var accent: String
    public var sortOrder: Int
    public var collapsed: Bool
    /// Whether the sidebar leaves this project out of the list unless it is asked to show the
    /// hidden ones. See `ProjectVisibility`, which is the rule, and note what it is NOT: a
    /// hidden project keeps every workspace it has, and those workspaces keep running, keep
    /// notifying, and keep turning up on Home, in search, in the menu bar and in Shortcuts. This
    /// column narrows one list.
    ///
    /// On the project rather than on the project and the machine, which is the same choice
    /// `collapsed` and `sortOrder` already made. Bloom's database is per machine already: there
    /// is one row per project per copy of Bloom, so a per-machine view preference and a
    /// per-project one are stored in exactly the same place, and a second key would only be
    /// worth its weight if the rows were ever synced between machines. They are not.
    public var hidden: Bool
    public var createdAt: Date
    /// Artwork the project already has on disk, absolute. Nil whenever the mark is the monogram.
    public var iconPath: String?
    /// Where `iconPath` came from, and whether Bloom has looked at all. See `RepoIconSource`.
    public var iconSource: RepoIconSource

    public init(
        id: RepoID = .new(),
        name: String,
        path: String,
        defaultBranch: String = "main",
        accent: String = Accent.all[0],
        sortOrder: Int = 0,
        collapsed: Bool = false,
        hidden: Bool = false,
        createdAt: Date = Date(),
        iconPath: String? = nil,
        iconSource: RepoIconSource = .undetected
    ) {
        self.id = id
        self.name = name
        self.path = path
        self.defaultBranch = defaultBranch
        self.accent = accent
        self.sortOrder = sortOrder
        self.collapsed = collapsed
        self.hidden = hidden
        self.createdAt = createdAt
        self.iconPath = iconPath
        self.iconSource = iconSource
    }

    /// Whether the sidebar should be drawing artwork rather than initials.
    ///
    /// Says nothing about whether the file is still there. That is answered where the file is
    /// read, and a file that has gone falls back to the monogram without changing what is stored:
    /// an unmounted volume is not the user changing their mind.
    public var hasIcon: Bool { iconPath != nil && iconSource.drawsIcon }
}

/// How a project came to have the mark it has.
///
/// Four cases rather than a flag, because "we have not looked yet" and "there is nothing to find"
/// are different answers, and because a picture the user chose must survive a redetection that a
/// picture Bloom guessed at should not.
public enum RepoIconSource: String, Sendable, Codable, CaseIterable, Hashable {
    /// Added before Bloom looked for icons, or added while detection was refused. Draws the
    /// monogram, and is the one state that invites the settings window to offer a search.
    case undetected
    /// Looked, and the monogram is the answer: either nothing was found or the user asked for it
    /// back. Never overwritten by a later detection without being asked.
    case monogram
    /// Found by `RepoIconDetector` when the project was added.
    case detected
    /// Picked by the user, and therefore the last word.
    case chosen

    public var drawsIcon: Bool {
        switch self {
        case .undetected, .monogram: false
        case .detected, .chosen: true
        }
    }
}

public enum Accent {
    /// Hex strings, kept as data so a repo colour can be persisted and restored.
    public static let all = [
        "4C8DF6", "22A06B", "E2725B", "9B6DE0", "D9A21B",
        "2FA8A8", "D8608C", "6C7A89", "E06C2A", "5B8C2A",
    ]

    public static func next(usedBy repos: [Repo]) -> String {
        let used = Set(repos.map(\.accent))
        return all.first { !used.contains($0) } ?? all[repos.count % all.count]
    }
}

// MARK: - Workspace

public enum WorkspaceState: String, Sendable, Codable, CaseIterable {
    case active
    case archived
}

/// How far the project's setup script has got in this worktree.
///
/// `CaseIterable` so `Store.recoverInterruptedSetups` can build its `WHERE` clause out of
/// `SetupLifecycle`'s table rather than restating it in SQL. The launch pass and the machine
/// disagreeing about which rows are interrupted is the drift that conformance rules out.
public enum SetupState: String, Sendable, Codable, CaseIterable, Hashable {
    case pending
    case running
    case succeeded
    case failed
    case skipped
}

public struct Workspace: Identifiable, Sendable, Hashable, Codable {
    public var id: WorkspaceID
    public var repoID: RepoID
    public var name: String
    public var branch: String
    public var path: String
    public var baseBranch: String
    /// Active or archived. **Read anywhere, written only through `archive(at:)` and
    /// `restore(to:hasSetupScript:)` in `WorkspaceLifecycle`,** because setting this on its own is
    /// not archiving: archiving is removing the worktree and then saying so, and a row that claims
    /// a workspace is live after its worktree has gone does not heal.
    ///
    /// `internal(set)` so that is a compile error in `Sources/Bloom` rather than a convention. See
    /// the house rule for the half the compiler cannot see, which is a new file inside the core.
    public internal(set) var state: WorkspaceState
    /// How far the setup script has got. **Read anywhere, written only through
    /// `apply(_: SetupEvent)`,** for the same reason and with the same `internal(set)` behind it:
    /// this state and `setupLog` are one statement, and `failed` with nothing to read is a
    /// half-truth the next reader treats as whole. See `SetupLifecycle`.
    public internal(set) var setupState: SetupState
    /// What the setup script printed, or the line explaining why there is nothing to read.
    /// Written by `apply(_: SetupEvent)` alongside the state it belongs to.
    public internal(set) var setupLog: String
    public var sortOrder: Int
    public var createdAt: Date
    public var lastActivityAt: Date
    public var archivedAt: Date?
    public var additions: Int
    public var deletions: Int
    public var changedFiles: Int
    public var unread: Bool
    public var pinned: Bool
    /// A colour the user put on this row so they can find it again, as a hex string, or nil.
    ///
    /// Nil is the normal case and has to look like nothing at all, which is why it is a nullable
    /// column rather than a default colour every workspace starts with. Stored as text rather than
    /// as an index into `WorkspaceColour.all`, so the list can be reordered or added to without
    /// silently recolouring every row that was already marked.
    public var colour: String?
    /// Who asked for this workspace: the owner, or an agent running in another workspace.
    ///
    /// Not a depth counter. The limit on how far this can nest is one, so "has a parent" IS the
    /// depth, and a number kept beside it is a number that can drift out of step with the parent
    /// it is supposed to describe.
    public var origin: WorkspaceOrigin
    /// The first of the ten ports this workspace holds, or 0 while it holds none.
    ///
    /// Stored rather than allocated fresh each launch, because a setup script writes this number
    /// into files that outlive the process: a `.env` with `APP_URL=http://localhost:3100`, a
    /// compose file, a Valet or Herd site. Reallocating on the next launch left those files
    /// naming a block nothing was listening on, and the dev server bound somewhere the browser
    /// was not looking. It is also what lets the archive script take down what the setup script
    /// put up, since both are handed the same `$BLOOM_PORT` for the same workspace.
    ///
    /// 0 means no block has been asked for yet, which is every row written before this column
    /// existed and every workspace whose repository has no script that wants one. Allocation is
    /// `WorkspaceManager.ensurePort`, and it is deliberately lazy: probing sixty-odd sockets for
    /// a workspace nothing will ever bind is work nobody asked for.
    public var port: Int

    /// A workspace as it is at rest: the three lifecycle columns spelled out.
    ///
    /// **Internal, and that is the whole of this rule's enforcement.** `state`, `setupState` and
    /// `setupLog` are `public internal(set)` so that nothing outside the module can assign one,
    /// but while this initialiser was public that bought nothing at all: any line in
    /// `Sources/Bloom` could build a fresh `Workspace` carrying an existing id and whatever state
    /// it liked and hand it to `Store.upsert`, which writes every column. One compiling statement
    /// archived a row without removing a worktree, which is the exact bug in `Store`'s head. So
    /// the two doors are separated: this one, which takes the states and lives inside the module
    /// with the lifecycles, and the public one below, which cannot say them.
    ///
    /// `Store.workspace(from:)` is the reader; `WorkspaceManager.createWorkspace` is the writer.
    ///
    /// The three keep their defaults so that nothing inside the module had to change. A call that
    /// names none of them is not ambiguous between the two: Swift prefers the overload that has
    /// fewer defaults left to apply, which is the public one, and it produces the same value.
    init(
        id: WorkspaceID = .new(),
        repoID: RepoID,
        name: String,
        branch: String,
        path: String,
        baseBranch: String,
        state: WorkspaceState = .active,
        setupState: SetupState = .pending,
        setupLog: String = "",
        sortOrder: Int = 0,
        createdAt: Date = Date(),
        lastActivityAt: Date = Date(),
        archivedAt: Date? = nil,
        additions: Int = 0,
        deletions: Int = 0,
        changedFiles: Int = 0,
        unread: Bool = false,
        pinned: Bool = false,
        colour: String? = nil,
        origin: WorkspaceOrigin = .user,
        port: Int = 0
    ) {
        self.id = id
        self.repoID = repoID
        self.name = name
        self.branch = branch
        self.path = path
        self.baseBranch = baseBranch
        self.state = state
        self.setupState = setupState
        self.setupLog = setupLog
        self.sortOrder = sortOrder
        self.createdAt = createdAt
        self.lastActivityAt = lastActivityAt
        self.archivedAt = archivedAt
        self.additions = additions
        self.deletions = deletions
        self.changedFiles = changedFiles
        self.unread = unread
        self.pinned = pinned
        self.colour = colour
        self.origin = origin
        self.port = port
    }

    /// A brand new workspace, which is the only kind anybody outside the module has any business
    /// making: live, its setup not yet run, and nothing to read in the log.
    ///
    /// There is no parameter for the three lifecycle columns because there is nothing to decide.
    /// A workspace that has just been made is `.active` with a `.pending` setup, every time, and
    /// moving it off that is `WorkspaceLifecycle` or `SetupLifecycle` doing the work first and
    /// then saying so. See the internal initialiser above for what happened when this was one
    /// door instead of two.
    public init(
        id: WorkspaceID = .new(),
        repoID: RepoID,
        name: String,
        branch: String,
        path: String,
        baseBranch: String,
        sortOrder: Int = 0,
        createdAt: Date = Date(),
        lastActivityAt: Date = Date(),
        additions: Int = 0,
        deletions: Int = 0,
        changedFiles: Int = 0,
        unread: Bool = false,
        pinned: Bool = false,
        colour: String? = nil,
        origin: WorkspaceOrigin = .user
    ) {
        self.init(
            id: id,
            repoID: repoID,
            name: name,
            branch: branch,
            path: path,
            baseBranch: baseBranch,
            state: .active,
            setupState: .pending,
            setupLog: "",
            sortOrder: sortOrder,
            createdAt: createdAt,
            lastActivityAt: lastActivityAt,
            archivedAt: nil,
            additions: additions,
            deletions: deletions,
            changedFiles: changedFiles,
            unread: unread,
            pinned: pinned,
            colour: colour,
            origin: origin,
            port: 0
        )
    }

    public var hasDiff: Bool { additions > 0 || deletions > 0 }
}

// MARK: - Session

/// What a chat is doing. `CaseIterable` so `Store.resetRunningSessions` can build its `WHERE`
/// clause out of `SessionLifecycle`'s table instead of restating it in SQL.
public enum SessionState: String, Sendable, Codable, CaseIterable, Hashable {
    case idle
    case running
    /// The agent asked to do something and is holding its turn open until somebody answers.
    ///
    /// Distinct from `running` because it is the opposite of running: the process is alive, the
    /// clock is going, and no work is happening. The CLI puts no timer on the question, so this
    /// state ends when a person ends it. A session in it is the one thing in Bloom that gets
    /// worse the longer it is left alone.
    case waiting
    case failed
    case cancelled
}

/// The rows in the composer's permission picker.
///
/// **The cases are Bloom's slots, and the words over them belong to whichever CLI is about to
/// run.** `PermissionVocabulary` holds those words and the reason there are two sets of them; the
/// order here is the order the menu draws, strictest first.
public enum PermissionMode: String, Sendable, Codable, CaseIterable {
    case auto
    case acceptEdits
    /// Approvals answered by the agent's own reviewer instead of by the person at the keyboard.
    ///
    /// **Added because Bloom had no row for it and a user said so.** Codex's four presets are
    /// `read-only`, `workspace`, `auto` and `full-access`, and Bloom offered three of them:
    /// `acceptEdits` sends the pair the Codex app labels "Ask for approval", so the preset that
    /// app labels "Approve for me" was not reachable from any row in the menu. On the wire it is
    /// `approvalsReviewer: auto_review`, which nothing in Bloom had ever sent.
    ///
    /// Codex only, and Claude Code loses nothing by that: `auto` already is this mode there, which
    /// is why `nearest(on:)` sends a chat carrying this one back to `auto` when it moves.
    case autoReview
    case bypassPermissions
    case plan

    /// The name with no backend said, which is Claude Code's, because that is what a chat is
    /// until somebody picks a model out of another section. `label(on:)` is the one to reach for
    /// wherever the agent is known.
    public var label: String { label(on: .claudeCode) }
}

public struct Session: Identifiable, Sendable, Hashable, Codable {
    public var id: SessionID
    /// The worktree this chat is having its conversation in, or nil when there is not one.
    ///
    /// **Nil is Ask Bloom and nothing else today.** That chat sits above every project, so there
    /// is no worktree for it to be about, and the column was `NOT NULL` until the rebuild in
    /// `Store.migrate` relaxed it. Everything that lists a workspace's chats filters by this and
    /// so never sees such a row, which is the whole reason a nullable column beat a sentinel
    /// workspace: the `workspaces` table's invariant is that a row in it is a real directory on
    /// disk, and the diff poll, the archive path and every git call believe it.
    public var workspaceID: WorkspaceID?
    /// The chat that started this one, when another agent did.
    ///
    /// **A chat with a parent is a crew member**, which the app calls a subagent: an agent the
    /// chat above it started in the same worktree, on the same branch, so that everything the two
    /// of them do lands in one diff. It is not a `child` in the bridge's sense, which is a
    /// workspace of its own with a branch and a pull request of its own. See `Crew`, whose head
    /// argues the difference and says why the word here is not "subagent".
    ///
    /// Nil for every chat the owner made, which is nearly all of them.
    public var parentSessionID: SessionID?
    public var title: String
    public var agentSessionID: String?
    public var model: String
    public var effort: String
    /// Which CLI drives this chat.
    ///
    /// **Per chat, not per workspace.** One worktree can hold a Claude Code conversation and a
    /// Codex one at the same time, editing the same files, which is already true of two Claude
    /// chats and is the reason this is not a column on `Workspace`. Anything keyed on "the
    /// workspace's agent" is wrong by construction.
    ///
    /// Every row that existed before this column defaults to Claude Code, because that is what
    /// every one of them was.
    public var agentKind: AgentKind {
        didSet { permissionMode = permissionMode.nearest(on: agentKind) }
    }
    /// How much this chat may do without asking.
    ///
    /// **It can only ever be a mode `agentKind` has a row for**, and the initialiser below is what
    /// makes that true of every value of this type, including the one `Store` builds from a row
    /// it has just read. A synthesised `init(from:)` is the one door that would go round this, and
    /// nothing in the app or the suite decodes a `Session`. Codex
    /// has no Plan and Claude Code has no Approve for me; a row written before this rule existed,
    /// or by a version that had a different one, would otherwise be drawn with no tick on any row
    /// of the picker while the wire carried something else again. See `PermissionMode.nearest(on:)`.
    ///
    /// The two observers hold the pair legal whichever of them is written, and in whichever order,
    /// so `sessionEditor.apply` setting a backend and a mode in one block cannot land a
    /// combination that does not exist. Writing inside a `didSet` does not run the observer again.
    public var permissionMode: PermissionMode {
        didSet { permissionMode = permissionMode.nearest(on: agentKind) }
    }
    /// What this chat is doing. **Read anywhere, written only through `apply(_: SessionEvent)`,**
    /// which stamps `updatedAt` in the same statement because a state change nothing downstream
    /// notices is not a state change. See `SessionLifecycle`.
    public internal(set) var state: SessionState
    public var sortOrder: Int
    public var createdAt: Date
    public var updatedAt: Date
    public var archivedAt: Date?
    public var lastReadSeq: Int
    public var inputTokens: Int
    public var outputTokens: Int
    public var costUSD: Double
    public var contextTokens: Int

    /// A chat as it is at rest, `state` spelled out. **Internal for the same reason
    /// `Workspace`'s is**, and read that one: `internal(set)` on the property stopped assignment
    /// and stopped nothing else, because a fresh value carrying an existing id and any state at
    /// all could be handed to the public `Store.upsert`, which writes every column.
    init(
        id: SessionID = .new(),
        workspaceID: WorkspaceID?,
        parentSessionID: SessionID? = nil,
        title: String = PaneNaming.chat,
        agentSessionID: String? = nil,
        model: String = AppDefaults.fallbackModel,
        effort: String = AppDefaults.fallbackEffort,
        agentKind: AgentKind = .claudeCode,
        permissionMode: PermissionMode = AppDefaults.fallbackPermissionMode,
        state: SessionState = .idle,
        sortOrder: Int = 0,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        archivedAt: Date? = nil,
        lastReadSeq: Int = 0,
        inputTokens: Int = 0,
        outputTokens: Int = 0,
        costUSD: Double = 0,
        contextTokens: Int = 0
    ) {
        self.id = id
        self.workspaceID = workspaceID
        self.parentSessionID = parentSessionID
        self.title = title
        self.agentSessionID = agentSessionID
        self.model = model
        self.effort = effort
        self.agentKind = agentKind
        // Through the rule rather than straight in. See the property's own note: this is the one
        // door every `Session` comes through, the ones `Store` builds from a row included.
        self.permissionMode = permissionMode.nearest(on: agentKind)
        self.state = state
        self.sortOrder = sortOrder
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.archivedAt = archivedAt
        self.lastReadSeq = lastReadSeq
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.costUSD = costUSD
        self.contextTokens = contextTokens
    }

    /// A brand new chat, which is `.idle` and has no other option. Moving it is
    /// `SessionLifecycle.apply`, which stamps `updatedAt` in the same statement.
    public init(
        id: SessionID = .new(),
        workspaceID: WorkspaceID?,
        parentSessionID: SessionID? = nil,
        title: String = PaneNaming.chat,
        agentSessionID: String? = nil,
        model: String = AppDefaults.fallbackModel,
        effort: String = AppDefaults.fallbackEffort,
        agentKind: AgentKind = .claudeCode,
        permissionMode: PermissionMode = AppDefaults.fallbackPermissionMode,
        sortOrder: Int = 0,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        lastReadSeq: Int = 0,
        inputTokens: Int = 0,
        outputTokens: Int = 0,
        costUSD: Double = 0,
        contextTokens: Int = 0
    ) {
        self.init(
            id: id,
            workspaceID: workspaceID,
            parentSessionID: parentSessionID,
            title: title,
            agentSessionID: agentSessionID,
            model: model,
            effort: effort,
            agentKind: agentKind,
            permissionMode: permissionMode,
            state: .idle,
            sortOrder: sortOrder,
            createdAt: createdAt,
            updatedAt: updatedAt,
            archivedAt: nil,
            lastReadSeq: lastReadSeq,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            costUSD: costUSD,
            contextTokens: contextTokens
        )
    }
}

// MARK: - Message

/// The coarse bucket a transcript row falls into. The detail lives in the stored JSON payload.
public enum MessageKind: String, Sendable, Codable {
    case user
    case assistantText
    case thinking
    case toolUse
    case toolResult
    /// A permission question, drawn where the call would have been. The live state of it, whether
    /// it is still waiting and what was said, lives in `permission_asks`; this row is the record
    /// that it was asked at all, and its position in the turn.
    case permissionAsk
    case result
    case error
    case system
    case notice
}

public struct Message: Identifiable, Sendable, Hashable {
    public var id: Int64
    public var sessionID: SessionID
    public var seq: Int
    public var kind: MessageKind
    public var payload: Data
    public var createdAt: Date
    public var durationMS: Int?
    /// For toolUse rows: the tool_use id, so a tool_result can find its parent.
    public var refID: String?

    public init(
        id: Int64 = 0,
        sessionID: SessionID,
        seq: Int,
        kind: MessageKind,
        payload: Data,
        createdAt: Date = Date(),
        durationMS: Int? = nil,
        refID: String? = nil
    ) {
        self.id = id
        self.sessionID = sessionID
        self.seq = seq
        self.kind = kind
        self.payload = payload
        self.createdAt = createdAt
        self.durationMS = durationMS
        self.refID = refID
    }
}

// MARK: - Terminal

public struct TerminalTab: Identifiable, Sendable, Hashable, Codable {
    public var id: TerminalTabID
    public var workspaceID: WorkspaceID
    public var title: String
    public var sortOrder: Int

    public init(id: TerminalTabID = .new(), workspaceID: WorkspaceID, title: String, sortOrder: Int = 0) {
        self.id = id
        self.workspaceID = workspaceID
        self.title = title
        self.sortOrder = sortOrder
    }
}

// MARK: - Pull request

public struct PullRequest: Sendable, Hashable, Codable {
    public enum Checks: String, Sendable, Codable {
        case none
        case pending
        case passing
        case failing
    }

    public var number: Int
    public var title: String
    public var url: String
    public var state: String
    public var isDraft: Bool
    public var mergeable: String?
    public var checks: Checks
    public var checksSummary: String
    public var reviewDecision: String?
    /// The head branch as GitHub knows it. Empty when the gh version in use did not report it.
    /// This is the branch merging deletes, so the confirmation names this one rather than the
    /// local checkout's idea of it.
    public var branch: String
    /// When it stopped being open, whether by merging or by being closed. Nil while it is open,
    /// and nil from a gh old enough not to report it.
    ///
    /// Kept for one decision: gh finds a pull request by branch NAME, and branch names are reused.
    /// A pull request that ended before the workspace asking about it was created belongs to an
    /// earlier life of that name. See `PullRequestOwnership`.
    public var closedAt: Date?

    public init(
        number: Int,
        title: String,
        url: String,
        state: String,
        isDraft: Bool = false,
        mergeable: String? = nil,
        checks: Checks = .none,
        checksSummary: String = "",
        reviewDecision: String? = nil,
        branch: String = "",
        closedAt: Date? = nil
    ) {
        self.number = number
        self.title = title
        self.url = url
        self.state = state
        self.isDraft = isDraft
        self.mergeable = mergeable
        self.checks = checks
        self.checksSummary = checksSummary
        self.reviewDecision = reviewDecision
        self.branch = branch
        self.closedAt = closedAt
    }
}

// MARK: - Agent CLIs

/// The coding agent CLIs Bloom knows how to talk about.
///
/// Two of the four can drive a chat. The others are detected and configurable so the settings
/// screen can be honest about what is installed and what is not.
///
/// **A chat picks one of these, not a workspace.** One worktree can hold a Claude Code
/// conversation and a Codex one at the same time. See `Session.agentKind` and docs/CODEX.md.
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

    /// Absolute path to the file the settings screen offers to open.
    ///
    /// Claude Code and Codex point at a real config file. Cursor and OpenCode point at their
    /// config directory instead, because their file layout is not verified and guessing a
    /// filename would send the user to something that does not exist.
    public var configPath: String {
        let home = NSHomeDirectory()
        switch self {
        case .claudeCode: return "\(home)/.claude/settings.json"
        case .codex: return "\(home)/.codex/config.toml"
        case .cursor: return "\(home)/.cursor"
        case .openCode: return "\(home)/.opencode"
        }
    }

    /// Interactive, so it has to be handed to a terminal rather than run inline.
    public var loginCommand: String {
        switch self {
        case .claudeCode: "claude /login"
        case .codex: "codex login"
        case .cursor: "cursor-agent login"
        case .openCode: "opencode auth login"
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
