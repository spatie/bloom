import Foundation

/// One configurable prompt.
///
/// A raw value rather than an index, so adding or reordering prompts can never repoint a stored
/// override at a different prompt. The raw value is also the storage key suffix.
public enum PromptID: String, Sendable, Hashable, CaseIterable, Codable {
    case createPullRequest
    case review
}

/// A substitution a prompt may use, and the one line of help shown beside it in Settings.
public struct PromptVariable: Sendable, Hashable, Identifiable {
    public let name: String
    public let summary: String

    public var id: String { name }
    public var token: String { PromptTemplate.token(name) }

    public init(name: String, summary: String) {
        self.name = name
        self.summary = summary
    }
}

/// Everything the settings form needs to draw one prompt, and everything the sender needs to run
/// it. One value per prompt, so a second prompt is a new entry in `PromptRegistry.all` and no new
/// UI at all.
public struct PromptDefinition: Sendable, Hashable, Identifiable {
    public let id: PromptID
    public let title: String
    public let summary: String
    public let variables: [PromptVariable]
    public let defaultTemplate: String

    public init(
        id: PromptID,
        title: String,
        summary: String,
        variables: [PromptVariable],
        defaultTemplate: String
    ) {
        self.id = id
        self.title = title
        self.summary = summary
        self.variables = variables
        self.defaultTemplate = defaultTemplate
    }
}

/// The built-in prompts.
///
/// Bloom asks the coding agent to do the work rather than shelling out itself, because the agent
/// already has the repository's conventions, its commit message style and its PR template in
/// context, and it can react when a push is rejected. A `gh pr create` fired from the app knows
/// none of that and can only fail.
public enum PromptRegistry {
    public static let all: [PromptDefinition] = [createPullRequest, review]

    public static func definition(for id: PromptID) -> PromptDefinition {
        // Total by construction: every case is in `all`, and the test suite pins that.
        all.first { $0.id == id } ?? createPullRequest
    }

    /// The names the create-pull-request prompt may use. Kept as constants so the sender, the
    /// definition and the tests cannot drift apart on a spelling.
    public enum CreatePullRequest {
        public static let workspace = "workspace"
        public static let branch = "branch"
        public static let baseBranch = "base_branch"
        public static let task = "task"
        public static let changes = "changes"
    }

    /// The names the review prompt may use.
    public enum Review {
        public static let message = "message"
        public static let comments = "comments"
        public static let count = "count"
    }

    static let createPullRequest = PromptDefinition(
        id: .createPullRequest,
        title: "Create pull request",
        summary: """
        Sent to the workspace's agent when you press Create pull request. The agent does the \
        pushing and the `gh` call itself, so it can follow the project's own commit and PR \
        conventions.
        """,
        variables: [
            PromptVariable(name: CreatePullRequest.workspace, summary: "The workspace's name."),
            PromptVariable(name: CreatePullRequest.branch, summary: "The branch the work is on."),
            PromptVariable(
                name: CreatePullRequest.baseBranch,
                summary: "The branch the pull request targets."
            ),
            PromptVariable(
                name: CreatePullRequest.task,
                summary: "The first thing you asked this workspace for."
            ),
            PromptVariable(
                name: CreatePullRequest.changes,
                summary: "The changed files, with their added and removed line counts."
            ),
        ],
        defaultTemplate: """
        I am happy with the state of this workspace and want a pull request for it.

        Workspace: {{workspace}}
        Branch: {{branch}}
        Target branch: {{base_branch}}

        Do this:

        - If this project has a skill or an instruction file about opening pull requests, follow \
        that first. It outranks everything below.
        - Run `git status`. If anything is uncommitted, review it and commit it, following whatever \
        this project says about commit messages.
        - Push the branch with `git push -u origin HEAD`. If it already tracks a different \
        upstream, push to that one instead.
        - Read the whole branch with `git diff {{base_branch}}...` before you write anything. The \
        description has to cover every change on the branch, not only what we did in this session.
        - Open the pull request with `gh pr create --base {{base_branch}} --title <title> --body \
        <description>`. If the repository has a pull request template, fill that in instead of \
        writing your own structure. Keep the title under 80 characters and the description under \
        five sentences.
        - Tell me the pull request URL when it exists.

        If a step fails, stop and tell me what went wrong instead of working around it.

        ## What I originally asked for

        {{task}}

        ## Changed files

        {{changes}}
        """
    )

    static let review = PromptDefinition(
        id: .review,
        title: "Send review comments",
        summary: """
        Sent when you have left inline comments on the diff and press send. Each comment already \
        carries its file, its line and the code around it, so this prompt only has to say what to \
        do with them.
        """,
        variables: [
            PromptVariable(
                name: Review.message,
                summary: "What you typed in the composer alongside the comments."
            ),
            PromptVariable(
                name: Review.comments,
                summary: "Every attached comment, with its file, line and surrounding code."
            ),
            PromptVariable(name: Review.count, summary: "How many comments are attached."),
        ],
        defaultTemplate: """
        {{message}}

        I reviewed the diff and left {{count}} inline comment(s). Each one below names the file it \
        is about, the line it points at, and the code around that line, with the commented line \
        marked `>`.

        Work through them in order. Read the surrounding code before you change anything, because \
        a comment is about the line it points at and not about the whole file. Where a comment \
        says the line has moved or is gone, find what it is actually about before acting on it, \
        and tell me if you cannot. If you disagree with one, say so instead of changing the code.

        {{comments}}
        """
    )
}
