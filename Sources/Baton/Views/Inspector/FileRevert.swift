import Foundation
import BatonCore

/// Throwing away everything the agent did to one file.
///
/// This is the only destructive thing the inspector can do, so it is written as one type with one
/// entry point, and the sentence the confirmation shows is produced here as well. Keeping the
/// warning next to the command is what stops the two from describing different operations after
/// someone edits one of them.
enum FileRevert {
    /// What the user is about to lose, in the same voice as the archive confirmation: what
    /// disappears, not "are you sure?".
    static func losses(for file: ChangedFile, in workspace: Workspace, hasDraft: Bool) -> String {
        var text: String

        switch file.change {
        case .untracked:
            text = "\(file.path) is not tracked by git, so there is no version to go back to. "
                + "Reverting moves it to the Trash."
        case .added:
            text = "\(file.path) did not exist on \(workspace.baseBranch). Reverting deletes it."
        default:
            text = "Reverting restores \(file.path) to the version on \(workspace.baseBranch)."
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
    static func revert(file: ChangedFile, in workspace: Workspace) async -> String? {
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
            let base = try await Git.mergeBase(workspace.baseBranch, in: worktree)

            // A rename is two paths: the old one has to come back and the new one has to go, and
            // doing only half of it leaves the file present under both names.
            if file.change == .renamed, let oldPath = file.oldPath {
                try await git(["checkout", base, "--", oldPath], in: worktree)
                try await git(["rm", "-f", "--", file.path], in: worktree)
                return nil
            }

            if try await exists(file.path, at: base, in: worktree) {
                try await git(["checkout", base, "--", file.path], in: worktree)
            } else {
                // Added since the base, so there is nothing to restore and the file itself is
                // the change.
                try await git(["rm", "-f", "--", file.path], in: worktree)
            }
            return nil
        } catch let failure as Failure {
            return "Could not revert \(file.filename): \(failure.message)"
        } catch let error as ShellError {
            return "Could not revert \(file.filename): \(error.stderr)"
        } catch {
            return "Could not revert \(file.filename): \(error.localizedDescription)"
        }
    }

    private static func exists(_ path: String, at ref: String, in worktree: String) async throws -> Bool {
        let result = try await Shell.run(
            "git", ["cat-file", "-e", "\(ref):\(path)"], cwd: worktree, env: environment
        )
        return result.ok
    }

    /// `ShellError`'s memberwise initialiser is internal to BatonCore, and a failed revert only
    /// needs the one sentence anyway.
    private struct Failure: Error {
        var message: String
    }

    private static func git(_ arguments: [String], in worktree: String) async throws {
        let result = try await Shell.run("git", arguments, cwd: worktree, env: environment)
        guard result.ok else {
            let detail = result.stderr.isEmpty ? result.stdout : result.stderr
            throw Failure(message: detail.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    /// The same two variables `Git` sets, so a revert cannot be the one command that stops to ask
    /// for a password or fights the index lock the refresh loop is holding.
    private static let environment = [
        "GIT_TERMINAL_PROMPT": "0",
        "GIT_OPTIONAL_LOCKS": "0",
    ]
}
