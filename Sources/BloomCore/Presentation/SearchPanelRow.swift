import Foundation

/// One line of the panel, whatever kind of thing it names.
///
/// Four cases and one flat array, because the arrow keys walk the drawn order rather than four
/// lists that would each need their own end. The section headings are not rows: they are not
/// selectable, so putting them in the same array would mean every key handler skipping them, which
/// is the rule `SearchPanelListing` keeps by holding both shapes rather than deriving one from the
/// other.
public enum SearchPanelRow: Equatable, Sendable, Identifiable {
    case workspace(SearchPanelWorkspaceHit)
    case transcript(SearchPanelTranscriptHit)
    case command(SearchPanelCommandHit)
    case fallback(SearchPanelFallback)

    /// Namespaced by kind, because a workspace row and the transcript row for the same workspace
    /// are two rows in one list and a shared id would make a `ForEach` draw one of them twice.
    public var id: String {
        switch self {
        case .workspace(let hit): "workspace:\(hit.workspace.id.rawValue)"
        case .transcript(let hit): "transcript:\(hit.result.workspaceID.rawValue)"
        case .command(let hit): "command:\(hit.item.action.rawValue)"
        case .fallback(let fallback): "fallback:\(fallback.id)"
        }
    }

    /// The workspace this row would push into on Cmd+Return, or nothing when it has no menu of
    /// its own. A transcript hit answers with its workspace: the row names one, and the menu on it
    /// is the same menu the sidebar offers.
    ///
    /// **An archived workspace has one too**, and it is the shorter menu Home already draws for
    /// one: Copy Name, Copy Branch Name, Restore. Which items that is is
    /// `WorkspaceMenuSubject.allows`, so nothing here has to know that a worktree is gone.
    public var drillable: WorkspaceID? {
        switch self {
        case .workspace(let hit): hit.workspace.id
        case .transcript(let hit): hit.result.workspaceID
        case .command, .fallback: nil
        }
    }
}

/// A workspace that matched, and why it is in the list.
public struct SearchPanelWorkspaceHit: Equatable, Sendable, Identifiable {
    public var workspace: Workspace
    public var repo: Repo?
    /// Character offsets into `workspace.name` that the query matched, ascending, drawn the way
    /// `SlashCommandRow` draws them. Empty when something other than the name matched, and empty
    /// when the offsets could not be trusted: see `FuzzyMatch.Hit.positions`.
    public var highlights: [Int]
    /// The text that put this row in the list when it was not the name, so a row matched on its
    /// branch says so rather than looking unrelated to what was typed.
    public var match: String?
    public var isArchived: Bool
    /// Why this row is in the resting list. Nil in a search, where the query is the reason.
    public var waiting: SearchPanelWaiting?
    public var score: Int

    public var id: WorkspaceID { workspace.id }

    public init(
        workspace: Workspace,
        repo: Repo? = nil,
        highlights: [Int] = [],
        match: String? = nil,
        isArchived: Bool = false,
        waiting: SearchPanelWaiting? = nil,
        score: Int = 0
    ) {
        self.workspace = workspace
        self.repo = repo
        self.highlights = highlights
        self.match = match
        self.isArchived = isArchived
        self.waiting = waiting
        self.score = score
    }
}

/// The two ways a workspace can be waiting on a person, which the resting list leads with.
///
/// Slack's quick switcher shows unread conversations and caps them, having found that listing
/// every channel was crushing on a large team. Bloom knows something better than unread: whether
/// the agent stopped to ask a question, or whether it finished and nobody has read it. Somebody
/// running eight agents opens this panel already wanting to know which one wants them.
public enum SearchPanelWaiting: String, Equatable, Sendable {
    /// The agent is blocked on an answer.
    case askedAQuestion
    /// The turn ended and the transcript has not been read.
    case turnFinished

    public var label: String {
        switch self {
        case .askedAQuestion: "asked a question"
        case .turnFinished: "turn finished"
        }
    }
}

/// A workspace whose transcript matched, with the best few lines already folded into it by
/// `TranscriptSearch.group`.
public struct SearchPanelTranscriptHit: Equatable, Sendable, Identifiable {
    public var result: TranscriptWorkspaceMatches
    /// Nil when the workspace has been deleted since the index was written, which is a row the
    /// builder drops rather than draws.
    public var workspace: Workspace?
    public var repo: Repo?
    public var isArchived: Bool

    public var id: WorkspaceID { result.workspaceID }

    public init(
        result: TranscriptWorkspaceMatches,
        workspace: Workspace?,
        repo: Repo?,
        isArchived: Bool
    ) {
        self.result = result
        self.workspace = workspace
        self.repo = repo
        self.isArchived = isArchived
    }
}

/// One menu bar item that matched, with the characters the query hit.
///
/// Whether it can be pressed right now is not here, for the reason `MenuBarCatalogue` gives about
/// `availability`: it depends on the live pane tree, on a running turn and on the responder chain,
/// none of which the core can hold. The app target asks the real menu and greys the row.
public struct SearchPanelCommandHit: Equatable, Sendable, Identifiable {
    public var item: MenuBarItem
    /// Offsets into `item.title`, as `SearchPanelWorkspaceHit.highlights` are into a name.
    public var highlights: [Int]
    public var score: Int

    public var id: MenuBarAction { item.action }

    public init(item: MenuBarItem, highlights: [Int] = [], score: Int = 0) {
        self.item = item
        self.highlights = highlights
        self.score = score
    }
}
