import Foundation

/// A branch history entry. Rows show the subject; the selected commit also exposes its body
/// and parents so merge comparisons can say exactly what is being reviewed.
public struct BranchCommit: Sendable, Hashable, Identifiable {
    /// The full object name. Abbreviations are for reading; git is always given the whole thing,
    /// because an abbreviation is ambiguous in a repository large enough for it to matter.
    public let sha: String
    public let subject: String
    public let author: String
    public let date: Date
    public let body: String
    public let parents: [String]

    public var id: String { sha }

    /// Seven, which is what git itself shows by default and what a person recognises a commit by.
    public var abbreviated: String { String(sha.prefix(7)) }

    public init(sha: String, subject: String, author: String, date: Date, body: String = "", parents: [String] = []) {
        self.sha = sha
        self.subject = subject
        self.author = author
        self.date = date
        self.body = body
        self.parents = parents
    }
}

/// A comparison selected by the reader. Commit review compares two immutable trees;
/// neither the index nor the working tree belongs to that patch.
public enum DiffScope: Sendable, Hashable {
    case all
    case uncommitted
    case commit(BranchCommit)

    public var isNarrowed: Bool { self != .all }
    public var isHistorical: Bool {
        if case .commit = self { return true }
        return false
    }

    /// Identity of the comparison, also used to keep viewed marks scoped to it.
    public func revision(baseline: String) -> String {
        switch self {
        case .all: baseline
        case .uncommitted: "HEAD"
        case .commit(let commit): commit.sha
        }
    }

    public var title: String {
        switch self {
        case .all: "All branch changes"
        case .uncommitted: "Uncommitted changes"
        case .commit(let commit): commit.subject
        }
    }

    public var badge: String {
        switch self {
        case .all: "All branch changes"
        case .uncommitted: "Uncommitted"
        case .commit(let commit): "Commit \(commit.abbreviated)"
        }
    }

    public func emptyMessage(base: String) -> String {
        switch self {
        case .all: "Nothing in this worktree differs from \(base)."
        case .uncommitted: "Everything in this worktree is committed."
        case .commit(let commit): "Commit \(commit.abbreviated) introduces no file changes."
        }
    }

    /// Historical and index snapshots must never offer an editor or revert today's file.
    public func allowsWorktreeActions(for file: ChangedFile) -> Bool {
        !isHistorical && file.layer == nil
    }
}

/// A page of branch history. A selected commit falling beyond the page is not evidence
/// that it was rewritten; callers verify ancestry before dropping the selection.
public struct BranchCommitList: Sendable, Hashable {
    public var commits: [BranchCommit]
    public var isTruncated: Bool

    public init(commits: [BranchCommit] = [], isTruncated: Bool = false) {
        self.commits = commits
        self.isTruncated = isTruncated
    }

    public static let limit = 50
    public var truncationNote: String? {
        isTruncated ? "Showing the newest \(commits.count) commits." : nil
    }

    public func canOffer(_ scope: DiffScope) -> Bool {
        guard case .commit(let commit) = scope else { return true }
        return isTruncated || commits.contains { $0.sha == commit.sha }
    }

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
