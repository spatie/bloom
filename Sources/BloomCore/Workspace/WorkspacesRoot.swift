import Foundation

/// Which folder under the home directory is Bloom's workspaces root, decided from what is already
/// on disk.
///
/// `WorkspaceManager.workspacesRoot` is the name everything calls. This is the rule underneath it,
/// pure, with `exists` a closure rather than a `FileManager` call for the reason
/// `WorktreePath.free` gives: the disk is the only authority on this, and the rule has to be
/// answerable in a test that owns a temporary directory instead of somebody's home folder.
///
/// **Why there are two names at all.** A worktree carries a `vendor/`, a `node_modules/` or a
/// `.build/`, and dozens of worktrees of the same project carry dozens of copies of it. Spotlight
/// walks every one, by name and by content, on every build, for a result nobody ever searches
/// for. The documented way to opt out of that is a `.metadata_never_index` marker file, and it
/// does not work: measured on this Mac on macOS 27.0, a directory carrying that marker was
/// indexed by name and by content, as was one carrying `.metadata_never_index_unless_rootfs`. The
/// literal appears in CoreServices only inside `mds`'s per-volume policy region and never in the
/// file-walking path, and `mdutil` says so itself, "Indexing and searching disabled because of
/// \".metadata_never_index\" file at root of volume". It is a volume-root mechanism. That branch
/// is closed and is not worth reopening.
///
/// What does work, tested in the same run, is the folder's NAME ending `.noindex`: it was still
/// unindexed four minutes in, against thirty seconds for the control beside it. It is what Xcode
/// relies on for `Build/Intermediates.noindex` and `ModuleCache.noindex`.
///
/// **Nothing is ever renamed on disk, and this rule is why the new name can arrive without one.**
/// A worktree's location is recorded in three places at once: the `workspaces` row, the `gitdir`
/// file inside the worktree, and the admin file git keeps under the parent repository. Moving one
/// means rewriting all three and running `git worktree repair`, and getting any part of that wrong
/// strands work that exists only in that checkout. A symlink from the old name to the new is not
/// the way round it either: `git rev-parse --show-toplevel` resolves symlinks, so git would report
/// one path while the database held another, which is the class of bug `WorkspaceManager` is
/// written to avoid. So an install that has a root keeps it, forever.
public enum WorkspacesRoot {
    /// What a new installation gets.
    public static let preferredName = "bloom/workspaces.noindex"

    /// What every installation made before this got, and the only other answer this gives.
    public static let legacyName = "bloom/workspaces"

    /// The rule, in full:
    ///
    /// 1. If `~/bloom/workspaces.noindex` is there, that is the root.
    /// 2. Otherwise, if `~/bloom/workspaces` is there, that is the root. This is the whole of what
    ///    an existing install sees: it has dozens of worktrees in that folder, its path is in
    ///    every `workspaces` row and in git's own admin files, and new worktrees landing somewhere
    ///    else would leave one project's checkouts split across two places for no gain, since
    ///    nothing already indexed becomes unindexed by moving the folder new ones go into.
    /// 3. Otherwise there is no root yet, and the one about to be created is the `.noindex` one.
    ///
    /// The order is what makes the answer stable rather than what makes it right, and both cases
    /// need saying. An existing install has no `.noindex` folder, so rule 1 misses and rule 2
    /// answers, which is the requirement. A new install answers rule 3 once, and from the first
    /// worktree onwards answers rule 1, because git created the folder on the way to cutting it;
    /// asking for the legacy name first would mean an empty `~/bloom/workspaces` appearing later,
    /// by any hand at all, moving new worktrees away from the ones already cut. Preferring the
    /// `.noindex` name also leaves an install that wants the new behaviour a way to ask for it
    /// that costs nothing and moves nothing: make the folder, and new worktrees go in it.
    public static func resolve(home: URL, exists: (URL) -> Bool) -> URL {
        let preferred = home.appendingPathComponent(preferredName, isDirectory: true)
        if exists(preferred) { return preferred }

        let legacy = home.appendingPathComponent(legacyName, isDirectory: true)
        if exists(legacy) { return legacy }

        return preferred
    }

    /// The same rule, asking this Mac.
    ///
    /// A directory and not merely something of that name: a plain file called `workspaces` would
    /// be answered "yes" by `fileExists` alone, and the root git is then handed is one it cannot
    /// create a worktree under.
    public static func resolve(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        resolve(home: home) { url in
            var isDirectory: ObjCBool = false
            let there = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            return there && isDirectory.boolValue
        }
    }

    /// The sentence the Settings row puts under the path, so that somebody who reads about the
    /// `.noindex` folder and does not have one can find out why in the place that names theirs.
    ///
    /// Here rather than in the view for the reason the whole three-target split exists: which of
    /// the two things is true of this install is a decision, and a decision taken inside a `View`
    /// is a decision nothing can test.
    public static func note(for root: URL) -> String {
        if root.lastPathComponent.hasSuffix(".noindex") {
            return "The name ends .noindex, which is what keeps Spotlight out of the dependencies "
                + "and build folders inside every worktree."
        }
        return "New installations use a folder named .noindex, which keeps Spotlight out of the "
            + "dependencies and build folders inside every worktree. This one keeps the folder it "
            + "already has, because moving a worktree would break the path git and Bloom both "
            + "hold for it."
    }
}
