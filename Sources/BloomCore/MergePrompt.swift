import Foundation

/// The facts the merge prompt is rendered against.
///
/// A value rather than a lookup into the app's models, for the same reason
/// `PullRequestPromptContext` is one: the wording of what an agent is told to do to somebody's
/// repository has to be checkable without a store, a worktree or GitHub.
public struct MergePromptContext: Sendable, Hashable {
    /// What goes in the branch's place when gh did not report one.
    ///
    /// An older gh does not answer `headRefName`, and a guessed branch name in a sentence that
    /// ends in `git push --delete` is the worst thing in this file. So the prompt says there is no
    /// name rather than inventing one, and the instructions treat "the branch the message names"
    /// as absent, which is the one case where leaving the server's branch standing is correct.
    public static let noBranch = "(gh did not report the branch name: do not guess it, and leave "
        + "the branch on the server alone)"

    public static let noTitle = "(gh did not report the title)"

    public var workspaceName: String
    public var number: Int
    public var title: String
    public var branch: String
    public var baseBranch: String
    public var method: GitHub.MergeMethod

    public init(
        workspaceName: String,
        number: Int,
        title: String,
        branch: String,
        baseBranch: String,
        method: GitHub.MergeMethod
    ) {
        self.workspaceName = workspaceName
        self.number = number
        self.title = title
        self.branch = branch
        self.baseBranch = baseBranch
        self.method = method
    }

    public var values: [String: String] {
        [
            PromptRegistry.MergePullRequest.workspace: workspaceName,
            PromptRegistry.MergePullRequest.number: String(number),
            PromptRegistry.MergePullRequest.title: title.isEmpty ? Self.noTitle : title,
            PromptRegistry.MergePullRequest.branch: branch.isEmpty ? Self.noBranch : branch,
            PromptRegistry.MergePullRequest.baseBranch: baseBranch,
            PromptRegistry.MergePullRequest.method: method.phrase,
            PromptRegistry.MergePullRequest.methodFlag: method.flag,
        ]
    }

    public func render(template: String) -> PromptRender {
        PromptTemplate.render(template, values: values)
    }
}

public extension GitHub.MergeMethod {
    /// The method in the words a person uses out loud, for the sentence the agent reads.
    ///
    /// Not `label`. That is GitHub's button text, in title case and in the imperative ("Squash and
    /// merge"), which reads as an instruction of its own when it lands mid sentence.
    var phrase: String {
        switch self {
        case .merge: "merge commit"
        case .squash: "squash merge"
        case .rebase: "rebase merge"
        }
    }

    /// The flag on `gh pr merge` that performs it.
    ///
    /// Derived from the raw value rather than written out again, because the raw value is already
    /// what gh is given and two lists of the same three strings is one list too many.
    var flag: String { "--\(rawValue)" }
}
