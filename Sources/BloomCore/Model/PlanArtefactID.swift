import Foundation

public struct PlanArtefactID: Identifier {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(rawValue: String) { self.rawValue = rawValue }
}
