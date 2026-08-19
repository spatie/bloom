import Foundation

/// One configurable prompt.
///
/// A raw value rather than an index, so adding or reordering prompts can never repoint a stored
/// override at a different prompt. The raw value is also the storage key suffix.
public enum PromptID: String, Sendable, Hashable, CaseIterable, Codable {
    case createPullRequest
    case review
    case nameWorkspace
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
    public static let all: [PromptDefinition] = [createPullRequest, review, nameWorkspace]

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

    /// The names the workspace-naming prompt may use.
    public enum NameWorkspace {
        public static let task = "task"
        public static let project = "project"
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
        Sent to the workspace's agent when you press Create pull request, with \
        `.bloom/pr-instructions.md` attached. The agent does the pushing and the `gh` call itself, \
        so it can follow the project's own commit and PR conventions. How it does that lives in \
        that file rather than here, because it belongs to the project and not to Bloom. This is \
        only the sentence that carries it.
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
        Create a pull request for this workspace against {{base_branch}}.
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

    /// The one prompt here that does not go to the workspace's own agent.
    ///
    /// It is answered by a separate, short-lived `claude -p` process with every tool switched off
    /// and the default system prompt replaced, because naming a task needs none of the context
    /// that makes a coding agent expensive to start. See `WorkspaceNamer`.
    static let nameWorkspace = PromptDefinition(
        id: .nameWorkspace,
        title: "Name a new workspace",
        summary: """
        Sent a moment after a workspace is created, to turn what you asked for into a short name \
        and a branch. Until the answer arrives the workspace wears a plant name. Answered by a \
        small model with no tools and no access to the repository, and it never becomes part of \
        the workspace's own conversation.
        """,
        variables: [
            PromptVariable(
                name: NameWorkspace.task,
                summary: "The first thing you asked this workspace for."
            ),
            PromptVariable(name: NameWorkspace.project, summary: "The project it was created in."),
        ],
        defaultTemplate: """
        Name this coding task, for a workspace sitting in a list beside twenty others.

        Project: {{project}}

        Answer at once, without deliberating.

        - name: at most five words, sentence case, no full stop, no quotes. Say what the work is, \
        in the words someone would use out loud. Never start it with "Task" or "Workspace".
        - branch: lowercase, words joined by hyphens, at most four words, letters, digits and \
        hyphens only, no slashes and no prefix.

        ## Task

        {{task}}
        """
    )
}
