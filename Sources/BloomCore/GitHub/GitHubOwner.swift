import Foundation

/// Who a new repository could belong to.
public struct GitHubOwner: Sendable, Hashable, Identifiable {
    public enum Kind: Sendable, Hashable {
        case user
        case organization
    }

    public let login: String
    public let kind: Kind

    public var id: String { login }

    public init(login: String, kind: Kind) {
        self.login = login
        self.kind = kind
    }
}
