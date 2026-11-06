import Foundation

/// Whether the GitHub CLI can be used, and if not, why not.
///
/// Two failures rather than one, because they are different problems: `gh` missing is fixed by
/// installing it, `gh` signed out is fixed by signing in, and a sentence that covers both says
/// nothing useful about either.
public enum GitHubAccess: Sendable, Equatable {
    case ready
    case notInstalled
    case signedOut
}
