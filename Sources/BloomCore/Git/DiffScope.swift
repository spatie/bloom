import Foundation

/// One commit on a workspace's own branch, as the scope menu lists it.
///
/// The subject only. A commit body can be a page long, and a menu row is one line.
public struct BranchCommit: Sendable, Hashable, Identifiable {
    /// The full object name. Abbreviations are for reading; git is always given the whole thing,
    /// because an abbreviation is ambiguous in a repository large enough for it to matter.
    public let sha: String
    public let subject: String
    public let author: String
    public let date: Date

    public var id: String { sha }

    /// Seven, which is what git itself shows by default and what a person recognises a commit by.
    public var abbreviated: String { String(sha.prefix(7)) }

    public init(sha: String, subject: String, author: String, date: Date) {
        self.sha = sha
        self.subject = subject
        self.author = author
        self.date = date
    }
}

/// How much of a workspace's work the Changes tab is showing.
///
/// Every scope is the same question with a different left hand side: **what does the worktree,
/// exactly as it is on disk right now, differ from**. That is what makes the three comparable and
/// what makes uncommitted work part of all of them: a diff against a commit always includes what
/// has not been committed yet, which is the only honest answer while an agent is still writing.
///
/// - `all` compares against where this branch left its base, which is what the tab has always
///   shown and what a pull request would contain.
/// - `uncommitted` compares against `HEAD`, so it is everything not yet in a commit.
/// - `since` compares against a commit on this branch, so it is everything written after it.
///
/// "Since" is the exact word. Picking a commit does NOT include that commit's own changes: it is
/// the point you are measuring from. That falls out of the model rather than being a rule to
/// remember, and it makes `uncommitted` the named case of "since the newest commit" rather than a
/// fourth kind of thing.
public enum DiffScope: Sendable, Hashable {
    case all
    case uncommitted
    case since(BranchCommit)

    /// Whether the reader is being shown less than everything, which is the whole of what the
    /// band under the tab row exists to say.
    public var isNarrowed: Bool { self != .all }

    /// What the worktree is diffed against, given where this branch left its base.
    ///
    /// The baseline is resolved by git and passed in, because working out where a branch diverged
    /// is two ref lookups and a `merge-base` and has no business happening in three places. See
    /// `Git.baseline`, which is what answers it.
    public func revision(baseline: String) -> String {
        switch self {
        case .all: baseline
        case .uncommitted: "HEAD"
        case .since(let commit): commit.sha
        }
    }

    /// The row in the menu, which is also what the band says it is showing.
    public var title: String {
        switch self {
        case .all: "All changes"
        case .uncommitted: "Uncommitted changes"
        case .since(let commit): "Since \(commit.subject)"
        }
    }

    /// The short form for the band, which has a dismiss button and a file count beside it.
    ///
    /// The abbreviated sha rather than the subject for a commit: a subject is a sentence, the band
    /// is one line, and a truncated sentence identifies a commit worse than seven characters do.
    public var badge: String {
        switch self {
        case .all: "All changes"
        case .uncommitted: "Uncommitted"
        case .since(let commit): "Since \(commit.abbreviated)"
        }
    }

    /// What the pane should say when this scope came back empty.
    ///
    /// Different sentences, because an empty list means something different in each: nothing has
    /// been written at all, everything has been committed, or nothing has happened since the
    /// commit that was picked. Answering all three with "Nothing in this worktree differs from
    /// main" would be wrong twice.
    public func emptyMessage(base: String) -> String {
        switch self {
        case .all: "Nothing in this worktree differs from \(base)."
        case .uncommitted: "Everything in this worktree is committed."
        case .since(let commit): "Nothing has changed since \(commit.abbreviated)."
        }
    }
}

/// The commits a workspace can measure from, and whether the list is all of them.
///
/// A count and a flag rather than a bare array, because a menu that quietly stops at fifty rows is
/// a menu that lies about a branch with sixty commits on it. See `Git.branchCommits`.
public struct BranchCommitList: Sendable, Hashable {
    /// The newest first, which is the order a person looks for a recent commit in.
    public var commits: [BranchCommit]
    /// True when git had more to give than the limit allowed.
    public var isTruncated: Bool

    public init(commits: [BranchCommit] = [], isTruncated: Bool = false) {
        self.commits = commits
        self.isTruncated = isTruncated
    }

    /// How many commits are offered at all.
    ///
    /// Fifty is not a performance ceiling: `git log` on ten thousand commits costs milliseconds.
    /// It is a menu ceiling. A workspace branch normally holds a handful of commits, and one
    /// holding hundreds is a long lived branch where scrolling to the two hundredth row is not how
    /// anybody is going to find the commit they mean.
    public static let limit = 50

    /// The line under the list when git had more, said rather than left to be inferred.
    public var truncationNote: String? {
        isTruncated ? "Only the newest \(Self.limit) commits are listed." : nil
    }

    /// Whether the scope that was picked can still be offered.
    ///
    /// A commit can leave this list: an amend, a rebase or a squash rewrites it, and the sha the
    /// reader picked then names nothing. The scope has to fall back rather than sit there asking
    /// git for a revision that no longer resolves, which answers as a failed refresh and leaves
    /// the pane showing the last list it had with an error over it.
    public func canOffer(_ scope: DiffScope) -> Bool {
        guard case .since(let commit) = scope else { return true }
        return commits.contains { $0.sha == commit.sha }
    }

    /// The scope actually in force, given what this branch still holds.
    ///
    /// Only ever consulted with a list that git has answered. An empty list from a branch with no
    /// commits of its own is a real answer and correctly drops a stale `since`; an empty list
    /// because nobody has asked yet must not be handed here, which is why the model keeps the two
    /// apart. The same distinction `hasReadChanges` keeps.
    public func resolve(_ scope: DiffScope) -> DiffScope {
        canOffer(scope) ? scope : .all
    }
}

public extension DiffScope {
    /// Review comments whose file this scope leaves out.
    ///
    /// Empty while nothing is narrowed, and deliberately: a comment on a file that has stopped
    /// differing from the base is already possible, has always been possible, and is not news
    /// caused by anything the reader just did. This answers one question only, "did narrowing the
    /// scope take a comment off screen", so it only speaks when narrowing is what happened.
    ///
    /// Nothing about this is a warning that work is at risk. Comments live in the store keyed by
    /// workspace and path, no refresh prunes them against the file list, and the composer sends
    /// every one of them whatever the tab is showing.
    func strandedComments(
        _ comments: [ReviewComment], among files: [ChangedFile]
    ) -> [ReviewComment] {
        guard isNarrowed else { return [] }
        let shown = Set(files.map(\.path))
        return comments.filter { !shown.contains($0.filePath) }
    }

    /// The sentence for those, or nil when there are none.
    func strandedNote(_ comments: [ReviewComment], among files: [ChangedFile]) -> String? {
        let stranded = strandedComments(comments, among: files)
        guard !stranded.isEmpty else { return nil }
        let count = stranded.count
        return "\(count) review comment\(count == 1 ? " is" : "s are") on files this scope leaves"
            + " out. \(count == 1 ? "It is" : "They are") kept, and still sent with your next"
            + " message."
    }
}
