import Foundation

public enum PullRequestRead: Sendable {
    case current(PullRequest?)
    case unavailable(GitHubReadFailure)
}
