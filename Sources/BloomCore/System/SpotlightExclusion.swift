import Foundation

/// The marker that tells Spotlight to leave a directory tree alone.
///
/// **The workspaces root is dozens of checkouts of the same repository.** Every one of them grows
/// a `vendor/`, a `node_modules/` or a `.build/`, all of it generated, none of it anything a
/// person searches for, and all of it rewritten by whichever agent is building right now. `mds`
/// wakes on those writes and reindexes them, which is real CPU spent on a copy of a tree it has
/// already indexed under the project the worktree was cut from.
///
/// The alternative is System Settings, Spotlight, Search Privacy, which is a list the owner has
/// to maintain by hand and which no fresh machine has. A file in the directory travels with the
/// directory, so a new install gets it the first time a worktree is cut.
///
/// **The name is the whole mechanism.** `.metadata_never_index` is what `mds` looks for, and it
/// excludes the directory it sits in and everything under it, so one at the root covers every
/// project and every worktree ever cut below it. The file's contents are never read, which is why
/// this writes an empty one.
public enum SpotlightExclusion {
    public static let markerName = ".metadata_never_index"

    /// Make sure `directory` exists and carries the marker.
    ///
    /// Best effort by design, and the return value says which way it went so a caller that cares
    /// can log it. Nothing here is worth failing a workspace creation over: the worst case of a
    /// marker that could not be written is a directory that gets indexed, which is where every
    /// machine starts anyway.
    @discardableResult
    public static func mark(_ directory: URL, using manager: FileManager = .default) -> Bool {
        let marker = directory.appendingPathComponent(markerName, isDirectory: false)
        if manager.fileExists(atPath: marker.path) { return true }
        do {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data().write(to: marker, options: .withoutOverwriting)
            return true
        } catch {
            // A race with another Bloom window doing the same thing lands here with the marker
            // already written, which is the outcome that was wanted.
            return manager.fileExists(atPath: marker.path)
        }
    }
}
