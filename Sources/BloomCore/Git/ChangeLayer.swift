import Foundation

/// A path can have two different patches at once. The layer is part of its row identity,
/// cache key and selection, so staging never opens the unstaged patch for the same path.
public enum ChangeLayer: String, Sendable, Hashable, CaseIterable, Codable {
    case conflicted
    case staged
    case unstaged
    case untracked

    public var title: String {
        switch self {
        case .conflicted: "Conflicts"
        case .staged: "Staged"
        case .unstaged: "Unstaged"
        case .untracked: "Untracked"
        }
    }

    public var comparison: String {
        switch self {
        case .conflicted: "Resolve the conflicts in the working tree."
        case .staged: "Latest commit to index"
        case .unstaged: "Index to working tree"
        case .untracked: "New file, not yet tracked"
        }
    }
}
