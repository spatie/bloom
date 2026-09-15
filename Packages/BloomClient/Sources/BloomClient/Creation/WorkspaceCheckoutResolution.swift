import Foundation

public enum WorkspaceCheckoutResolution: Sendable, Equatable, Codable {
    case checkout(WorkspaceCheckout)
    case failure(String)
}
