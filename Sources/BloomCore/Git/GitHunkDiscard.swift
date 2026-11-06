import Foundation

extension Git {
    /// Reverses one hunk of `file`'s diff in `scope`, and nothing else in the file.
    ///
    /// **The hunk is looked up again rather than trusted.** The one on screen was parsed from a
    /// patch read up to six seconds ago, in a worktree an agent may have written since, so the
    /// patch is read afresh and the hunk has to be in it with the same coordinates and the same
    /// lines. Otherwise this refuses with `changed` and writes nothing.
    ///
    /// **Every target is checked before any is written.** `git apply` is all or nothing within one
    /// call, but a discard can be two calls, worktree and index, and a worktree reversed with the
    /// index refused is exactly the partial write this must not leave. `--check` answers for both
    /// first. The window between the checks and the writes is the time it takes to start two
    /// processes, and the control is disabled for the whole of an agent's turn, which is the only
    /// other writer this app knows about.
    ///
    /// `--whitespace=nowarn` because a repository with `apply.whitespace=error` would otherwise
    /// refuse to put back the trailing space somebody's old line had.
    ///
    /// `expected` is the baseline the diff on screen was drawn against, checked like
    /// `revertTrackedFile` checks it. Only the branch scope resolves one; the uncommitted scope is
    /// measured from `HEAD` itself and a moved `HEAD` already shows up as a hunk that is not there.
    public static func discardHunk(
        _ hunk: DiffHunk, of file: ChangedFile, worktree: String, base: String, scope: DiffScope,
        intent: HunkDiscard.Intent = .discard, expected: String? = nil
    ) async throws {
        let availability = HunkDiscard.availability(
            file: file, scope: scope, ignoringWhitespace: false, agentIsRunning: false
        )
        guard availability == .enabled, let targets = HunkDiscard.targets(for: file.layer, intent: intent) else {
            throw HunkDiscardRefusal.notOffered
        }
        if let expected, scope == .all, try await baseline(base, in: worktree) != expected {
            throw StaleDiffTarget()
        }

        let current = try await patch(worktree: worktree, base: base, file: file, scope: scope)
        guard let isolated = HunkPatch.isolate(hunk, from: current) else {
            throw HunkDiscardRefusal.changed
        }

        let reverse = ["apply", "--reverse", "--whitespace=nowarn"]
        var writes: [[String]] = []
        for (requirement, flags) in [(targets.worktree, [String]()), (targets.index, ["--cached"])] {
            guard requirement != .untouched else { continue }
            let checked = try await run(reverse + flags + ["--check"], in: worktree, stdin: isolated)
            if checked.ok {
                writes.append(reverse + flags)
            } else if requirement == .required {
                throw HunkDiscardRefusal.doesNotApply(checked.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }

        for arguments in writes {
            try await check(arguments, in: worktree, stdin: isolated)
        }
    }
}
