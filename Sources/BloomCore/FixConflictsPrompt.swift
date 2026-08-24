import Foundation

/// The facts the fix-merge-conflicts prompt is rendered against.
///
/// A value rather than a lookup into the app's models, for the same reason `MergePromptContext` is
/// one: the wording of what an agent is told to do to somebody's repository has to be checkable
/// without a store, a worktree or GitHub.
///
/// It carries the branch as well as the base, and both are load bearing rather than decoration.
/// The turn asks for the base to be brought INTO this worktree, so a sentence that named only one
/// of the two would leave the direction of that merge to be guessed, and the wrong guess is the
/// one that rewrites the base branch.
public struct FixConflictsPromptContext: Sendable, Hashable {
    /// What goes in the branch's place when there is no name to put there.
    ///
    /// The caller fills this from the workspace's own branch rather than from gh's `headRefName`,
    /// because the sentence is about the branch the agent is standing on and Bloom knows that
    /// without asking GitHub. It can still be empty, on a workspace whose branch was never
    /// recorded, and "resolve the conflicts on " followed by nothing reads to an agent as an
    /// instruction that was cut off. So it says the name is missing and that the worktree is the
    /// answer, which is true: the agent is already standing on it.
    public static let noBranch = "(the branch name is not recorded: it is whichever branch this "
        + "worktree is already on, and do not switch away from it)"

    public var workspaceName: String
    public var number: Int
    public var branch: String
    public var baseBranch: String

    public init(workspaceName: String, number: Int, branch: String, baseBranch: String) {
        self.workspaceName = workspaceName
        self.number = number
        self.branch = branch
        self.baseBranch = baseBranch
    }

    public var values: [String: String] {
        [
            PromptRegistry.FixConflicts.workspace: workspaceName,
            PromptRegistry.FixConflicts.number: String(number),
            PromptRegistry.FixConflicts.branch: branch.isEmpty ? Self.noBranch : branch,
            PromptRegistry.FixConflicts.baseBranch: baseBranch,
        ]
    }

    public func render(template: String) -> PromptRender {
        PromptTemplate.render(template, values: values)
    }
}
