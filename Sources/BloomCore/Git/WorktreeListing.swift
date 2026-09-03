import Foundation

/// One record of `git worktree list --porcelain`, and the parser over the whole of it.
///
/// Pure, and in a file of its own, because the answer to "which branches are already taken"
/// decides whether the create window may offer a row at all, and that decision was reached by
/// asking Bloom's own database. The database only knows about worktrees Bloom cut. Git knows
/// about all of them, whoever made them, which on this Mac means Conductor's, another agent
/// runner's, and whatever was cut by hand. See `BranchHolder` for the bug that forced it.
///
/// It used to be parsed inline inside `Git.worktrees`, where the only way to exercise a locked
/// worktree or a detached head was to have a repository with one already in it. The awkward
/// shapes are all real: a project on this Mac lists twenty-two worktrees from three different
/// applications, several of them locked by an agent, with the main checkout among them looking
/// exactly like the rest.
public struct WorktreeEntry: Sendable, Hashable {
    public var path: String
    public var head: String
    /// The branch with `refs/heads/` taken off and nothing else taken off after it. A branch name
    /// may itself carry slashes, so `refs/heads/freekmurze/figma-mcp-check` is
    /// `freekmurze/figma-mcp-check` and not `figma-mcp-check`, which is the name git refused to
    /// check out twice and therefore the name that has to match.
    ///
    /// Nil for a detached head and for a bare repository's record, neither of which holds a
    /// branch and neither of which can therefore stop anybody opening one.
    public var branch: String?
    public var isBare: Bool
    public var isDetached: Bool
    /// The reason git was given for the lock, or the empty string when it was locked without one.
    ///
    /// It changes nothing about availability: a locked worktree holds its branch exactly as
    /// firmly as an unlocked one. It is read because `locked <reason>` is a line of the record and
    /// a parser that does not know it is a line will one day mistake it for something else.
    public var lockReason: String?
    /// Git's own view that this worktree's directory has gone, with the reason it gave.
    ///
    /// A prunable worktree still holds its branch until somebody runs `git worktree prune`, so
    /// this is reported rather than acted on. Telling the owner "the branch is held by a folder
    /// that is not there" is a worse answer than naming the path and letting him see that for
    /// himself.
    public var pruneReason: String?

    public var isLocked: Bool { lockReason != nil }
    public var isPrunable: Bool { pruneReason != nil }

    public init(
        path: String,
        head: String = "",
        branch: String? = nil,
        isBare: Bool = false,
        isDetached: Bool = false,
        lockReason: String? = nil,
        pruneReason: String? = nil
    ) {
        self.path = path
        self.head = head
        self.branch = branch
        self.isBare = isBare
        self.isDetached = isDetached
        self.lockReason = lockReason
        self.pruneReason = pruneReason
    }
}

public enum WorktreeListing {
    /// Every worktree git listed, in the order it listed them, the main checkout first.
    ///
    /// Records are separated by a blank line, and a record is flushed on the next `worktree` line
    /// as well as on the blank one. Relying on the blank line alone means one missing separator
    /// silently merges two worktrees into a record naming the first path and the second branch,
    /// which is the shape of mistake that ends in Bloom telling somebody the wrong folder to go
    /// and close.
    ///
    /// A path is taken whole, from the single space after the keyword to the end of the line, so a
    /// worktree under a folder with spaces in its name survives. Git does not quote paths in this
    /// format, which is why `-z` exists; nothing here can do better than git can.
    public static func parse(_ porcelain: String) -> [WorktreeEntry] {
        var entries: [WorktreeEntry] = []
        var current: WorktreeEntry?

        func flush() {
            if let current { entries.append(current) }
            current = nil
        }

        for line in porcelain.components(separatedBy: "\n") {
            let line = line.hasSuffix("\r") ? String(line.dropLast()) : line
            if line.isEmpty {
                flush()
            } else if let path = value(of: "worktree", in: line) {
                flush()
                current = WorktreeEntry(path: path)
            } else if current == nil {
                // A stray attribute with no `worktree` line above it. Git never emits one, and
                // inventing a record with no path for it would put an empty path into the answer.
                continue
            } else if let head = value(of: "HEAD", in: line) {
                current?.head = head
            } else if let ref = value(of: "branch", in: line) {
                current?.branch = ref.hasPrefix("refs/heads/")
                    ? String(ref.dropFirst("refs/heads/".count))
                    : ref
            } else if line == "bare" {
                current?.isBare = true
            } else if line == "detached" {
                current?.isDetached = true
            } else if line == "locked" {
                current?.lockReason = ""
            } else if let reason = value(of: "locked", in: line) {
                current?.lockReason = reason
            } else if line == "prunable" {
                current?.pruneReason = ""
            } else if let reason = value(of: "prunable", in: line) {
                current?.pruneReason = reason
            }
        }
        flush()
        return entries
    }

    /// The rest of the line after `keyword `, or nil when the line is about something else.
    ///
    /// Matched on the keyword plus its space rather than on the keyword alone, so a worktree at a
    /// path called `barely` is not read as the `bare` attribute.
    private static func value(of keyword: String, in line: String) -> String? {
        let prefix = keyword + " "
        guard line.hasPrefix(prefix) else { return nil }
        return String(line.dropFirst(prefix.count))
    }
}
