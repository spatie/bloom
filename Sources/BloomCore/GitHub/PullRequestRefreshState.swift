import Foundation

/// Absence clears the previous result; an unavailable service preserves it with an explanation.
/// The sidebar and inspector share this decision so a failed poll never means a clean slate.
public struct PullRequestRefreshState: Sendable, Equatable {
    public private(set) var pullRequest: PullRequest?
    public private(set) var failure: GitHubReadFailure?
    private var dismissed: DismissedFailure?

    /// What a dismissal remembers, which is deliberately less than the failure itself. The
    /// inspector polls every few seconds, and a rate limit carries a `retryAt` that can move on
    /// each of them, so remembering the whole value brought the banner straight back.
    private struct DismissedFailure: Sendable, Equatable {
        let reason: GitHubReadFailure.Reason
        let message: String

        init(_ failure: GitHubReadFailure) {
            reason = failure.reason
            message = failure.message
        }
    }

    public init(pullRequest: PullRequest? = nil) {
        self.pullRequest = pullRequest
    }

    /// The failure worth showing: the current one, unless somebody has already closed it.
    ///
    /// A dismissal lasts until GitHub says something different. A new failure is new information
    /// and shows again; a successful read clears the dismissal, so the next time the same thing
    /// breaks it is reported rather than silently remembered as closed.
    public var visibleFailure: GitHubReadFailure? {
        guard let failure else { return nil }
        return dismissed == DismissedFailure(failure) ? nil : failure
    }

    public mutating func record(_ read: PullRequestRead) {
        switch read {
        case .current(let pullRequest):
            self.pullRequest = pullRequest
            failure = nil
            dismissed = nil
        case .unavailable(let failure):
            self.failure = failure
        }
    }

    public mutating func dismissFailure() {
        dismissed = failure.map(DismissedFailure.init)
    }
}
