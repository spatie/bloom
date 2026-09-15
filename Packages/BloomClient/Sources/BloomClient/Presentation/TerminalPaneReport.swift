import Foundation

public struct TerminalPaneReport: Sendable, Equatable {
    public var number: Int
    public var name: String
    public var isLive: Bool

    public init(number: Int, name: String, isLive: Bool) {
        self.number = number
        self.name = name
        self.isLive = isLive
    }
}
