import Foundation

public enum CenterTabKind: String, Codable, Sendable, CaseIterable {
    case terminal
    case browser
    /// The changed files of this workspace, read one at a time.
    case review
    /// The workspace's scratch text.
    case notes
}
