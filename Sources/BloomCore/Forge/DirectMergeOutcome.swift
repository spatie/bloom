import Foundation

public enum DirectMergeOutcome: Sendable, Equatable {
    case merged
    /// gh accepted the command, but a fresh read still reports the pull request open.
    case acceptedButOpen
    /// gh accepted the command, but the follow-up status read failed.
    case acceptedUnverified
}
