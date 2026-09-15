import Foundation
import BloomClient

public struct GitSnapshotID: Identifier {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
}
