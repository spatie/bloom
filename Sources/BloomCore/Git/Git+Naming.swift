import Foundation

/// Turning a prompt into a branch name, a stem and a title.
///
/// The one part of `Git` that never runs git: every function here is a rule about words, so the
/// tests drive them without a repository on disk. Whether the result is a name git will accept
/// is a separate question, and `isValidBranchName` in `Git.swift` is what answers it.
extension Git {
    private static let stopWords: Set<String> = [
        "the", "a", "an", "and", "or", "but", "to", "of", "in", "on", "for", "with",
        "please", "can", "you", "i", "we", "it", "this", "that", "is", "are", "be",
        "should", "would", "could", "make", "let", "lets",
    ]

    /// Turn a prompt into a branch-safe slug. Mirrors what Conductor does: take the meaningful
    /// words from the first line, cap the length, keep it readable.
    public static func slug(from prompt: String, maxWords: Int = 5) -> String {
        let firstLine = prompt
            .components(separatedBy: "\n")
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? prompt

        let words = firstLine
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }

        var kept = words.filter { !stopWords.contains($0) && $0.count > 1 }
        if kept.isEmpty { kept = words }
        if kept.isEmpty { return "workspace" }

        var parts = Array(kept.prefix(maxWords))

        // A file path is usually the most distinguishing thing in a prompt, and it is exactly
        // what falls off the end of the word budget. Without this, "add a docblock to Invoice.php"
        // and "... to Contact.php" produce the same branch, and the collision suffix (-2, -3)
        // leaves a sidebar full of names that say nothing about which is which.
        if let token = distinguishingToken(from: firstLine), !parts.contains(token) {
            parts.append(token)
        }

        return String(parts.joined(separator: "-").prefix(60))
    }

    /// The basename of the first path-like token in a line, lowercased and hyphenated.
    static func distinguishingToken(from line: String) -> String? {
        let separators = CharacterSet(charactersIn: " \t,;()[]{}\"'`")
        for token in line.components(separatedBy: separators) where !token.isEmpty {
            let trimmed = token.trimmingCharacters(in: CharacterSet(charactersIn: ".:"))
            let base = (trimmed as NSString).lastPathComponent
            let stem = (base as NSString).deletingPathExtension
            let ext = (base as NSString).pathExtension

            // Either an actual path, or something that really looks like a filename. A bare
            // sentence ending in a full stop must not qualify.
            let looksLikePath = trimmed.contains("/")
            let looksLikeFile = !ext.isEmpty && ext.count <= 5
                && ext.allSatisfy(\.isLetter) && stem.count >= 3
            guard looksLikePath || looksLikeFile else { continue }

            let cleaned = stem
                .lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { !$0.isEmpty }
                .joined(separator: "-")
            if cleaned.count >= 2 { return cleaned }
        }
        return nil
    }

    /// A human-facing workspace name: the first line, trimmed and sentence-cased.
    public static func title(from prompt: String, maxLength: Int = 72) -> String {
        let firstLine = prompt
            .components(separatedBy: "\n")
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard !firstLine.isEmpty else { return "New workspace" }

        var title = firstLine
        if title.count > maxLength {
            let cut = title.prefix(maxLength)
            if let lastSpace = cut.lastIndex(of: " ") {
                title = String(cut[..<lastSpace])
            } else {
                title = String(cut)
            }
        }
        return title.prefix(1).uppercased() + title.dropFirst()
    }

    /// Append -2, -3 and so on until the branch name is free.
    /// The branch a prompt would be cut on, before anything checks whether it is free.
    ///
    /// One function because two places need the same answer and only one of them can act on it:
    /// `WorkspaceManager.cut` puts a worktree on it, and the create sheet prints it under the box
    /// so somebody can see what they are about to make. Those were two copies of the same three
    /// lines, one of them carrying a comment saying it mirrored the other, which is a drift waiting
    /// for the next change to either side. A preview that has drifted is a lie in a monospaced font.
    ///
    /// An explicit branch is returned untouched, prefix and all: somebody who typed a branch name
    /// meant that branch name. The uniquing suffix is deliberately not here, because it depends on
    /// what the repository holds at the moment of cutting and the preview has no business guessing.
    public static func branchStem(prompt: String, prefix: String?, branch: String? = nil) -> String {
        if let branch, !branch.isEmpty { return branch }
        return prefixed(Self.slug(from: prompt), with: prefix)
    }

    /// A branch name under a project's `branchPrefix`.
    ///
    /// Three lines, and it is a function because there were three copies of them: here, in
    /// `WorkspaceNaming.cleanBranch` where a model's suggestion is prefixed, and in the app where
    /// a claimed sea's slug is. The third carried a comment saying it applied the same rule as the
    /// second, which it did by writing it out again, under a comment on this one warning about
    /// exactly that. What a prefix means, which is a slash and no trimming, is decided here.
    ///
    /// An empty prefix is no prefix. A project that has never set one and one that set it to ""
    /// are the same project.
    public static func prefixed(_ slug: String, with prefix: String?) -> String {
        guard let prefix, !prefix.isEmpty else { return slug }
        return "\(prefix)/\(slug)"
    }

    public static func uniqueBranch(_ desired: String, taken: Set<String>) -> String {
        guard taken.contains(desired) else { return desired }
        var suffix = 2
        while taken.contains("\(desired)-\(suffix)") { suffix += 1 }
        return "\(desired)-\(suffix)"
    }
}
