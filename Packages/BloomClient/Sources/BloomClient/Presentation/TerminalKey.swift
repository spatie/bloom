import Foundation

public enum TerminalKey: String, Sendable, Equatable, CaseIterable {
    case enter
    case controlC = "control-c"
    case tab
    case escape
    case up
    case down
    case left
    case right

    public var bytes: [UInt8] {
        switch self {
        case .enter: [13]
        case .controlC: [3]
        case .tab: [9]
        case .escape: [27]
        case .up: Array("\u{1b}[A".utf8)
        case .down: Array("\u{1b}[B".utf8)
        case .right: Array("\u{1b}[C".utf8)
        case .left: Array("\u{1b}[D".utf8)
        }
    }
}
