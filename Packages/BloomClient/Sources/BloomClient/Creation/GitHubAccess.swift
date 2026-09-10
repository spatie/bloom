import Foundation

public enum GitHubAccess: Sendable, Equatable, Codable {
    case ready
    case notInstalled
    case signedOut
}
