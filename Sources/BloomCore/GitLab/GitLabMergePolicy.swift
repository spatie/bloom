import Foundation

public extension PullRequest {
    /// glab cannot clear an MR's existing squash choice by omitting --squash, or by passing
    /// --squash=false. Refuse a different promise instead of changing project or MR settings.
    func mergeMethodProblem(_ method: GitHub.MergeMethod) -> String? {
        guard forge == .gitLab, method != .squash else { return nil }
        guard let squashesOnMerge else { return "Refresh the merge request before choosing this merge method." }
        return squashesOnMerge
            ? "This merge request is configured to squash. Choose Squash and merge, or change that setting in GitLab first."
            : nil
    }
}

public extension GitHub.MergeMethod {
    func label(on forge: Forge) -> String {
        guard forge == .gitLab else { return label }
        switch self {
        case .merge: return "Project merge method"
        case .squash: return label
        case .rebase: return "Rebase, then project merge"
        }
    }

    func phrase(on forge: Forge) -> String {
        guard forge == .gitLab else { return phrase }
        switch self {
        case .merge: return "the project's merge method"
        case .squash: return "a squash merge"
        case .rebase: return "a rebase followed by the project's merge method"
        }
    }
}
