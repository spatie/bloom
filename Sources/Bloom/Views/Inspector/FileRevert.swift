import Foundation
import BloomCore

/// Throwing away everything the agent did to one file.
///
/// This is the only destructive thing the inspector can do, so it is written as one type with one
/// entry point, and the sentence the confirmation shows is produced here as well. Keeping the
/// warning next to the command is what stops the two from describing different operations after
/// someone edits one of them.
enum FileRevert {
    /// What the user is about to lose, in the same voice as the archive confirmation: what
    /// disappears, not "are you sure?".
    ///
    /// `base` is `Workspace.comparisonBase`, so the project checkout is told about `HEAD`, which
    /// is what its Discard restores from, rather than about a branch it may have left.
    static func losses(for file: ChangedFile, base: String, hasDraft: Bool) -> String {
        var text: String
        let place = base == "HEAD" ? "at HEAD" : "on \(base)"

        switch file.change {
        case .untracked:
            text = "\(file.path) is not tracked by git, so git has no copy of it. Discarding "
                + "moves it to the Trash, and the Trash is the only place it can be recovered from."
        case .added:
            text = "\(file.path) did not exist \(place). Discarding deletes it."
        default:
            text = "Discarding restores \(file.path) to the version \(place)."
        }

        let changed = file.additions + file.deletions
        if changed > 0 {
            text += "\n\nThis would lose:\n\u{2022} \(file.additions) added and "
                + "\(file.deletions) removed lines in \(file.filename)"
        }
        if hasDraft {
            text += "\n\u{2022} the unsaved edits you have open in Edit mode"
        }
        text += "\n\nThere is no undo for this."
        return text
    }

    /// Returns nil on success, or the sentence to put in front of the user.
    ///
    /// Untracked files go to the Trash rather than to `unlink`, because git has no copy of them
    /// and the Trash is the only recovery anybody gets. Everything else goes through git, so the
    /// index and the worktree end up agreeing.
    ///
    /// `expected` is the commit the list on screen was compared with, and Discard refuses when
    /// the base is no longer that commit. See `Git.revertTrackedFile`.
    static func revert(file: ChangedFile, in workspace: Workspace, expected: String?) async -> String? {
        let worktree = workspace.path
        let absolute = (worktree as NSString).appendingPathComponent(file.path)

        if file.change == .untracked {
            do {
                try FileManager.default.trashItem(
                    at: URL(fileURLWithPath: absolute), resultingItemURL: nil
                )
                return nil
            } catch {
                return "Could not move \(file.filename) to the Trash: \(error.localizedDescription)"
            }
        }

        do {
            try await Git.revertTrackedFile(
                file, worktree: worktree, base: workspace.comparisonBase, expected: expected
            )
            return nil
        } catch let error as ShellError {
            return "Could not discard \(file.filename): \(error.stderr)"
        } catch {
            return "Could not discard \(file.filename): \(error.localizedDescription)"
        }
    }

    /// One hunk rather than the whole file, through `Git.discardHunk`, which reads the patch again
    /// and writes nothing unless the hunk is still there and still applies. Nil on success.
    static func discard(
        hunk: DiffHunk, of file: ChangedFile, in workspace: Workspace, scope: DiffScope, expected: String?
    ) async -> String? {
        do {
            try await Git.discardHunk(
                hunk, of: file, worktree: workspace.path, base: workspace.comparisonBase, scope: scope,
                expected: expected
            )
            return nil
        } catch let error as ShellError {
            return error.stderr
        } catch {
            return error.localizedDescription
        }
    }

}
