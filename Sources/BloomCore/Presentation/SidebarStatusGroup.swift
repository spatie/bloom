import Foundation

/// The four things a workspace can be, when the pane is sorted by what it needs rather than by
/// where it lives.
///
/// The order of the cases is the order the sections are drawn in, and it is the argument this type
/// exists to make: **what you can act on comes before what is merely happening.** A finished turn
/// nobody has read is work waiting for a person, so it sits above an agent that is mid turn and
/// needs nothing from anybody. That is the one placement that surprised the owner enough to ask
/// about it, and it is deliberate.
///
/// Thirteen `WorkspaceStatus` cases collapse into four here, and the collapsing is the point. The
/// mark on a row says precisely what a workspace is; these sections say what to do about it, and
/// "draft pull request", "checks passed" and "no changes" are all the same answer: nothing, for now.
public enum SidebarStatusGroup: String, CaseIterable, Sendable, Hashable {
    /// Stopped until a person does something: a permission question, or a setup that failed.
    case needsYou
    /// A turn finished and nobody has read it.
    case readyToRead
    /// An agent has a turn open, or a worktree is still being cut.
    case working
    /// Everything else, which is most of the pane most of the time.
    case idle

    /// Which section a workspace belongs in, from the verdict its row's mark is already drawn from.
    ///
    /// Taking `WorkspaceStatus` rather than the workspace itself is what keeps one judgement in one
    /// place: whether an agent is running, whether GitHub has anything to say and which of the two
    /// wins are all decided by `WorkspaceStatus.resolve`, and a second copy of that precedence here
    /// is how the mark on a row and the section above it come to disagree.
    public static func of(_ status: WorkspaceStatus) -> Self {
        switch status {
        case .awaitingPermission, .setupFailed: .needsYou
        case .unread: .readyToRead
        case .running, .settingUp: .working
        // Every pull request state and both worktree states. A branch with changes, a draft, a
        // merge, red checks: all of them are things to look at when you choose to, and none of
        // them is the agent asking for you now. The mark on the row still tells them apart.
        case .merged, .closed, .conflicted, .checksFailing, .checksRunning, .checksPassed, .draft,
             .pullRequestOpen, .changed, .clean:
            .idle
        }
    }

    public var title: String {
        switch self {
        case .needsYou: "Needs you"
        case .readyToRead: "Ready to read"
        case .working: "Working"
        case .idle: "Idle"
        }
    }

    /// Whether this section can be folded away.
    ///
    /// Only `idle`, and only because of what it holds: a long tail of workspaces that are finished,
    /// parked or untouched, which is the one section that grows without anybody doing anything. The
    /// three above it are all short by construction and are the reason the pane is in this shape at
    /// all, so folding one would be hiding exactly what was asked for.
    public var isFoldable: Bool { self == .idle }

    /// How many rows `idle` has to reach before it is worth offering to fold it.
    ///
    /// Below this the control is furniture on a section you can read in one glance. It is a count
    /// rather than a height because the pane's row height is not ours to set: see `SidebarMetrics`.
    public static let foldThreshold = 4
}

/// The pane's sections, in order, with the workspaces in each.
///
/// A value rather than a function over the rows in a view body, because the rule underneath it is
/// the one that has to be tested: a workspace does NOT leave its section while it is the selected
/// row. Reading a finished turn, answering a permission question, or watching a turn end in the row
/// you are looking at would all otherwise move that row out from under the pointer, into a section
/// that may itself be folded. See `stuck`.
public struct SidebarStatusListing: Equatable, Sendable {
    public struct Section: Equatable, Sendable {
        public var group: SidebarStatusGroup
        public var workspaces: [Workspace]

        public init(group: SidebarStatusGroup, workspaces: [Workspace]) {
            self.group = group
            self.workspaces = workspaces
        }
    }

    public var sections: [Section]

    public init(sections: [Section]) {
        self.sections = sections
    }

    public static let empty = SidebarStatusListing(sections: [])

    /// Builds the sections.
    ///
    /// - Parameter workspaces: every workspace the pane is drawing, in the order projects and their
    ///   rows are already drawn in. That order is kept inside each section, so a pane sorted by
    ///   status still reads project by project inside a section rather than in an order nobody
    ///   chose.
    /// - Parameter status: the verdict for one workspace, which only the app layer can answer
    ///   because it alone knows what is running and what GitHub said.
    /// - Parameter stuck: the row that is selected, and the section it was in when it was selected.
    ///   It stays there until the selection moves. Nil when nothing in the pane is selected.
    public static func build(
        workspaces: [Workspace],
        status: (Workspace) -> WorkspaceStatus,
        stuck: StuckRow? = nil
    ) -> SidebarStatusListing {
        var byGroup: [SidebarStatusGroup: [Workspace]] = [:]
        for workspace in workspaces {
            let group = stuck?.id == workspace.id
                ? stuck?.group ?? SidebarStatusGroup.of(status(workspace))
                : SidebarStatusGroup.of(status(workspace))
            byGroup[group, default: []].append(workspace)
        }

        return SidebarStatusListing(
            sections: SidebarStatusGroup.allCases.compactMap { group in
                guard let rows = byGroup[group], !rows.isEmpty else { return nil }
                return Section(group: group, workspaces: rows)
            }
        )
    }

    /// The selected row and the section it is held in. See `build`.
    public struct StuckRow: Equatable, Sendable {
        public var id: WorkspaceID
        public var group: SidebarStatusGroup

        public init(id: WorkspaceID, group: SidebarStatusGroup) {
            self.id = id
            self.group = group
        }
    }
}
