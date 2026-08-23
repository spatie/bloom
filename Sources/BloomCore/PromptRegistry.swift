import Foundation

/// One configurable prompt.
///
/// A raw value rather than an index, so adding or reordering prompts can never repoint a stored
/// override at a different prompt. The raw value is also the storage key suffix.
public enum PromptID: String, Sendable, Hashable, CaseIterable, Codable {
    case createPullRequest
    case pushLocalWork
    case mergePullRequest
    case continueAfterMerge
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
    public static let all: [PromptDefinition] = [
        createPullRequest, pushLocalWork, mergePullRequest, continueAfterMerge, review,
        nameWorkspace,
    ]

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

    /// The names the commit-and-push prompt may use.
    public enum PushLocalWork {
        public static let workspace = "workspace"
        public static let branch = "branch"
        public static let baseBranch = "base_branch"
        public static let changes = "changes"
    }

    /// The names the merge prompt may use.
    public enum MergePullRequest {
        public static let workspace = "workspace"
        public static let number = "number"
        public static let title = "title"
        public static let branch = "branch"
        public static let baseBranch = "base_branch"
        /// The method in words, as GitHub's own buttons say it: "squash merge".
        public static let method = "method"
        /// The same method as the flag that performs it: `--squash`. Both, because the sentence
        /// is read by a person editing it in Settings and then by an agent typing a command, and
        /// neither form is the right one for both readers.
        public static let methodFlag = "method_flag"
    }

    /// The names the continue-after-merge prompt may use.
    public enum ContinueAfterMerge {
        public static let workspace = "workspace"
        public static let branch = "branch"
        public static let previousBranch = "previous_branch"
        public static let baseBranch = "base_branch"
        public static let pullRequest = "pull_request"
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
        Sent to the workspace's agent when you press Create pull request, with the project's \
        `.bloom/pr-instructions.md` attached, or Bloom's own copy of it when the project has \
        none. The agent does the pushing and the `gh` call itself, so it can follow the project's \
        own commit and PR conventions. How it does that lives in that file rather than here, \
        because it belongs to the project and not to Bloom. This is only the sentence that \
        carries it.
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

    /// Sent when the pull request strip reports local changes.
    ///
    /// The agent commits rather than Bloom, for the same reason it opens the pull request rather
    /// than Bloom: a commit needs a message, the agent is the only party here that knows what it
    /// changed and how this project words a commit, and a message Bloom invented would be a lie
    /// in the repository's history forever. Bloom knows only that something is uncommitted.
    static let pushLocalWork = PromptDefinition(
        id: .pushLocalWork,
        title: "Commit and push",
        summary: """
        Sent to the workspace's agent when you press Commit and push in the pull request strip, \
        which appears when this worktree is holding work GitHub has not got. Bloom never writes a \
        commit message itself: the agent knows what it changed and how this project words a \
        commit, and one Bloom invented would be in the history forever.
        """,
        variables: [
            PromptVariable(name: PushLocalWork.workspace, summary: "The workspace's name."),
            PromptVariable(name: PushLocalWork.branch, summary: "The branch the work is on."),
            PromptVariable(
                name: PushLocalWork.baseBranch,
                summary: "The branch the pull request targets."
            ),
            PromptVariable(
                name: PushLocalWork.changes,
                summary: "The changed files, with their added and removed line counts."
            ),
        ],
        defaultTemplate: """
        Commit everything outstanding in this worktree, with a message that describes the change \
        the way this project words one, then push {{branch}} so its pull request reflects what is \
        here. If there is nothing to commit, just push.
        """
    )

    /// Sent when the merged pull request strip's Continue button has already moved the worktree.
    ///
    /// A turn rather than a note, and that is the one place Bloom deliberately parts company with
    /// Conductor, which attaches its equivalent to the composer as a file and lets the user's next
    /// message carry it. Bloom sends it, for two reasons. The session is the thing being kept
    /// alive, so what happened to it belongs in the session; and the branch under the agent has
    /// moved, which is exactly the sort of fact an agent will otherwise discover an hour later by
    /// running `git status` and drawing the wrong conclusion from it.
    ///
    /// The template is expected to tell the agent NOT to start anything. Nobody has asked for work
    /// yet: Continue is a press on a strip, not an instruction, and an agent that reads this as a
    /// brief will invent one.
    static let continueAfterMerge = PromptDefinition(
        id: .continueAfterMerge,
        title: "Continue after a merge",
        summary: """
        Sent to the workspace's agent when you press Continue on a merged pull request. By the \
        time it arrives the worktree is already on a new branch, cut from an updated base, in the \
        same directory and the same session. This only tells the agent what moved, so it does not \
        find out an hour later from a confusing `git status`.
        """,
        variables: [
            PromptVariable(name: ContinueAfterMerge.workspace, summary: "The workspace's name."),
            PromptVariable(
                name: ContinueAfterMerge.branch,
                summary: "The new branch this worktree is on now."
            ),
            PromptVariable(
                name: ContinueAfterMerge.previousBranch,
                summary: "The branch that was merged."
            ),
            PromptVariable(
                name: ContinueAfterMerge.baseBranch,
                summary: "The branch the new one was cut from."
            ),
            PromptVariable(
                name: ContinueAfterMerge.pullRequest,
                summary: "The number of the pull request that landed."
            ),
        ],
        defaultTemplate: """
        Pull request #{{pull_request}} is merged, so {{previous_branch}} is finished with.

        This worktree is now on a new branch, {{branch}}, cut from an up to date \
        {{base_branch}}, so everything that just landed is already underneath you. Nothing else \
        moved: same directory, same session, and anything that was uncommitted is still here.

        Do not redo what the pull request landed, and do not start anything new yet. Say in one \
        line that you are ready, then wait for what I ask next.
        """
    )

    /// Sent when the merge confirmation is accepted.
    ///
    /// Bloom used to run `gh pr merge` itself and then `git push --delete` behind it. It does not
    /// any more, and this prompt is the whole of the replacement. Merging is the one destructive,
    /// off-machine thing this app offers: run from a button it produced a shell error in a notice
    /// and no way to answer GitHub back, where an agent doing it in the transcript shows the
    /// command, goes through the permission mode the user already set, and can say in words that
    /// a required check is missing rather than throwing.
    ///
    /// The steps are not here. They are in `.bloom/merge-instructions.md`, or in Bloom's own copy
    /// of it, for the same reason the pull request steps are in a file: they belong to the project
    /// and not to this app. This is only the sentence that carries it, and the three facts the
    /// file cannot know, which are the pull request, the branch and the method.
    static let mergePullRequest = PromptDefinition(
        id: .mergePullRequest,
        title: "Merge a pull request",
        summary: """
        Sent to the workspace's agent when you confirm Merge, with the project's \
        `.bloom/merge-instructions.md` attached, or Bloom's own copy of it when the project has \
        none. Bloom never runs `gh pr merge` itself: the agent runs it in front of you, under the \
        permission mode you set, and can tell you what GitHub said when it refuses. How the merge \
        is done lives in that file rather than here, because it belongs to the project.
        """,
        variables: [
            PromptVariable(name: MergePullRequest.workspace, summary: "The workspace's name."),
            PromptVariable(name: MergePullRequest.number, summary: "The pull request's number."),
            PromptVariable(name: MergePullRequest.title, summary: "The pull request's title."),
            PromptVariable(name: MergePullRequest.branch, summary: "The branch it is on."),
            PromptVariable(
                name: MergePullRequest.baseBranch,
                summary: "The branch it is merged into."
            ),
            PromptVariable(
                name: MergePullRequest.method,
                summary: "The method you chose, in words: squash merge, merge commit, rebase merge."
            ),
            PromptVariable(
                name: MergePullRequest.methodFlag,
                summary: "The same method as the gh flag that performs it, such as --squash."
            ),
        ],
        defaultTemplate: """
        Merge pull request #{{number}} into {{base_branch}} as a {{method}}, which is \
        `{{method_flag}}`. It is on the branch {{branch}}.
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
