import Foundation

/// What a workspace's folder is: a worktree Bloom cut for it, or the project's own checkout.
///
/// **Every workspace used to be a worktree, and most of the app still says so in its behaviour.**
/// Archiving runs the project's archive script and removes the folder, restoring cuts a fresh
/// worktree, a placeholder name renames the branch, a merged pull request moves the worktree to a
/// new branch. All of that is right for a folder Bloom made and owns, and every one of it is
/// destructive in the project's own checkout: the archive script of a Laravel project drops the
/// database the owner develops against, `deleteBranch` would take `main`, and renaming would turn
/// `main` into a sentence about the first prompt. So the kind is stated on the row and asked at
/// each of those doors, and the properties below are the answers, one per door, so that the doors
/// cannot come to disagree about what a project checkout is.
///
/// **Stored, never derived from `path == repo.path`.** `Tools/dev-db.sh` rewrites every workspace
/// path in the dev copy so that it cannot reach a real folder, and a rule keyed on the path would
/// quietly turn a project checkout into a worktree there, which is the copy every change is tried
/// in first.
public enum WorkspaceKind: String, Sendable, Hashable, Codable, CaseIterable {
    /// A worktree Bloom cut for this workspace, on a branch of its own.
    case worktree
    /// The project's own checkout at `Repo.path`, on whatever branch it is on.
    case projectCheckout = "project_checkout"

    /// What a project checkout is called when it is made. A worktree is named by its prompt, by a
    /// codename or by whoever made it; this one is the same folder every time, and a model naming
    /// it after the first prompt would also rename the branch it is standing on.
    public static let projectCheckoutName = "Project checkout"

    /// The name to create a workspace of this kind under, or nil when the usual naming applies.
    public var suppliedName: String? {
        switch self {
        case .worktree: nil
        case .projectCheckout: Self.projectCheckoutName
        }
    }

    /// Whether archiving leaves the folder, the branch and the archive script alone and only marks
    /// the row. Answered through `WorkspaceManager.preservesFolderWhenArchiving`, the door a folder
    /// git no longer recognises already takes.
    public var preservesFolderOnArchive: Bool { self == .projectCheckout }

    /// Whether `branch` and `baseBranch` follow whatever the folder has checked out. A worktree's
    /// branch is its own and a checkout elsewhere is somebody else's business; the project checkout
    /// is moved by the owner in a terminal, and the row has to go where the folder went.
    public var followsHead: Bool { self == .projectCheckout }

    /// Whether the project's setup script may run here. It prepares a fresh worktree, and the
    /// project checkout is the folder it was written from.
    public var allowsSetup: Bool { self == .worktree }

    /// Whether run scripts marked to start on their own do. In the project checkout the owner's
    /// own dev server is usually already running on its own port, and a second one Bloom started
    /// beside it on another would be one nobody asked for.
    public var autostartsRunScripts: Bool { self == .worktree }

    /// Whether this workspace has pull requests: creating one, merging one, carrying on after one.
    /// The project checkout's branch is usually the default branch, and when it is not, the owner
    /// is already working on that branch outside Bloom.
    public var hasPullRequests: Bool { self == .worktree }

    /// The permission mode a new chat here starts in, given the one the defaults chose.
    ///
    /// The project checkout never starts a chat on "Bypass permissions": in a worktree that mode
    /// risks a copy, here it runs every command unasked in the owner's only working copy, against
    /// the database they develop with. It starts on Auto instead, which on Claude Code checks each
    /// call for risk and on Codex is read only, and the owner can switch in the composer as
    /// anywhere else. Every other default is left alone. Asked of a chat at the moment it is made,
    /// so a mode somebody picks afterwards is never overruled.
    public func startingPermission(_ mode: PermissionMode) -> PermissionMode {
        self == .projectCheckout && mode == .bypassPermissions ? .auto : mode
    }
}

public extension WorkspaceKind {
    /// The live project checkout of one project, if it has one.
    ///
    /// At most one exists, which the database holds with a unique index, so the first match is
    /// the answer. `excluding` is for the row asking about itself, which is restore.
    static func liveProjectCheckout(
        in repoID: RepoID, among workspaces: [Workspace], excluding: WorkspaceID? = nil
    ) -> Workspace? {
        workspaces.first {
            $0.kind == .projectCheckout && $0.repoID == repoID && $0.state == .active
                && $0.id != excluding
        }
    }
}
