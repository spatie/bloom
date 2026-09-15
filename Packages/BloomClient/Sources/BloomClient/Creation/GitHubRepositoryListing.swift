import Foundation

public struct GitHubRepositoryListing: Codable, Sendable, Identifiable, Equatable {
    public var nameWithOwner: String
    public var description: String?
    public var isPrivate: Bool
    public var id: String { nameWithOwner }

    public init(nameWithOwner: String, description: String? = nil, isPrivate: Bool) {
        self.nameWithOwner = nameWithOwner; self.description = description; self.isPrivate = isPrivate
    }

    enum CodingKeys: String, CodingKey {
        case nameWithOwner = "full_name"
        case description
        case isPrivate = "private"
    }
}
