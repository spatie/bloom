import Foundation

/// Keeping Spotlight out of the worktrees.
///
/// A workspace is a full checkout, and a checkout that has been built in holds `vendor/`,
/// `node_modules/`, `.build/` and whatever else the project's toolchain unpacks: tens of thousands
/// of files that nobody has ever searched for by content, rewritten every time a test run touches
/// them. `mds` and `mdworker` re-read all of it, on a machine already running several agents, and
/// the owner watched that cost turn up as CPU. Twenty worktrees multiply it by twenty.
///
/// The alternative offered was System Settings, Spotlight, Privacy, add `~/bloom/workspaces`. That
/// works and it is a thing a person has to remember, on every Mac they use, after Bloom has
/// already made the directory. Bloom made it, so Bloom marks it.
///
/// **`.metadata_never_index` inside an ordinary directory rather than `.noindex` on its name.**
/// The suffix is the mechanism Apple documents, and it is unusable here twice over: the workspaces
/// root's absolute path is stored in every `workspaces` row and in git's own worktree admin files,
/// so renaming it would strand every checkout in it, and a worktree's own directory is named after
/// its branch. The marker file is what is left, and it was measured before it was written rather
/// than taken on trust: this Mac has carried one in `~/dev/code` since June, and against 3,236
/// directories under it Spotlight returns nothing at all, for a name query, for a content query,
/// and for everything created since. See `SpotlightExclusionTests` for what the marker's contract
/// is here, which is the writing of it and not Spotlight's half.
///
/// **The root only, and never one per worktree.** Exclusion covers the whole subtree, which is the
/// property the measurement above rests on, so a marker in each project's folder would be dozens
/// of files saying what one already says. It also means a marker is in place before the first
/// worktree is cut, rather than after each one has already been indexed.
///
/// **Nowhere else needs one.** The agent scratch is under `NSTemporaryDirectory()`, the database
/// and the settings are under `~/Library/Application Support`, and macOS excludes both of those
/// already; attachments live inside a worktree, so the root above covers them; and an archived
/// workspace is a worktree that has been removed, with no directory of its own to mark.
public enum SpotlightExclusion {
    /// The marker Spotlight reads. Empty: only the name carries meaning.
    public static let markerName = ".metadata_never_index"

    /// What marking a directory did, so a test can tell "already there" from "just written" and
    /// from "could not". Nothing acts on this: it is an optimisation reporting itself.
    public enum Outcome: Equatable, Sendable {
        case written
        case alreadyMarked
        case noSuchDirectory
        case refused
    }

    public static func markerPath(in directory: String) -> String {
        (directory as NSString).appendingPathComponent(markerName)
    }

    /// Puts the marker in `directory`, if it is not there already.
    ///
    /// **An existing file of that name is left exactly as it is**, whatever is in it. Somebody
    /// may have put one there by hand, which is precisely what the owner did the day this was
    /// asked for, and a marker Bloom overwrites is a file Bloom destroyed to write the same thing.
    ///
    /// **Failing is not an error anybody hears about.** A read-only home directory, a sandbox that
    /// refuses the write, a directory owned by somebody else: every one of them ends with Spotlight
    /// indexing worktrees the way it did before this existed, which is where the app was last week.
    /// There is nothing for a person to do about it and nothing to interrupt them for, so the
    /// outcome is returned for a test to read and discarded everywhere else.
    ///
    /// - Parameter creatingIt: make `directory` first. False at launch, where the point is to catch
    ///   an installation that already has a workspaces root; true on the path that is about to fill
    ///   it, so the marker lands before the files do rather than after.
    @discardableResult
    public static func mark(_ directory: String, creatingIt: Bool = false) -> Outcome {
        let manager = FileManager.default
        if creatingIt {
            try? manager.createDirectory(atPath: directory, withIntermediateDirectories: true)
        }

        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: directory, isDirectory: &isDirectory), isDirectory.boolValue else {
            return .noSuchDirectory
        }

        let marker = markerPath(in: directory)
        if manager.fileExists(atPath: marker) { return .alreadyMarked }

        // Not atomically. `write(toFile:atomically:)` writes a neighbour and renames it, which
        // needs a name of its own in a directory whose entries are worktrees git is holding open.
        // The file is empty and its content is never read, so there is nothing a half written one
        // could say wrongly.
        guard manager.createFile(atPath: marker, contents: Data()) else { return .refused }
        return .written
    }

    /// The one directory on this Mac that gets it.
    @discardableResult
    public static func markWorkspacesRoot(creatingIt: Bool = false) -> Outcome {
        mark(WorkspaceManager.workspacesRoot.path, creatingIt: creatingIt)
    }
}
