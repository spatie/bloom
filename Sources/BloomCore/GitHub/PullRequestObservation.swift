import Foundation

/// The row and forge generation a request lookup started with. A forge change clears the
/// numbers and changes the generation in one transaction, so an old read cannot write them back.
public struct PullRequestObservation: Sendable {
    public let workspace: Workspace
    public let forge: Forge?
    let generation: String
}
