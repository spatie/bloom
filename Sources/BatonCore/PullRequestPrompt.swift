import Foundation

/// The facts the create-pull-request prompt is rendered against.
///
/// A value rather than a lookup into the app's models, so the wording of what the agent is told can
/// be checked without a store, a worktree or GitHub.
public struct PullRequestPromptContext: Sendable, Hashable {
    /// What is put in a variable's place when the workspace cannot answer it. A sentence rather
    /// than an empty string, because a heading followed by nothing reads to the agent as an
    /// instruction that was cut off.
    public static let noTask = "(nothing recorded: this workspace has no opening prompt)"
    public static let noChanges = "(git reports no changes against the target branch)"

    /// How many files are listed before the rest are counted. A rename-heavy branch can touch
    /// hundreds, and a wall of paths costs the agent context it needs for the diff itself.
    public static let fileLimit = 40

    public var workspaceName: String
    public var branch: String
    public var baseBranch: String
    public var task: String
    public var changes: String

    public init(
        workspaceName: String,
        branch: String,
        baseBranch: String,
        task: String,
        changes: String
    ) {
        self.workspaceName = workspaceName
        self.branch = branch
        self.baseBranch = baseBranch
        self.task = task
        self.changes = changes
    }

    public var values: [String: String] {
        [
            PromptRegistry.CreatePullRequest.workspace: workspaceName,
            PromptRegistry.CreatePullRequest.branch: branch,
            PromptRegistry.CreatePullRequest.baseBranch: baseBranch,
            PromptRegistry.CreatePullRequest.task: task.isEmpty ? Self.noTask : task,
            PromptRegistry.CreatePullRequest.changes: changes.isEmpty ? Self.noChanges : changes,
        ]
    }

    public func render(template: String) -> PromptRender {
        PromptTemplate.render(template, values: values)
    }

    /// One line per file, in git's own order, with the counts that tell the agent where the weight
    /// of the change is. Binary files say so rather than claiming zero lines changed.
    public static func changeSummary(_ files: [ChangedFile], limit: Int = fileLimit) -> String {
        guard !files.isEmpty else { return "" }

        var lines = files.prefix(limit).map { file -> String in
            let name = file.oldPath.map { "\($0) -> \(file.path)" } ?? file.path
            let detail = file.isBinary ? "binary" : "+\(file.additions)/-\(file.deletions)"
            return "- \(name) (\(label(for: file.change)), \(detail))"
        }

        let remaining = files.count - lines.count
        if remaining > 0 {
            lines.append("- ...and \(remaining) more file\(remaining == 1 ? "" : "s")")
        }
        return lines.joined(separator: "\n")
    }

    /// Git's one-letter status codes spelled out, because the prompt is prose the agent reads and
    /// `?` on its own is ambiguous in that setting.
    static func label(for change: ChangedFile.Change) -> String {
        switch change {
        case .added: "added"
        case .modified: "modified"
        case .deleted: "deleted"
        case .renamed: "renamed"
        case .copied: "copied"
        case .untracked: "untracked"
        }
    }
}

/// Reads the text back out of a stored user turn.
///
/// The runner writes the exact JSON line it handed the agent's stdin, so the opening prompt of a
/// workspace is recoverable from the transcript rather than needing a column of its own.
public enum UserTurnPayload {
    public static func text(from payload: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let message = object["message"] as? [String: Any],
              let content = message["content"] as? [[String: Any]] else { return nil }

        let text = content
            .compactMap { $0["text"] as? String }
            .joined(separator: "\n")
        return text.isEmpty ? nil : text
    }
}
