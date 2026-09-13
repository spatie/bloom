import Foundation

/// Absence clears the previous result; an unavailable service preserves it with an explanation.
/// The sidebar and inspector share this decision so a failed poll never means a clean slate.
public struct PullRequestRefreshState: Sendable, Equatable {
    public private(set) var pullRequest: PullRequest?
    public private(set) var failure: GitHubReadFailure?

    public init(pullRequest: PullRequest? = nil) {
        self.pullRequest = pullRequest
    }

    public mutating func record(_ read: PullRequestRead) {
        switch read {
        case .current(let pullRequest):
            self.pullRequest = pullRequest
            failure = nil
        case .unavailable(let failure):
            self.failure = failure
        }
    }
}
