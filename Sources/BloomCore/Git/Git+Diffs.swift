import Foundation

/// What a worktree has changed, counted the way the inspector and the sidebar show it.
///
/// Every call in this file runs git with `-z` and parses the bytes rather than the text. A path
/// is a byte string that may hold a tab or a newline and need not decode as UTF-8 at all, and
/// git's default output C-quotes anything that is not plain ASCII, so splitting the decoded
/// `String` on tabs gets both wrong.
///
/// `LocalWork` is here rather than in `Git+Safety.swift` because it is the cheap question, the
/// one a pull request strip can afford to ask beside a poll. Its own comment has the difference.
///
/// `ChangedFile` below is one entry of the answer: a path, what happened to it, and the counts.
public struct ChangedFile: Identifiable, Sendable, Hashable {
    public enum Change: String, Sendable {
        case added = "A"
        case modified = "M"
        case deleted = "D"
        case renamed = "R"
        case copied = "C"
        case untracked = "?"
    }

    public var path: String
    public var oldPath: String?
    public var change: Change
    public var additions: Int
    public var deletions: Int
    public var isBinary: Bool

    public var id: String { path }

    public var filename: String { (path as NSString).lastPathComponent }
    public var directory: String { (path as NSString).deletingLastPathComponent }

    public init(
        path: String,
        oldPath: String? = nil,
        change: Change,
        additions: Int = 0,
        deletions: Int = 0,
        isBinary: Bool = false
    ) {
        self.path = path
        self.oldPath = oldPath
        self.change = change
        self.additions = additions
        self.deletions = deletions
        self.isBinary = isBinary
    }
}

/// What this worktree is holding that GitHub has not been told about.
///
/// The question a pull request strip has to answer alongside GitHub's own: is the branch on the
/// server still the work that is on this disk. Every state GitHub reports ("checks passed",
/// "ready to merge") is about a commit that was pushed, and the moment anything is edited or
/// committed afterwards those states describe something that no longer exists here.
///
/// Deliberately NOT `WorkspaceSafetyReport`. That one asks "what would deleting this worktree
/// destroy", and its `unpushedCommits` means "reachable from this branch and from no other ref",
/// which counts a commit as safe when a tag or another local branch happens to point at it. That
/// is the right question before an archive and the wrong one here: a commit sitting on a local
/// tag is still a commit GitHub does not have. It is also expensive, walking every ref in the
/// repository and byte-comparing every ignored file, which is not something to run beside a poll.
public struct LocalWork: Sendable, Hashable {
    /// Tracked files with changes that are not committed, staged or not.
    public var modifiedFiles: Int
    /// Files git has never been told about. Counted apart from the ones above because they are
    /// the half a reader is most likely to have meant to leave lying around.
    public var untrackedFiles: Int
    /// Commits on this branch that its upstream does not have. Zero when there is no upstream,
    /// which `hasUpstream` is what distinguishes.
    public var unpushedCommits: Int
    /// Whether this branch is tracking anything at all. False means it has never been pushed, so
    /// there is no count to give: everything on it is unpushed by definition.
    public var hasUpstream: Bool

    public init(
        modifiedFiles: Int = 0,
        untrackedFiles: Int = 0,
        unpushedCommits: Int = 0,
        hasUpstream: Bool = true
    ) {
        self.modifiedFiles = modifiedFiles
        self.untrackedFiles = untrackedFiles
        self.unpushedCommits = unpushedCommits
        self.hasUpstream = hasUpstream
    }

    /// Anything in the worktree that a push alone would not carry.
    public var hasUncommitted: Bool { modifiedFiles > 0 || untrackedFiles > 0 }

    /// Committed work the remote does not have.
    ///
    /// False on a branch with no upstream, and that is deliberate rather than an oversight: with
    /// nothing to compare against there is no count, and guessing one would be worse than saying
    /// nothing. The strip only ever asks this about a branch that already has a pull request, and
    /// a branch with a pull request has an upstream.
    public var hasUnpushed: Bool { hasUpstream && unpushedCommits > 0 }

    /// Whether GitHub's idea of this branch is out of date.
    public var isAhead: Bool { hasUncommitted || hasUnpushed }
}

extension Git {
    /// Files changed on this worktree relative to whatever the scope measures from, including
    /// uncommitted work and untracked files.
    ///
    /// The default scope is the whole of this workspace's work, measured from where the branch
    /// diverged from `base`, which is what every caller but the Changes tab wants. Untracked files
    /// belong to every scope: a file git has never seen is uncommitted whichever commit you are
    /// measuring from.
    ///
    /// Everything here runs with `-z` and is parsed from bytes. Git's default output C-quotes any
    /// path that is not plain ASCII and separates fields with tab and newline, both of which a
    /// path is allowed to contain. Splitting that text gave `"caf\303\251.txt"` for `café.txt`
    /// and cut a path containing a tab in half.
    ///
    /// Throws if any of the git calls fail, because an empty list has to mean "nothing changed"
    /// and never "we could not find out".
    public static func changedFiles(
        worktree: String, base: String, scope: DiffScope = .all
    ) async throws -> [ChangedFile] {
        let mergeBase = try await revision(for: scope, base: base, in: worktree)

        // Three walks of the same worktree, none of which reads another's output, all three taking
        // the merge base that is already resolved. Replaying these commands on this machine:
        // 50.7ms serial to 18.8ms together on a fresh worktree, 99.4ms to 47.6ms on a real one.
        // `GIT_OPTIONAL_LOCKS=0` is set on every one of them, so nothing here wants `index.lock`.
        async let nameStatusRead = checkRaw(
            ["diff", "--name-status", "-M", "-z", mergeBase, "--"], in: worktree
        )
        async let numstatRead = checkRaw(
            ["diff", "--numstat", "-M", "-z", mergeBase, "--"], in: worktree
        )
        async let untrackedRead = checkRaw(
            ["ls-files", "--others", "--exclude-standard", "-z"], in: worktree
        )

        let nameStatus = try await nameStatusRead
        let numstat = try await numstatRead
        let untracked = try await untrackedRead

        let changeByPath = parseNameStatus(nameStatus.stdout)
        var byPath = parseNumstat(numstat.stdout, changes: changeByPath)

        // Untracked files never appear in `git diff`, but they are absolutely part of the change.
        for record in nulRecords(untracked.stdout) {
            let path = String(decoding: record, as: UTF8.self)
            guard !path.isEmpty, byPath[path] == nil else { continue }
            let full = (worktree as NSString).appendingPathComponent(path)
            // Counted the way git counts. `components(separatedBy:)` returns an empty trailing
            // piece after the final newline, and since practically every text file ends in one,
            // every untracked file used to read one addition too many.
            let lineCount = (try? String(contentsOfFile: full, encoding: .utf8))
                .map(countLines) ?? 0
            byPath[path] = ChangedFile(
                path: path, change: .untracked, additions: lineCount, deletions: 0,
                isBinary: lineCount == 0 && FileManager.default.fileExists(atPath: full)
            )
        }

        return byPath.values.sorted { $0.path < $1.path }
    }

    /// `diff --name-status -z` records: a status field, then one path, except for `R`/`C` where
    /// the similarity score is glued to the status (`R100`) and TWO paths follow, old then new.
    static func parseNameStatus(_ data: Data) -> [String: (ChangedFile.Change, String?)] {
        var changes: [String: (ChangedFile.Change, String?)] = [:]
        var records = nulRecords(data)[...]

        while let status = records.popFirst() {
            guard let code = String(decoding: status.prefix(1), as: UTF8.self).first else { continue }
            if code == "R" || code == "C" {
                guard let old = records.popFirst(), let new = records.popFirst() else { break }
                changes[String(decoding: new, as: UTF8.self)] = (
                    code == "R" ? .renamed : .copied, String(decoding: old, as: UTF8.self)
                )
            } else {
                guard let path = records.popFirst() else { break }
                changes[String(decoding: path, as: UTF8.self)] =
                    (ChangedFile.Change(rawValue: String(code)) ?? .modified, nil)
            }
        }
        return changes
    }

    /// `diff --numstat -z` records: `additions TAB deletions TAB path`, except for a rename or
    /// copy where the path field is empty and the old and new paths follow as their own records.
    static func parseNumstat(
        _ data: Data,
        changes: [String: (ChangedFile.Change, String?)]
    ) -> [String: ChangedFile] {
        var files: [String: ChangedFile] = [:]
        var records = nulRecords(data)[...]

        while let record = records.popFirst() {
            // Only the first two tabs are separators. Any further tab belongs to the path.
            let fields = split(record, on: 0x09, limit: 2)
            guard fields.count == 3 else { continue }

            let additions = String(decoding: fields[0], as: UTF8.self)
            let deletions = String(decoding: fields[1], as: UTF8.self)

            var path = String(decoding: fields[2], as: UTF8.self)
            var oldPath: String?
            if fields[2].isEmpty {
                guard let old = records.popFirst(), let new = records.popFirst() else { break }
                oldPath = String(decoding: old, as: UTF8.self)
                path = String(decoding: new, as: UTF8.self)
            }

            let recorded = changes[path]
            files[path] = ChangedFile(
                path: path,
                oldPath: recorded?.1 ?? oldPath,
                change: recorded?.0 ?? (oldPath == nil ? .modified : .renamed),
                additions: Int(additions) ?? 0,
                deletions: Int(deletions) ?? 0,
                isBinary: additions == "-"
            )
        }
        return files
    }

    public static func diffStat(worktree: String, base: String) async throws -> (files: Int, additions: Int, deletions: Int) {
        let files = try await changedFiles(worktree: worktree, base: base)
        return (
            files.count,
            files.reduce(0) { $0 + $1.additions },
            files.reduce(0) { $0 + $1.deletions }
        )
    }

    /// The unified patch for one file, measured from the same place as `changedFiles`.
    ///
    /// The scope has to be passed through here too, or a narrowed list opens files whose diff is
    /// the whole branch: the list would say seven files and the pane would show a patch containing
    /// hunks that are not part of what the reader asked to see.
    public static func patch(
        worktree: String, base: String, file: ChangedFile, scope: DiffScope = .all
    ) async throws -> String {
        if file.change == .untracked {
            let result = try await run(
                ["diff", "--no-index", "--no-color", "--", "/dev/null", file.path], in: worktree
            )
            // --no-index exits 1 whenever there is a difference, which is the normal case here.
            return result.stdout
        }
        let mergeBase = try await revision(for: scope, base: base, in: worktree)
        return try await check(
            ["diff", "--no-color", "-M", mergeBase, "--", file.path], in: worktree
        ).stdout
    }

    /// What a scope diffs against, resolved against this worktree.
    ///
    /// `baseline` is asked for only where the answer is used: a scope measuring from `HEAD` or
    /// from a named commit does not need two ref lookups and a `merge-base` to say so, and the
    /// changed file list runs this on a six second poll.
    private static func revision(
        for scope: DiffScope, base: String, in worktree: String
    ) async throws -> String {
        guard scope != .all else { return try await baseline(base, in: worktree) }
        let revision = scope.revision(baseline: "")
        try validate(ref: revision, label: "revision")
        return revision
    }

    /// The commits this workspace put on its own branch, newest first.
    ///
    /// Bounded by `BranchCommitList.limit` and asked for one more than that, so the caller can say
    /// the list is short without a second `rev-list --count`.
    ///
    /// **Merges are left out.** A merge commit on a workspace branch is almost always the base
    /// branch being pulled in, which is the one thing on the branch the reader did not write; its
    /// subject is `Merge remote-tracking branch 'origin/main'`, and measuring a diff from it is
    /// measuring from somebody else's work. Nothing is hidden by this: a merge's own changes are
    /// still in every scope that spans it, because a scope is a revision the worktree is compared
    /// against and not a list of commits to add up.
    ///
    /// Everything is parsed from bytes with `-z`, for the reason `changedFiles` documents: a
    /// commit subject and an author name may both contain anything at all, newlines included.
    public static func branchCommits(
        worktree: String, base: String, limit: Int = BranchCommitList.limit
    ) async throws -> BranchCommitList {
        let mergeBase = try await baseline(base, in: worktree)
        // A unit separator between the fields. It is the one byte in this format that a subject,
        // an author name and an ISO date can all be relied on not to contain.
        let format = "--pretty=format:%H\u{1f}%s\u{1f}%an\u{1f}%aI"
        let output = try await checkRaw(
            [
                "log", "--no-merges", "-z", "--max-count=\(limit + 1)", format,
                "\(mergeBase)..HEAD", "--",
            ],
            in: worktree
        )
        let parsed = parseBranchCommits(output.stdout)
        return BranchCommitList(
            commits: Array(parsed.prefix(limit)), isTruncated: parsed.count > limit
        )
    }

    /// The records of `log -z --pretty=format:%H<US>%s<US>%an<US>%aI`.
    ///
    /// A record with the wrong number of fields is dropped rather than guessed at. There is no
    /// such thing as a commit worth listing that we could not read, and a menu row naming the
    /// wrong sha would scope a diff to the wrong place.
    static func parseBranchCommits(_ data: Data) -> [BranchCommit] {
        nulRecords(data).compactMap { record in
            let fields = record.split(separator: 0x1f, omittingEmptySubsequences: false)
            guard fields.count == 4 else { return nil }
            let sha = String(decoding: fields[0], as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !sha.isEmpty else { return nil }
            guard let date = try? Date.ISO8601FormatStyle().parse(
                String(decoding: fields[3], as: UTF8.self)
            ) else { return nil }
            return BranchCommit(
                sha: sha,
                subject: String(decoding: fields[1], as: UTF8.self),
                author: String(decoding: fields[2], as: UTF8.self),
                date: date
            )
        }
    }

    /// What this worktree is holding that the remote has not got, in one `git` call.
    ///
    /// `status --porcelain=v1 -z --branch` answers all of it at once: the first record is a header
    /// reading `## branch...upstream [ahead N, behind M]`, and every record after it is a changed
    /// file. Asking separately would be a `status` plus a `rev-list`, and this runs beside a poll
    /// that already spends three git calls every six seconds.
    ///
    /// The header is the only way to get the ahead count without naming a remote ref by hand.
    /// `@{upstream}` in a `rev-list` fails outright on a branch that has never been pushed, and a
    /// branch that has never been pushed is precisely the case this has to be able to describe.
    public static func localWork(worktree: String) async throws -> LocalWork {
        let status = try await checkRaw(
            ["status", "--porcelain=v1", "-z", "--branch"], in: worktree
        )
        return parseLocalWork(status.stdout)
    }

    /// The records of `status --porcelain=v1 -z --branch`, header first.
    ///
    /// One pass, counting rather than collecting: the strip says how many, never which, and a
    /// worktree mid `npm install` can hold thousands of untracked paths that nothing would read.
    /// A rename or a copy is two records and one file, so its second record is skipped, which is
    /// the same rule `parseStatus` follows before an archive.
    static func parseLocalWork(_ data: Data) -> LocalWork {
        var records = nulRecords(data)[...]
        var work = LocalWork()

        guard let header = records.first,
              String(decoding: header.prefix(2), as: UTF8.self) == "##" else {
            // No header means git answered something this does not understand. Reporting "nothing
            // local" would be a claim, and so would reporting a clean worktree, so the caller gets
            // the empty value and the strip says nothing rather than something wrong.
            return work
        }
        records.removeFirst()

        // `## branch...upstream [ahead 2, behind 1]`, or `## branch` with no upstream at all, or
        // `## HEAD (no branch)` on a detached head.
        let line = String(decoding: header.dropFirst(3), as: UTF8.self)
        work.hasUpstream = line.contains("...")
        if let ahead = line.range(of: "[ahead "),
           let end = line[ahead.upperBound...].firstIndex(where: { $0 == "," || $0 == "]" }) {
            work.unpushedCommits = Int(line[ahead.upperBound..<end]) ?? 0
        }

        while let record = records.popFirst() {
            guard record.count > 3 else { continue }
            let code = String(decoding: record.prefix(2), as: UTF8.self)
            if code == "??" {
                work.untrackedFiles += 1
            } else {
                work.modifiedFiles += 1
                if code.contains("R") || code.contains("C") { _ = records.popFirst() }
            }
        }
        return work
    }

    public static func hasUncommittedChanges(worktree: String) async throws -> Bool {
        !(try await check(["status", "--porcelain"], in: worktree).trimmed.isEmpty)
    }

    /// Whether git is holding this path in the index, meaning the project committed it.
    ///
    /// False when git cannot be asked at all, which is the safe answer everywhere this is used:
    /// every caller is deciding whether a file belongs to the project or to Bloom, and treating
    /// an unanswerable question as "the project's" leaves the file alone.
    public static func isTracked(_ path: String, in worktree: String) async -> Bool {
        guard !path.isEmpty, !path.hasPrefix("-"), !path.contains("\0") else { return false }
        let result = try? await run(
            ["ls-files", "--error-unmatch", "-z", "--", path], in: worktree
        )
        return result?.ok ?? false
    }

    /// Commits on HEAD that `base` does not have. Throws rather than answering 0 when git cannot
    /// resolve the base, because 0 reads as "this branch is in sync".
    ///
    /// **There were two of these, asking git the same thing and disagreeing about failure.** The
    /// other lived in `Git+Branches.swift`, swallowed a non-zero exit and answered 0, under a
    /// comment saying that "git could not tell me" must not arrive disguised as a number, which is
    /// precisely what a 0 there was. Its one caller is `branchRenameFacts`, whose own comment says
    /// a count git refused to give is treated as one commit so the rename is refused rather than
    /// performed on a repository nobody could ask a question of. That protection never fired: the
    /// likeliest failure is a base branch that no longer resolves, and `try?` saw a clean 0 rather
    /// than a throw. One implementation now, and it is the one whose contract the callers were
    /// written against.
    public static func commitsAhead(worktree: String, base: String) async throws -> Int {
        try validate(ref: base, label: "base branch")
        let result = try await check(["rev-list", "--count", "\(base)..HEAD", "--"], in: worktree)
        guard let count = Int(result.trimmed) else {
            throw error(["rev-list", "--count", "\(base)..HEAD"], 0, "unreadable count '\(result.trimmed)'", "")
        }
        return count
    }

    /// Lines the way `git diff --numstat` counts them: a trailing newline terminates the last
    /// line rather than starting an empty one.
    ///
    /// Public because the transcript counts lines too, for the "42 lines" a Write chip shows and
    /// for a turn's own rollup of what it changed. Those numbers sit a few points from the
    /// inspector's, which are git's, so they have to be counted the same way.
    public static func countLines(_ contents: String) -> Int {
        guard !contents.isEmpty else { return 0 }
        var count = contents.reduce(into: 0) { total, character in
            if character == "\n" { total += 1 }
        }
        // A file whose last line has no newline still has that line.
        if contents.hasSuffix("\n") == false { count += 1 }
        return count
    }
}
