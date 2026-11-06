import Foundation

/// The one-line account of the tool calls hidden by an activity disclosure.
/// Each call is classified once from its typed input; a file change can name several files.
public struct TranscriptActivitySummary: Sendable {
    public enum Action: Sendable {
        case edit([String])
        case read([String])
        case command
        case search
        case webPage
        case calledTool
        case other

        public static func of(_ use: AgentToolUse) -> Action {
            if let item = CodexTranslation.item(in: use.input) {
                switch item {
                case .fileChange(let change):
                    return .edit(change.changes.map(\.path))
                case .commandExecution:
                    return .command
                case .webSearch(let search):
                    return search.action == "openPage" ? .webPage : .search
                case .mcpToolCall:
                    return .calledTool
                default:
                    return .other
                }
            }

            switch use.name {
            case "Write", "Edit", "MultiEdit":
                return .edit([use.input["file_path"]?.stringValue ?? ""])
            case "NotebookEdit":
                return .edit([use.input["notebook_path"]?.stringValue ?? ""])
            case "Read":
                return .read([use.input["file_path"]?.stringValue
                    ?? use.input["notebook_path"]?.stringValue ?? ""])
            case "Bash":
                return .command
            case "Glob", "Grep", "WebSearch":
                return .search
            case "WebFetch":
                return .webPage
            default:
                return MCPToolName(use.name) == nil ? .other : .calledTool
            }
        }
    }

    public struct Call: Sendable {
        public var action: Action
        public var isRunning: Bool

        public init(action: Action, isRunning: Bool = false) {
            self.action = action
            self.isRunning = isRunning
        }
    }

    /// A visible individual call uses the same wording as a collapsed activity group. Its full
    /// command or file operation remains in the row's expandable detail.
    public static func singleCallLabel(_ use: AgentToolUse, isRunning: Bool) -> String? {
        let action = Action.of(use)
        if case .other = action { return nil }
        return label([Call(action: action, isRunning: isRunning)])
    }

    /// Returns nil when there are no recognisable tool calls, leaving the generic fold label.
    public static func label(_ calls: [Call]) -> String? {
        var edits: Set<String> = []
        var reads: Set<String> = []
        var editCount = 0
        var readCount = 0
        var commands = 0
        var runningCommands = 0
        var searches = 0
        var runningSearches = 0
        var webPages = 0
        var calledTools = 0
        var others = 0

        for call in calls {
            switch call.action {
            case .edit(let paths):
                let known = paths.filter { !$0.isEmpty }
                edits.formUnion(known)
                if known.isEmpty { editCount += 1 }
            case .read(let paths):
                let known = paths.filter { !$0.isEmpty }
                reads.formUnion(known)
                if known.isEmpty { readCount += 1 }
            case .command:
                if call.isRunning { runningCommands += 1 } else { commands += 1 }
            case .search:
                if call.isRunning { runningSearches += 1 } else { searches += 1 }
            case .webPage:
                webPages += 1
            case .calledTool:
                calledTools += 1
            case .other:
                others += 1
            }
        }

        var parts: [String] = []
        let changed = edits.count + editCount
        let explored = reads.count + readCount
        if changed > 0 { parts.append("Edited \(Counted.of(changed, "file"))") }
        if searches > 0 { parts.append("Ran \(Counted.of(searches, "search"))") }
        if runningSearches > 0 { parts.append("running \(Counted.of(runningSearches, "search"))") }
        if commands > 0 { parts.append("ran \(Counted.of(commands, "command"))") }
        if runningCommands > 0 { parts.append("running \(Counted.of(runningCommands, "command"))") }
        if explored > 0 { parts.append("explored \(Counted.of(explored, "file"))") }
        if webPages > 0 { parts.append("explored \(Counted.of(webPages, "web page"))") }
        if calledTools > 0 { parts.append("called \(Counted.of(calledTools, "tool"))") }
        if others > 0 { parts.append("used \(Counted.of(others, "tool"))") }
        guard !parts.isEmpty else { return nil }
        let sentence = parts.joined(separator: ", ")
        return sentence.prefix(1).uppercased() + sentence.dropFirst()
    }
}
