import Foundation

/// Everything the review pane needs to draw one file, in the form it was last drawn in.
///
/// The three come from one pass and are only ever right together: the patch git gave, the
/// document prepared from it (which is where the lexer's carry state and the intra-line emphasis
/// live), and the worktree copy the between-hunks expanders reveal.
public struct DiffPresentation: Sendable {
    /// The patch as git wrote it, before the whitespace setting was applied to it.
    public var source: FileDiff
    public var document: DiffDocument
    /// The worktree copy, split the way `ReviewCommentAnchor` splits it, or nil for a file that is
    /// not text or is no longer on disk.
    public var lines: [String]?

    public init(source: FileDiff, document: DiffDocument, lines: [String]?) {
        self.source = source
        self.document = document
        self.lines = lines
    }
}

/// The files the review pane has already prepared, so coming back to one is not doing it again.
///
/// **Changing centre tab destroys the review pane, and building it again took the reader through
/// the whole pipeline from git.** `PatchCache` fixed the first half of that, the `git diff`
/// subprocess; this is the second half, and it is the expensive one. Between a patch and a frame
/// there is a parse, a preparation pass that walks every line of the file threading the lexer's
/// carry state, and a read of the worktree copy off disk. On a file of any size that is most of
/// the wait, and it was paid again on every flick between the conversation and the changes.
///
/// # Why there is no generation in the key
///
/// `PatchCache` keys on `WorkspaceModel.changesGeneration` and is therefore good for at most the
/// six seconds between polls, deliberately: it hands back an answer as though it were fresh, so it
/// may only do so while nothing has looked at the worktree again.
///
/// This one is not that. It holds what was last ON SCREEN for a file, and it is handed back for
/// exactly the same reason a pane that stays open keeps its diff while the poll re-reads the
/// worktree underneath it: replacing a correct answer with a spinner and then the same correct
/// answer is a flash of nothing. The pane still goes to git on every arrival, and a patch that has
/// genuinely moved replaces what this handed over a moment later. So the rule is the one the open
/// pane already follows, extended across the tab switch that used to destroy it.
///
/// What IS in the key is everything that would make a held presentation an answer to a different
/// question: the worktree, the base branch, the path and what happened to it, the scope the tab is
/// set to, and whether whitespace is being ignored, because that last one changes which hunks
/// there are.
public struct DiffPresentationCache: Sendable {
    public struct Key: Hashable, Sendable {
        public var worktree: String
        public var base: String
        public var file: String
        public var change: ChangedFile.Change
        public var scope: DiffScope
        public var ignoresWhitespace: Bool

        public init(
            worktree: String,
            base: String,
            file: ChangedFile,
            scope: DiffScope,
            ignoresWhitespace: Bool
        ) {
            self.worktree = worktree
            self.base = base
            self.file = file.path
            self.change = file.change
            self.scope = scope
            self.ignoresWhitespace = ignoresWhitespace
        }
    }

    /// How many files are held at once.
    ///
    /// Fewer than `PatchCache.capacity`, and for a reason: an entry here is a prepared document
    /// and a copy of the file's lines rather than one string, so it is the larger thing by some
    /// way. Six covers walking a handful of files and coming back, which is what a review is, and
    /// keeps a repository whose files are megabytes from quietly becoming the largest thing in the
    /// process.
    public static let capacity = 6

    private var held: [Key: DiffPresentation] = [:]
    /// Keys oldest first, so the entry evicted for capacity is the least recently stored.
    private var order: [Key] = []

    public init() {}

    public var count: Int { held.count }

    public func presentation(for key: Key) -> DiffPresentation? {
        held[key]
    }

    public mutating func store(_ presentation: DiffPresentation, for key: Key) {
        if held[key] == nil || order.last != key {
            order.removeAll { $0 == key }
            order.append(key)
        }
        held[key] = presentation

        while order.count > Self.capacity {
            let oldest = order.removeFirst()
            held[oldest] = nil
        }
    }

    /// Drops everything held for one file, for a caller that knows the answer is about a file that
    /// no longer says what it said: a revert, or a save from the in-place editor.
    public mutating func forget(file path: String) {
        let stale = order.filter { $0.file == path }
        for key in stale { held[key] = nil }
        order.removeAll { $0.file == path }
    }
}
