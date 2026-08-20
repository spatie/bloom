import Foundation

public func newID() -> String { UUID().uuidString.lowercased() }

// MARK: - Repo

public struct Repo: Identifiable, Sendable, Hashable, Codable {
    public var id: String
    public var name: String
    public var path: String
    public var defaultBranch: String
    public var accent: String
    public var sortOrder: Int
    public var collapsed: Bool
    public var createdAt: Date
    /// Artwork the project already has on disk, absolute. Nil whenever the mark is the monogram.
    public var iconPath: String?
    /// Where `iconPath` came from, and whether Bloom has looked at all. See `RepoIconSource`.
    public var iconSource: RepoIconSource

    public init(
        id: String = newID(),
        name: String,
        path: String,
        defaultBranch: String = "main",
        accent: String = Accent.all[0],
        sortOrder: Int = 0,
        collapsed: Bool = false,
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

public enum SetupState: String, Sendable, Codable {
    case pending
    case running
    case succeeded
    case failed
    case skipped
}

public struct Workspace: Identifiable, Sendable, Hashable, Codable {
    public var id: String
    public var repoID: String
    public var name: String
    public var branch: String
    public var path: String
    public var baseBranch: String
    public var state: WorkspaceState
    public var setupState: SetupState
    public var setupLog: String
    public var sortOrder: Int
    public var createdAt: Date
    public var lastActivityAt: Date
    public var archivedAt: Date?
    public var additions: Int
    public var deletions: Int
    public var changedFiles: Int
    public var unread: Bool
    public var pinned: Bool

    public init(
        id: String = newID(),
        repoID: String,
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
        pinned: Bool = false
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
    }

    public var hasDiff: Bool { additions > 0 || deletions > 0 }
}

// MARK: - Session

public enum SessionState: String, Sendable, Codable {
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

public enum PermissionMode: String, Sendable, Codable, CaseIterable {
    case auto
    case acceptEdits
    case bypassPermissions
    case plan

    public var label: String {
        switch self {
        case .auto: "Ask"
        case .acceptEdits: "Accept edits"
        case .bypassPermissions: "Full access"
        case .plan: "Plan"
        }
    }
}

public struct Session: Identifiable, Sendable, Hashable, Codable {
    public var id: String
    public var workspaceID: String
    public var title: String
    public var agentSessionID: String?
    public var model: String
    public var effort: String
    public var permissionMode: PermissionMode
    public var state: SessionState
    public var sortOrder: Int
    public var createdAt: Date
    public var updatedAt: Date
    public var archivedAt: Date?
    public var lastReadSeq: Int
    public var inputTokens: Int
    public var outputTokens: Int
    public var costUSD: Double
    public var contextTokens: Int

    public init(
        id: String = newID(),
        workspaceID: String,
        title: String = "New session",
        agentSessionID: String? = nil,
        model: String = "opus",
        effort: String = "high",
        permissionMode: PermissionMode = .acceptEdits,
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
        self.title = title
        self.agentSessionID = agentSessionID
        self.model = model
        self.effort = effort
        self.permissionMode = permissionMode
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
    public var sessionID: String
    public var seq: Int
    public var kind: MessageKind
    public var payload: Data
    public var createdAt: Date
    public var durationMS: Int?
    /// For toolUse rows: the tool_use id, so a tool_result can find its parent.
    public var refID: String?

    public init(
        id: Int64 = 0,
        sessionID: String,
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
    public var id: String
    public var workspaceID: String
    public var title: String
    public var sortOrder: Int

    public init(id: String = newID(), workspaceID: String, title: String, sortOrder: Int = 0) {
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
        branch: String = ""
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
    }
}

// MARK: - Agent CLIs

/// The coding agent CLIs Bloom knows how to talk about.
///
/// Only Claude Code can actually drive a workspace today, but the others are detected and
/// configurable so the settings screen can be honest about what is installed and what is not.
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

    /// Whether Bloom can actually drive a workspace with it. Only Claude Code today, because
    /// `AgentRunner` speaks the Claude Code stream-json protocol and nothing else.
    public var canRunWorkspaces: Bool { self == .claudeCode }
}
