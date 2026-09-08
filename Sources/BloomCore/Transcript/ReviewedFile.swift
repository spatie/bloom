import Foundation

// MARK: - The mark

/// One file a reviewer has said they have read, and what its diff looked like when they said it.
///
/// **A tick that cannot go stale is a tick that lies.** The agent is editing this worktree while
/// the review is open, so a mark that only said "read" would still be sitting on a file the agent
/// rewrote a minute later, and the reader would walk past it. So the mark carries a fingerprint of
/// the diff it was given for, and a file whose diff has moved on since reads as unviewed again.
///
/// This is the second time Bloom has had this feature. The first was a lone `@AppStorage` bool per
/// workspace and path, written and read by one toggle in the file bar and by nothing else: no row
/// in the list dimmed, no count said "3 of 12", and it was taken out in "Take Viewed out of the
/// file bar" for exactly that reason. What makes it worth having now is that the mark is read
/// somewhere other than the control that sets it, which is why it is a table rather than a
/// defaults key: it belongs to the workspace, it dies with the workspace through the foreign key,
/// and there can be one per changed file.
public struct ReviewedFile: Sendable, Hashable, Codable {
    public var workspaceID: WorkspaceID
    /// Repository-relative, as the diff spells it, so it is the same string the changed file list,
    /// the review pane and a review comment all use for one file.
    public var path: String
    /// What `ReviewedFileFingerprint` made of the file's diff at the moment it was ticked.
    public var fingerprint: String
    public var viewedAt: Date

    public init(
        workspaceID: WorkspaceID,
        path: String,
        fingerprint: String,
        viewedAt: Date = Date()
    ) {
        self.workspaceID = workspaceID
        self.path = path
        self.fingerprint = fingerprint
        self.viewedAt = viewedAt
    }
}

// MARK: - What a mark is given for

/// What a file's diff looked like when it was ticked, in one short string.
///
/// Diff counts identify the change shape; the worktree stamp also notices replacements that
/// leave those counts unchanged. Stamps are read with the existing background file refresh,
/// not while drawing a row and not by launching a git process for every viewed file.
public enum ReviewedFileFingerprint {
    public static func of(_ file: ChangedFile, revision: String = "") -> String {
        let counts = "\(file.change.rawValue):\(file.additions):\(file.deletions):\(file.isBinary ? 1 : 0)"
        return revision.isEmpty ? counts : counts + ":" + revision
    }

    public static func revisions(for files: [ChangedFile], worktree: String, base: String, scope: DiffScope) -> [String: String] {
        let comparison = scope.revision(baseline: base)
        return Dictionary(uniqueKeysWithValues: files.map { file in
            let path = (worktree as NSString).appendingPathComponent(file.path)
            let attributes = try? FileManager.default.attributesOfItem(atPath: path)
            let modified = (attributes?[.modificationDate] as? Date)?.timeIntervalSinceReferenceDate
            let size = (attributes?[.size] as? NSNumber)?.uint64Value
            let inode = (attributes?[.systemFileNumber] as? NSNumber)?.uint64Value
            let stamp = "\(comparison):\(modified.map { String($0) } ?? "missing"):\(size.map { String($0) } ?? "missing"):\(inode.map { String($0) } ?? "missing")"
            return (file.path, stamp)
        })
    }
}

// MARK: - Reading the marks

/// Every question the window asks about the ticks, over the fingerprints as they were stored.
///
/// A dictionary of path to fingerprint rather than the rows themselves, because that is what the
/// answers turn on and it is what the model can hold cheaply beside the changed file list. When
/// the two disagree the file is not viewed: the mark stays in the store (a revert that puts the
/// diff back the way it was makes the tick true again, and re-ticking a file the agent has since
/// undone is a keystroke the reader should not have to spend) and every reader here reports it as
/// unread while the disagreement lasts.
public enum ReviewedFiles {
    public static func isViewed(_ file: ChangedFile, marks: [String: String], revisions: [String: String] = [:]) -> Bool {
        marks[file.path] == ReviewedFileFingerprint.of(file, revision: revisions[file.path] ?? "")
    }

    /// How many of the files on screen carry a tick that still holds.
    public static func viewedCount(among files: [ChangedFile], marks: [String: String], revisions: [String: String] = [:]) -> Int {
        files.count(where: { isViewed($0, marks: marks, revisions: revisions) })
    }

    /// The line the changed file list draws over itself, or nil when there is nothing to say.
    ///
    /// Nothing at all until a file has been ticked, because "0 of 12 viewed" on first sight is a
    /// progress bar for work nobody has started, and the whole list is unread by definition. It
    /// says "All 12 files viewed" at the end rather than "12 of 12", which is the one state worth
    /// reading as an answer instead of as a ratio.
    public static func summary(among files: [ChangedFile], marks: [String: String], revisions: [String: String] = [:]) -> String? {
        let total = files.count
        guard total > 0 else { return nil }
        let viewed = viewedCount(among: files, marks: marks, revisions: revisions)
        guard viewed > 0 else { return nil }
        if viewed >= total {
            return "All \(Counted.of(total, "file")) viewed"
        }
        return "\(viewed) of \(total) files viewed"
    }

    /// The files a reviewer has not read yet, in the order they were given, which is what walking
    /// to the next unread file needs.
    public static func unviewed(
        among files: [ChangedFile],
        marks: [String: String],
        revisions: [String: String] = [:]
    ) -> [ChangedFile] {
        files.filter { !isViewed($0, marks: marks, revisions: revisions) }
    }
}

// MARK: - The control's own wording

/// What the tick offers, seen from whichever side it is currently on.
///
/// One item that changes its label rather than two, and one wording however many places offer it:
/// the file bar's toggle, the row's context menu and the shortcut's help all read this, so a
/// keystroke and a menu item cannot come to two accounts of what they do. The same shape, and the
/// same argument, as `UnreadMarkAction` over in the model.
public enum ReviewedMarkAction: String, Sendable, Hashable, CaseIterable {
    /// The file has not been read. The item offers to tick it.
    case markViewed
    /// The file is ticked. The item offers to clear it.
    case markNotViewed

    public init(isViewed: Bool) {
        self = isViewed ? .markNotViewed : .markViewed
    }

    public var title: String {
        switch self {
        case .markViewed: "Mark as Viewed"
        case .markNotViewed: "Mark as Not Viewed"
        }
    }

    /// What the tick becomes when this is chosen.
    public var isViewed: Bool { self == .markViewed }

    /// The sentence under the pointer, which names the file because the control sits in a bar
    /// that may be showing a different one by the time somebody reads it.
    public func help(for filename: String) -> String {
        switch self {
        case .markViewed: "Mark \(filename) as viewed (Option+V)"
        case .markNotViewed: "Mark \(filename) as not yet viewed (Option+V)"
        }
    }
}
