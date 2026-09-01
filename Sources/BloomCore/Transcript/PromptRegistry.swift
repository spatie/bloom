import Foundation

/// One configurable prompt.
///
/// A raw value rather than an index, so adding or reordering prompts can never repoint a stored
/// override at a different prompt. The raw value is also the storage key suffix.
public enum PromptID: String, Sendable, Hashable, CaseIterable, Codable {
    case createPullRequest
    case pushLocalWork
    case mergePullRequest
    case fixConflicts
    case continueAfterMerge
    case carryOnArchived
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
        createPullRequest, pushLocalWork, mergePullRequest, fixConflicts, continueAfterMerge,
        carryOnArchived, review, nameWorkspace,
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

    /// The names the fix-merge-conflicts prompt may use.
    ///
    /// Deliberately fewer than the merge prompt's. Nothing in this turn touches GitHub, so the
    /// method and its flag would be two variables describing a command that is never run, and the
    /// title says nothing a conflicted file does not say better.
    public enum FixConflicts {
        public static let workspace = "workspace"
        public static let number = "number"
        /// The branch the conflicts are resolved ON, which is the one this worktree is standing on.
        public static let branch = "branch"
        /// The branch that is brought IN. Both, because the direction of that merge is the one
        /// thing in this prompt that must not be left to a guess.
        public static let baseBranch = "base_branch"
    }

    /// The names the continue-after-merge prompt may use.
    public enum ContinueAfterMerge {
        public static let workspace = "workspace"
        public static let branch = "branch"
        public static let previousBranch = "previous_branch"
        public static let baseBranch = "base_branch"
        public static let pullRequest = "pull_request"
    }

    /// The names the carry-on prompt may use.
    public enum CarryOnArchived {
        public static let workspace = "workspace"
        public static let project = "project"
        /// The branch the archive was on, and that no longer exists anywhere.
        public static let previousBranch = "previous_branch"
        /// The directory the archive was in, which was removed with it. The agent is holding
        /// paths under it, so it is named rather than left to be discovered.
        public static let previousPath = "previous_path"
        public static let branch = "branch"
        public static let baseBranch = "base_branch"
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

    /// Sent when the pull request strip's Create pull request button is pressed.
    ///
    /// The agent does the pushing and the `gh` call itself, rather than Bloom shelling out, so it
    /// can follow the project's own commit and pull request conventions. How it does that lives in
    /// `.bloom/pr-instructions.md`, or in Bloom's own copy of that file when the project has none,
    /// because the steps belong to the project and not to this app. The template below is only the
    /// sentence that carries the file.
    ///
    /// The summary is one line on purpose. What somebody editing this needs is which button sends
    /// it and which file rides along; the paragraph above used to be on screen and is why the
    /// Prompts pane opened with two hundred words before its first control.
    static let createPullRequest = PromptDefinition(
        id: .createPullRequest,
        title: "Create pull request",
        summary: """
        Sent when you press Create pull request, with the project's `.bloom/pr-instructions.md` \
        attached.
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
        Sent when you press Commit and push in the pull request strip. The agent writes the \
        commit message, not Bloom.
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
        Sent when you press Continue on a merged pull request, after the worktree has already \
        moved to a new branch. It only says what moved.
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
    /// The steps are not here, and this is the one prompt where that is a safety decision rather
    /// than a tidying one. They are `MergeInstructions.canonical`, a constant the turn is built
    /// from, because a template is editable in Settings and somebody rewording the sentence that
    /// names the pull request must not be able to delete the paragraph forbidding `--admin` by
    /// accident. What belongs here is the four facts the rules cannot know: the pull request, the
    /// branch it is on, the branch it goes into, and the method.
    ///
    /// The steps used to be a file, written into the worktree on every press and attached back.
    /// See `MergeInstructions` for why they are not one any more, and `ProjectInstructions` for
    /// what still is.
    static let mergePullRequest = PromptDefinition(
        id: .mergePullRequest,
        title: "Merge a pull request",
        summary: """
        Sent when you confirm Merge, with Bloom's own merge steps under it and the project's own \
        instructions attached when it has any. The agent runs `gh pr merge` in front of you, not \
        Bloom.
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

    /// Sent when the strip says the branch conflicts with its base.
    ///
    /// It exists because the button that used to stand there could not work. A conflicted pull
    /// request drew the ordinary Merge button beside a red band, and pressing it asked the agent
    /// to run `gh pr merge` on something GitHub had already refused to merge. The state has one
    /// remedy, a person resolving the conflict, and the button now offers that instead.
    ///
    /// **The steps used to be here, all eight paragraphs of them, and they are a file now.** They
    /// are `ConflictInstructions`, written into the shielded scratch folder and named in the
    /// sentence this template renders, which is the arrangement Create pull request has had all
    /// along. The bubble was the argument: beside a pull request turn that reads as one sentence
    /// and a path, this one was a wall of text, and a wall of text in a transcript is not read.
    /// `ConflictInstructions` says why this turn went to a file while merging went the other way.
    ///
    /// What is left here is the record, and that is what decides where the cut goes. A transcript
    /// read months later has to say what was asked without opening anything, and the file it names
    /// may well be gone by then, because the scratch folder goes when the worktree does. So the
    /// message keeps the facts and the outcome: which pull request, which two branches, that the
    /// resolution is pushed, and that the pull request is not merged. How it is done is the part
    /// that can live in a file.
    ///
    /// **The turn pushes the resolution, and it used to stop short of that.** The argument for
    /// stopping was that a resolved worktree is the state the strip's Commit and push button is
    /// for, so the next press could be the reader's. What that produced in practice was a turn
    /// that reported success on a pull request GitHub still refused to merge, because a conflict
    /// resolved in a worktree nobody has pushed is still a conflict to everybody else: the owner
    /// asked "does the merge conflict still exist", was told "locally no, on GitHub yes", and had
    /// to type "push" himself. A button called Fix merge conflicts that leaves the conflict
    /// standing is not finished.
    ///
    /// It still merges nothing. Pushing is what makes the resolution real; merging is a decision
    /// about whether the work is good, and that one stays with the reader. That sentence is in
    /// this template rather than only in the file, because it is the one limit on the turn that a
    /// person reading the transcript afterwards has to be able to see.
    ///
    /// A project that has more to say about conflicts than the file does says it once, for
    /// everybody, in `.bloom/conflict-instructions.md` or in the project settings window, and
    /// Bloom attaches that after Bloom's own and says it wins. See `ProjectInstructions`.
    static let fixConflicts = PromptDefinition(
        id: .fixConflicts,
        title: "Fix merge conflicts",
        summary: """
        Sent when you press Fix merge conflicts, with Bloom's own steps attached as a file. It \
        resolves against the base branch here and pushes the result; it never merges the pull \
        request.
        """,
        variables: [
            PromptVariable(name: FixConflicts.workspace, summary: "The workspace's name."),
            PromptVariable(name: FixConflicts.number, summary: "The pull request's number."),
            PromptVariable(
                name: FixConflicts.branch,
                summary: "The branch the conflicts are resolved on, which is this worktree's."
            ),
            PromptVariable(
                name: FixConflicts.baseBranch,
                summary: "The branch that conflicts with it, and that is brought in."
            ),
        ],
        defaultTemplate: """
        Pull request #{{number}} conflicts with {{base_branch}}, so GitHub will not merge it as it \
        stands. Resolve that here, in this worktree, on {{branch}}: bring {{base_branch}} into this \
        branch, work through the conflicts, commit, and push {{branch}}, so the conflict is gone \
        for everybody rather than only here.

        Do not merge the pull request.
        """
    )

    /// Sent into the first chat of the workspace Carry On makes, once its worktree exists.
    ///
    /// The chat it lands in is resuming the archived workspace's thread, so the agent reading it
    /// has the whole of that conversation and is not being briefed by a stranger. What it does
    /// not have is the worktree: the directory was deleted by the archive and the branch is gone
    /// from this Mac and from the remote, which is why Restore could not be offered. Every path
    /// the agent is holding is therefore stale, and that is the one fact this template exists to
    /// state.
    ///
    /// It asks for one line about where the two of them got to, and that request is for the
    /// reader rather than for the agent. Bloom's transcript rows belong to the chat they were
    /// written for, so the new workspace's conversation is empty on screen while the agent's
    /// context is full, and a chat that opens with the agent saying what it is carrying is what
    /// closes that gap honestly. The archived workspace is still there to read in full.
    ///
    /// Like `continueAfterMerge`, it must tell the agent not to start anything. Carry On is a
    /// press on a button, not a brief.
    static let carryOnArchived = PromptDefinition(
        id: .carryOnArchived,
        title: "Carry on from an archive",
        summary: """
        Sent when you press Carry On in an archived workspace, into a new worktree, resuming that \
        workspace's conversation. It only says what moved.
        """,
        variables: [
            PromptVariable(
                name: CarryOnArchived.workspace,
                summary: "The archived workspace's name, which the new one keeps."
            ),
            PromptVariable(name: CarryOnArchived.project, summary: "The project it belongs to."),
            PromptVariable(
                name: CarryOnArchived.previousBranch,
                summary: "The branch the archived workspace was on, which no longer exists."
            ),
            PromptVariable(
                name: CarryOnArchived.previousPath,
                summary: "The worktree the archive removed."
            ),
            PromptVariable(
                name: CarryOnArchived.branch,
                summary: "The branch the new worktree is on."
            ),
            PromptVariable(
                name: CarryOnArchived.baseBranch,
                summary: "The branch the new one was cut from."
            ),
        ],
        defaultTemplate: """
        We are carrying on somewhere else. The workspace this conversation was in, \
        {{workspace}}, has been archived: its worktree at {{previous_path}} was deleted, and \
        {{previous_branch}} is gone from this Mac and from the remote, so there was nothing left \
        to rebuild it from.

        You are in a new worktree now, on a fresh branch {{branch}} cut from an up \
        to date {{base_branch}} in {{project}}. Everything we said to each other is still yours, \
        and none of the files are: every path you remember is stale, so read anything here before \
        you rely on it, and expect work that landed on {{base_branch}} to already be underneath \
        you.

        Do not redo what the old branch held, and do not start anything new yet. Say in one or \
        two lines where we had got to and what was left, which is the only record of it this \
        chat has, then wait for what I ask next.
        """
    )

    /// Sent when inline comments left on the diff are sent from the composer.
    ///
    /// Each comment already carries its file, its line and the code around it by the time it gets
    /// here, so the template only has to say what to do with them.
    static let review = PromptDefinition(
        id: .review,
        title: "Send review comments",
        summary: """
        Sent when you send the inline comments you left on the diff.
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
    ///
    /// Until the answer arrives the workspace wears a plant name, and the answer never becomes
    /// part of the workspace's own conversation. Turned off, a workspace is named from the first
    /// line of the message instead, which is how it always worked; `PromptSettingsView` says that
    /// much in a tooltip on the switch.
    static let nameWorkspace = PromptDefinition(
        id: .nameWorkspace,
        title: "Name a new workspace",
        summary: """
        Sent a moment after a workspace is created, to turn what you asked for into a name and a \
        branch.
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
