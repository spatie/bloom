import Foundation

/// Reading and driving one terminal tab in the caller's own workspace.
public enum TerminalBridgeCommand: Sendable, Equatable {
    case read(Int?, Int)
    case write(Int?, String, submit: Bool)
    case key(Int?, TerminalKey)

    public var number: Int? {
        switch self {
        case .read(let number, _), .write(let number, _, _), .key(let number, _): number
        }
    }

    public var toolName: String {
        switch self {
        case .read: TerminalPaneToolName.read
        case .write: TerminalPaneToolName.write
        case .key: TerminalPaneToolName.key
        }
    }
}

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

public enum TerminalPaneAnswer: Sendable, Equatable {
    case told(String)
    case output(String, terminal: Int, name: String, live: Bool)
    case refused(String)
}

public typealias TerminalPaneCommanding =
    @Sendable (TerminalBridgeCommand, WorkspaceID) async -> TerminalPaneAnswer

public typealias TerminalStarting =
    @Sendable (TerminalStartOrder, WorkspaceID) async -> PaneOutcome

public struct TerminalStartOrder: Sendable, Equatable {
    public var command: String
    public var title: String?
    public var focus: Bool

    public init(command: String, title: String? = nil, focus: Bool = true) {
        self.command = command
        self.title = title
        self.focus = focus
    }
}

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

public enum TerminalPaneToolName {
    public static let start = "terminal_start"
    public static let read = "terminal_read"
    public static let write = "terminal_write"
    public static let key = "terminal_send_key"
}

public enum TerminalPaneChoice {
    public static func parse(_ raw: JSONValue?, tool: String) -> Result<Int?, PaneRefusal> {
        switch raw {
        case .none, .null:
            return .success(nil)
        case .integer(let number) where number >= 1:
            return .success(number)
        case .integer(let number):
            return .failure(
                PaneRefusal(
                    "'terminal' is the number pane_list gives a terminal, counting from 1. "
                        + "\(number) is not one of them."
                )
            )
        default:
            return .failure(
                PaneRefusal(
                    "'terminal' is a whole number, as pane_list prints it. Leave it out when "
                        + "only one terminal is open, and call pane_list first when there is more "
                        + "than one."
                )
            )
        }
    }

    public static func choose(
        number: Int?, among terminals: [TerminalPaneReport], tool: String
    ) -> Result<TerminalPaneReport, PaneRefusal> {
        guard !terminals.isEmpty else {
            return .failure(
                PaneRefusal(
                    "There is no terminal open in this workspace, so \(tool) has nothing to use. "
                        + "Open and start one with terminal_start."
                )
            )
        }
        guard let number else {
            guard terminals.count == 1 else {
                return .failure(
                    PaneRefusal(
                        "There are \(terminals.count) terminals open, so \(tool) needs a "
                            + "'terminal' number. Call pane_list and choose one."
                    )
                )
            }
            return .success(terminals[0])
        }
        guard let found = terminals.first(where: { $0.number == number }) else {
            return .failure(
                PaneRefusal(
                    "There is no terminal \(number) in this workspace. Call pane_list again "
                        + "because the numbers change when tabs are opened or closed."
                )
            )
        }
        return .success(found)
    }
}
